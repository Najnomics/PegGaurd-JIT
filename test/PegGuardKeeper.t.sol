// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";

import {PegGuardHook} from "../src/PegGuardHook.sol";
import {PegGuardKeeper} from "../src/PegGuardKeeper.sol";
import {PythOracleAdapter} from "../src/oracle/PythOracleAdapter.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

contract PegGuardKeeperTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;
    PoolId poolId;

    PegGuardHook hook;
    PegGuardKeeper keeper;
    MockPyth mockPyth;
    PythOracleAdapter adapter;

    int24 tickLower;
    int24 tickUpper;

    bytes32 constant FEED_USDC = keccak256("USDC");
    bytes32 constant FEED_USDT = keccak256("USDT");

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        mockPyth = new MockPyth();
        adapter = new PythOracleAdapter(address(mockPyth));

        bytes memory constructorArgs =
            abi.encode(poolManager, address(adapter), Currency.unwrap(currency0), address(this));
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), flags, type(PegGuardHook).creationCode, constructorArgs);
        hook = new PegGuardHook{salt: salt}(poolManager, address(adapter), Currency.unwrap(currency0), address(this));
        require(address(hook) == expected, "PegGuardKeeperTest: hook address mismatch");

        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);
        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        PegGuardHook.ConfigurePoolParams memory params = PegGuardHook.ConfigurePoolParams({
            priceFeedId0: FEED_USDC,
            priceFeedId1: FEED_USDT,
            baseFee: 3000,
            maxFee: 50_000,
            minFee: 500,
            reserveCutBps: 0,
            volatilityThresholdBps: 0,
            depegThresholdBps: 0
        });
        hook.configurePool(poolKey, params);
        hook.updateLiquidityAllowlist(poolKey, address(positionManager), true);

        keeper = new PegGuardKeeper(address(hook), address(this));
        hook.setKeeperRole(address(keeper), true);

        PegGuardKeeper.KeeperConfig memory cfg = PegGuardKeeper.KeeperConfig({
            alertBps: 30, crisisBps: 70, jitActivationBps: 70, modeCooldown: 0, jitCooldown: 0
        });
        keeper.setKeeperConfig(poolKey, cfg);

        _setPrices(1_000_000_00, 1_000_000_00, 50);
    }

    function testKeeperPromotesToAlert() public {
        _setPrices(995_000_00, 1_000_000_00, 30);
        keeper.evaluateAndUpdate(poolKey);
        (, PegGuardHook.PoolState memory state) = hook.getPoolSnapshot(poolKey);
        assertEq(uint8(state.mode), uint8(PegGuardHook.PoolMode.Alert));
        assertFalse(state.jitLiquidityActive);
    }

    function testKeeperTriggersCrisisAndJIT() public {
        _setPrices(920_000_00, 1_000_000_00, 20);
        keeper.evaluateAndUpdate(poolKey);
        (, PegGuardHook.PoolState memory state) = hook.getPoolSnapshot(poolKey);
        assertEq(uint8(state.mode), uint8(PegGuardHook.PoolMode.Crisis));
        assertTrue(state.jitLiquidityActive);
    }

    function _setPrices(int64 price0, int64 price1, uint64 confidence) internal {
        mockPyth.setPrice(FEED_USDC, price0, confidence);
        mockPyth.setPrice(FEED_USDT, price1, confidence);
    }
}
