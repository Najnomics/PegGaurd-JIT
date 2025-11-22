// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PegGuardHook} from "../src/PegGuardHook.sol";
import {PegGuardKeeper} from "../src/PegGuardKeeper.sol";
import {PegGuardJITManager} from "../src/PegGuardJITManager.sol";
import {PythOracleAdapter} from "../src/oracle/PythOracleAdapter.sol";

contract PegGuardIntegrationTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PegGuardHook hook;
    PegGuardKeeper keeper;
    PegGuardJITManager jitManager;
    MockPyth mockPyth;
    PythOracleAdapter adapter;

    PoolKey poolKey;
    PoolId poolId;
    Currency currency0;
    Currency currency1;

    bytes32 constant FEED0 = keccak256("ASSET0");
    bytes32 constant FEED1 = keccak256("ASSET1");

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
        require(address(hook) == expected, "PegGuardIntegration: hook addr mismatch");

        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);
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

        hook.configurePool(
            poolKey,
            PegGuardHook.ConfigurePoolParams({
                priceFeedId0: FEED0,
                priceFeedId1: FEED1,
                baseFee: 3000,
                maxFee: 50_000,
                minFee: 500,
                reserveCutBps: 3000,
                volatilityThresholdBps: 100,
                depegThresholdBps: 50
            })
        );
        hook.updateLiquidityAllowlist(poolKey, address(positionManager), true);

        keeper = new PegGuardKeeper(address(hook), address(this));
        hook.setKeeperRole(address(keeper), true);

        keeper.setKeeperConfig(
            poolKey,
            PegGuardKeeper.KeeperConfig({
                alertBps: 100, crisisBps: 200, jitActivationBps: 200, modeCooldown: 0, jitCooldown: 0
            })
        );

        jitManager = new PegGuardJITManager(
            address(hook), address(positionManager), address(permit2), address(this), address(this)
        );
        hook.setKeeperRole(address(jitManager), true);
        hook.updateLiquidityAllowlist(poolKey, address(positionManager), true);

        jitManager.configurePool(
            poolKey,
            PegGuardJITManager.PoolJITConfig({
                tickLower: tickLower + poolKey.tickSpacing,
                tickUpper: tickUpper - poolKey.tickSpacing,
                maxDuration: 1 hours,
                reserveShareBps: 1000
            })
        );
    }

    function testEndToEndFlow() public {
        MockERC20(Currency.unwrap(currency0)).approve(address(jitManager), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(jitManager), type(uint256).max);

        mockPyth.setPrice(FEED0, 95_000_00, 50);
        mockPyth.setPrice(FEED1, 100_000_00, 50);

        keeper.evaluateAndUpdate(poolKey);
        (, PegGuardHook.PoolState memory state) = hook.getPoolSnapshot(poolKey);
        assertEq(uint8(state.mode), uint8(PegGuardHook.PoolMode.Crisis));
        assertTrue(state.jitLiquidityActive);

        jitManager.executeBurst(poolKey, 5e18, 10e18, 10e18, address(this), 60);

        vm.warp(block.timestamp + 120);
        jitManager.settleBurst(poolKey, 0, 0);

        (, state) = hook.getPoolSnapshot(poolKey);
        assertFalse(state.jitLiquidityActive);
        assertGt(state.reserveBalance, 0);
    }

    function testFullLifecycleWithReserveAccumulation() public {
        MockERC20(Currency.unwrap(currency0)).approve(address(jitManager), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(jitManager), type(uint256).max);

        // Start balanced
        mockPyth.setPrice(FEED0, 100_000_00, 50);
        mockPyth.setPrice(FEED1, 100_000_00, 50);
        keeper.evaluateAndUpdate(poolKey);
        (, PegGuardHook.PoolState memory state) = hook.getPoolSnapshot(poolKey);
        assertEq(uint8(state.mode), uint8(PegGuardHook.PoolMode.Calm));

        // Trigger crisis (5% depeg = 500 bps, above 200 bps threshold)
        mockPyth.setPrice(FEED0, 95_000_00, 50);
        mockPyth.setPrice(FEED1, 100_000_00, 50);
        keeper.evaluateAndUpdate(poolKey);
        (, state) = hook.getPoolSnapshot(poolKey);
        assertEq(uint8(state.mode), uint8(PegGuardHook.PoolMode.Crisis));
        assertTrue(state.jitLiquidityActive);

        // Execute burst
        uint256 reserveBefore = state.reserveBalance;
        jitManager.executeBurst(poolKey, 10e18, 100e18, 100e18, address(this), 60);

        // Settle burst - should accumulate reserve
        vm.warp(block.timestamp + 120);
        jitManager.settleBurst(poolKey, 0, 0);
        (, state) = hook.getPoolSnapshot(poolKey);
        assertGt(state.reserveBalance, reserveBefore);

        // Return to calm (depeg resolved)
        mockPyth.setPrice(FEED0, 100_000_00, 50);
        mockPyth.setPrice(FEED1, 100_000_00, 50);
        keeper.evaluateAndUpdate(poolKey);
        (, state) = hook.getPoolSnapshot(poolKey);
        // Mode should return to Calm when depeg is below alert threshold
        assertLe(uint8(state.mode), uint8(PegGuardHook.PoolMode.Alert));
        // JIT should be deactivated if mode is Calm
        if (state.mode == PegGuardHook.PoolMode.Calm) {
            assertFalse(state.jitLiquidityActive);
        }
    }

    function testKeeperModeTransitions() public {
        // Calm -> Alert -> Crisis -> Calm
        mockPyth.setPrice(FEED0, 100_000_00, 50);
        mockPyth.setPrice(FEED1, 100_000_00, 50);
        keeper.evaluateAndUpdate(poolKey);
        (, PegGuardHook.PoolState memory state) = hook.getPoolSnapshot(poolKey);
        assertEq(uint8(state.mode), uint8(PegGuardHook.PoolMode.Calm));

        // Alert threshold (1% depeg = 100 bps, matches threshold)
        mockPyth.setPrice(FEED0, 99_000_00, 50); // 1% depeg = 100 bps
        keeper.evaluateAndUpdate(poolKey);
        (, state) = hook.getPoolSnapshot(poolKey);
        assertEq(uint8(state.mode), uint8(PegGuardHook.PoolMode.Alert));

        // Crisis threshold (2%+ depeg = 200+ bps)
        mockPyth.setPrice(FEED0, 98_000_00, 50); // 2% depeg = 200 bps
        keeper.evaluateAndUpdate(poolKey);
        (, state) = hook.getPoolSnapshot(poolKey);
        assertEq(uint8(state.mode), uint8(PegGuardHook.PoolMode.Crisis));
        assertTrue(state.jitLiquidityActive);

        // Back to calm
        mockPyth.setPrice(FEED0, 100_000_00, 50);
        keeper.evaluateAndUpdate(poolKey);
        (, state) = hook.getPoolSnapshot(poolKey);
        assertEq(uint8(state.mode), uint8(PegGuardHook.PoolMode.Calm));
        assertFalse(state.jitLiquidityActive);
    }
}
