// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {BaseTest} from "./utils/BaseTest.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {PegGuardHook} from "../src/PegGuardHook.sol";
import {PegGuardJITManager} from "../src/PegGuardJITManager.sol";
import {PythOracleAdapter} from "../src/oracle/PythOracleAdapter.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract PegGuardJITManagerTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using EasyPosm for IPositionManager;

    Currency currency0;
    Currency currency1;
    address token0;
    address token1;

    PoolKey poolKey;
    PoolId poolId;

    PegGuardHook hook;
    PegGuardJITManager jitManager;
    MockPyth mockPyth;
    PythOracleAdapter adapter;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        token0 = Currency.unwrap(currency0);
        token1 = Currency.unwrap(currency1);

        mockPyth = new MockPyth();
        adapter = new PythOracleAdapter(address(mockPyth));

        address flags = address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG) ^ (0x9999 << 144));
        bytes memory constructorArgs = abi.encode(poolManager, address(adapter), token1, address(this));
        deployCodeTo("PegGuardHook.sol:PegGuardHook", constructorArgs, flags);
        hook = PegGuardHook(flags);

        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        uint128 liquidityAmount = 100e18;
        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

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
            priceFeedId0: bytes32("USDC"), priceFeedId1: bytes32("DAI"), baseFee: 3000, maxFee: 50_000, minFee: 500
        });
        hook.configurePool(poolKey, params);

        jitManager = new PegGuardJITManager(
            address(hook), address(positionManager), address(permit2), address(this), address(this)
        );
        hook.grantRole(hook.KEEPER_ROLE(), address(jitManager));
        hook.updateLiquidityAllowlist(poolKey, address(jitManager), true);
        hook.updateLiquidityAllowlist(poolKey, address(this), true);

        PegGuardJITManager.PoolJITConfig memory cfg = PegGuardJITManager.PoolJITConfig({
            tickLower: tickLower, tickUpper: tickUpper, maxDuration: 1 hours, reserveShareBps: 1000
        });
        jitManager.configurePool(poolKey, cfg);

        MockERC20(token0).approve(address(jitManager), type(uint256).max);
        MockERC20(token1).approve(address(jitManager), type(uint256).max);
    }

    function testBurstLifecycleStreamsReserveShare() public {
        uint256 funderToken0Before = IERC20(token0).balanceOf(address(this));
        uint256 funderToken1Before = IERC20(token1).balanceOf(address(this));

        jitManager.executeBurst(poolKey, 10e18, 1_000e18, 1_000e18, address(this), 30 minutes);
        (, PegGuardHook.PoolState memory stateAfterBurst) = hook.getPoolSnapshot(poolKey);
        assertTrue(stateAfterBurst.jitLiquidityActive);

        vm.warp(block.timestamp + 31 minutes);
        jitManager.settleBurst(poolKey, 0, 0);

        (, PegGuardHook.PoolState memory finalState) = hook.getPoolSnapshot(poolKey);
        assertFalse(finalState.jitLiquidityActive);
        assertTrue(finalState.reserveBalance > 0);

        assertGe(IERC20(token0).balanceOf(address(this)), funderToken0Before - 1);
        assertGe(IERC20(token1).balanceOf(address(this)), funderToken1Before - 1);
    }
}
