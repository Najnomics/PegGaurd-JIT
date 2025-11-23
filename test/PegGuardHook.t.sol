// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {PegGuardHook} from "../src/PegGuardHook.sol";
import {PythOracleAdapter} from "../src/oracle/PythOracleAdapter.sol";
import {PegGuardLiquidityLib} from "../src/libraries/PegGuardLiquidityLib.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract MintExecutor {
    using EasyPosm for IPositionManager;

    struct MintParams {
        PoolKey key;
        int24 lower;
        int24 upper;
        uint256 liquidity;
        uint256 amount0Max;
        uint256 amount1Max;
        address recipient;
        uint256 deadline;
        bytes hookData;
    }

    function mint(IPositionManager posm, MintParams calldata params)
        external
        returns (uint256 tokenId, BalanceDelta delta)
    {
        return posm.mint(
            params.key,
            params.lower,
            params.upper,
            params.liquidity,
            params.amount0Max,
            params.amount1Max,
            params.recipient,
            params.deadline,
            params.hookData
        );
    }
}

contract PegGuardHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;
    PoolId poolId;

    PegGuardHook hook;
    MintExecutor mintExecutor;
    MockPyth mockPyth;
    PythOracleAdapter adapter;

    uint256 positionTokenId;
    int24 tickLower;
    int24 tickUpper;

    bytes32 constant FEED_USDC = 0xd6aca1be9729c13d677335161321649cccae6a591554772516700f986f942eaa;
    bytes32 constant FEED_USDT = 0x8b1a1d9c2b109e527c9134b25b1a1833b16b6594f92daa9f6d9b7a6024bce9d0;

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
        require(address(hook) == expected, "PegGuardHookTest: hook address mismatch");

        mintExecutor = new MintExecutor();

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

        MintExecutor.MintParams memory initParams =
            _buildMintParams(poolKey, tickLower, tickUpper, liquidityAmount, amount0Expected + 1, amount1Expected + 1);
        (positionTokenId,) = _mintPosition(initParams);

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
        hook.setKeeperRole(address(this), true);
        hook.updateLiquidityAllowlist(poolKey, address(positionManager), true);

        _setPrices(1_000_000_00, 1_000_000_00, 100);
    }

    function testReturnsBaseFeeWhenPoolBalanced() public {
        _swap(true);
        (, PegGuardHook.PoolState memory state) = hook.getPoolSnapshot(poolKey);
        assertEq(state.lastOverrideFee, 3000);
    }

    function testPenaltyAppliedForWorseningTrade() public {
        _setPrices(980_000_00, 1_000_000_00, 50);
        _swap(true); // zeroForOne worsens under-peg token0
        (, PegGuardHook.PoolState memory state) = hook.getPoolSnapshot(poolKey);
        assertGt(state.lastOverrideFee, 3000);
    }

    function testRebateAppliedForHelpfulTrade() public {
        _setPrices(980_000_00, 1_000_000_00, 50);
        _swap(false);
        (, PegGuardHook.PoolState memory state) = hook.getPoolSnapshot(poolKey);
        assertLt(state.lastOverrideFee, 3000);
    }

    function testModePremiumApplied() public {
        hook.setPoolMode(poolKey, PegGuardHook.PoolMode.Alert);
        hook.setJITWindow(poolKey, true);
        _swap(true);
        (, PegGuardHook.PoolState memory state) = hook.getPoolSnapshot(poolKey);
        assertEq(state.lastOverrideFee, 3000 + hook.ALERT_FEE_PREMIUM() + hook.JIT_ACTIVE_PREMIUM());
    }

    function testReserveLifecycle() public {
        MockERC20 reserveToken = MockERC20(Currency.unwrap(currency0));
        uint256 amount = 1e18;
        reserveToken.approve(address(hook), amount);
        hook.fundReserve(poolKey, amount);
        (, PegGuardHook.PoolState memory state) = hook.getPoolSnapshot(poolKey);
        assertEq(state.reserveBalance, amount);

        hook.withdrawReserve(poolKey, address(this), amount / 2);
        (, state) = hook.getPoolSnapshot(poolKey);
        assertEq(state.reserveBalance, amount / 2);
    }

    function testIssueRebate() public {
        MockERC20 reserveToken = MockERC20(Currency.unwrap(currency0));
        uint256 amount = 2e18;
        reserveToken.approve(address(hook), amount);
        hook.fundReserve(poolKey, amount);
        hook.issueRebate(poolKey, address(0xBEEF), 1e18);
        (, PegGuardHook.PoolState memory state) = hook.getPoolSnapshot(poolKey);
        assertEq(state.reserveBalance, amount - 1e18);
        assertEq(state.totalRebates, 1e18);
        assertEq(reserveToken.balanceOf(address(0xBEEF)), 1e18);
    }

    function testCannotAddLiquidityWhenAllowlistEnforced() public {
        hook.setLiquidityPolicy(poolKey, true);
        (PegGuardHook.PoolConfig memory cfg,) = hook.getPoolSnapshot(poolKey);
        assertTrue(cfg.enforceAllowlist);
        hook.updateLiquidityAllowlist(poolKey, address(positionManager), false);
        assertFalse(hook.isAllowlisted(poolKey, address(positionManager)));

        uint128 liquidityAmount = 1e18;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        MintExecutor.MintParams memory denyParams =
            _buildMintParams(poolKey, tickLower, tickUpper, liquidityAmount, amount0Expected + 1, amount1Expected + 1);
        (bool denySuccess, bytes memory denyErr) = _delegateMint(denyParams);
        assertFalse(denySuccess, "expected allowlist revert");
        _assertBeforeAddLiquidityRevert(denyErr, PegGuardLiquidityLib.UnauthorizedLiquidityProvider.selector);

        hook.updateLiquidityAllowlist(poolKey, address(positionManager), true);
        assertTrue(hook.isAllowlisted(poolKey, address(positionManager)));
        MintExecutor.MintParams memory allowParams =
            _buildMintParams(poolKey, tickLower, tickUpper, liquidityAmount, amount0Expected + 1, amount1Expected + 1);
        _mintPosition(allowParams);
    }

    function testTargetRangeEnforcedDuringJIT() public {
        int24 targetLower = tickLower + poolKey.tickSpacing;
        int24 targetUpper = tickUpper - poolKey.tickSpacing;
        hook.setTargetRange(poolKey, targetLower, targetUpper);
        hook.updateLiquidityAllowlist(poolKey, address(positionManager), true);
        hook.setJITWindow(poolKey, true);

        uint128 liquidityAmount = 5e17;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        MintExecutor.MintParams memory jitParams =
            _buildMintParams(poolKey, tickLower, tickUpper, liquidityAmount, amount0Expected + 1, amount1Expected + 1);
        (bool jitSuccess, bytes memory jitErr) = _delegateMint(jitParams);
        assertFalse(jitSuccess, "expected target range revert");
        _assertBeforeAddLiquidityRevert(jitErr, PegGuardHook.TargetRangeViolation.selector);

        (uint256 allowedAmount0, uint256 allowedAmount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(targetLower),
            TickMath.getSqrtPriceAtTick(targetUpper),
            liquidityAmount
        );

        MintExecutor.MintParams memory allowedParams = _buildMintParams(
            poolKey, targetLower, targetUpper, liquidityAmount, allowedAmount0 + 1, allowedAmount1 + 1
        );
        _mintPosition(allowedParams);

        hook.setJITWindow(poolKey, false);
    }

    function _buildMintParams(
        PoolKey memory key,
        int24 lower,
        int24 upper,
        uint128 liquidity,
        uint256 amount0Max,
        uint256 amount1Max
    ) internal view returns (MintExecutor.MintParams memory params) {
        params.key = key;
        params.lower = lower;
        params.upper = upper;
        params.liquidity = liquidity;
        params.amount0Max = amount0Max;
        params.amount1Max = amount1Max;
        params.recipient = address(this);
        params.deadline = block.timestamp;
        params.hookData = Constants.ZERO_BYTES;
    }

    function _mintPosition(MintExecutor.MintParams memory params)
        internal
        returns (uint256 tokenId, BalanceDelta delta)
    {
        (bool success, bytes memory data) = _delegateMint(params);
        require(success, "mint failed");
        return abi.decode(data, (uint256, BalanceDelta));
    }

    function _delegateMint(MintExecutor.MintParams memory params) internal returns (bool success, bytes memory data) {
        return
            address(mintExecutor)
                .delegatecall(abi.encodeWithSelector(MintExecutor.mint.selector, positionManager, params));
    }

    function _assertBeforeAddLiquidityRevert(bytes memory err, bytes4 expectedInner) internal view {
        bytes4 outerSelector = bytes4(err);
        assertEq(outerSelector, CustomRevert.WrappedError.selector, "unexpected outer selector");

        bytes memory data = err;
        assembly {
            data := add(data, 0x04)
            mstore(data, sub(mload(data), 0x04))
        }

        (address target, bytes4 hookSelector, bytes memory revertReason, bytes memory context) =
            abi.decode(data, (address, bytes4, bytes, bytes));

        assertEq(target, address(hook), "unexpected hook target");
        assertEq(hookSelector, IHooks.beforeAddLiquidity.selector, "unexpected hook selector");
        require(revertReason.length >= 4, "missing inner selector");
        assertEq(bytes4(revertReason), expectedInner, "unexpected inner error");
        require(context.length >= 4, "missing context selector");
        assertEq(bytes4(context), Hooks.HookCallFailed.selector, "unexpected context selector");
    }

    function _swap(bool zeroForOne) internal returns (BalanceDelta swapDelta) {
        swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function _setPrices(int64 price0, int64 price1, uint64 confidence) internal {
        mockPyth.setPrice(FEED_USDC, price0, confidence);
        mockPyth.setPrice(FEED_USDT, price1, confidence);
    }
}
