// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {PegGuardHook} from "../src/PegGuardHook.sol";
import {PegGuardKeeper} from "../src/PegGuardKeeper.sol";
import {PegGuardJITManager} from "../src/PegGuardJITManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {AddressConstants as HookmateAddressConstants} from "hookmate/constants/AddressConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract UserFlowScript is Script {
    using CurrencyLibrary for Currency;

    uint24 internal constant DYNAMIC_FEE = 0x800000;
    int24 internal constant POOL_TICK_SPACING = 10;
    uint160 internal constant STARTING_PRICE = 79228162514264337593543950336; // 1.0 in Q64.96

    function run() external {
        address admin = vm.envAddress("PEG_GUARD_ADMIN");
        address hookAddr = vm.envAddress("PEG_GUARD_HOOK");
        address keeperAddr = vm.envAddress("PEG_GUARD_KEEPER");
        address jitAddr = vm.envAddress("PEG_GUARD_JIT_MANAGER");
        address positionManagerAddr = vm.envAddress("POSITION_MANAGER");
        address permit2Addr = vm.envAddress("PERMIT2");
        address payable routerAddr = payable(HookmateAddressConstants.getV4SwapRouterAddress(block.chainid));

        uint24 baseFee = uint24(vm.envUint("POOL_BASE_FEE"));
        uint24 maxFee = uint24(vm.envUint("POOL_MAX_FEE"));
        uint24 minFee = uint24(vm.envUint("POOL_MIN_FEE"));
        uint256 reserveCutBps = vm.envOr("POOL_RESERVE_CUT_BPS", uint256(0));
        uint256 volBps = vm.envOr("POOL_VOLATILITY_THRESHOLD_BPS", uint256(0));
        uint256 depegBps = vm.envOr("POOL_DEPEG_THRESHOLD_BPS", uint256(0));
        bytes32 priceId0 = vm.envBytes32("PRICE_FEED_ID0");
        bytes32 priceId1 = vm.envBytes32("PRICE_FEED_ID1");

        uint256 amountTokenA = vm.envOr("USERFLOW_LP_AMOUNT0", uint256(50_000 * 1e6));
        uint256 amountTokenB = vm.envOr("USERFLOW_LP_AMOUNT1", uint256(25 ether));

        PegGuardHook hook = PegGuardHook(hookAddr);
        PegGuardKeeper keeper = PegGuardKeeper(keeperAddr);
        PegGuardJITManager jit = PegGuardJITManager(jitAddr);
        IPositionManager positionManager = IPositionManager(positionManagerAddr);
        IPermit2 permit2 = IPermit2(permit2Addr);
        IUniswapV4Router04 router = IUniswapV4Router04(routerAddr);

        vm.startBroadcast(admin);

        // 1. Deploy test assets and mint inventory
        MockERC20 tokenA = new MockERC20("PegUSD", "PGUSD", 6);
        MockERC20 tokenB = new MockERC20("PegETH", "PGETH", 18);
        tokenA.mint(admin, 1_000_000 * 1e6);
        tokenB.mint(admin, 1_000 ether);
        console2.log("Deployed PegUSD at", address(tokenA));
        console2.log("Deployed PegETH at", address(tokenB));

        // Determine currency ordering by address
        MockERC20 token0Contract;
        MockERC20 token1Contract;
        uint256 amount0;
        uint256 amount1;
        if (address(tokenA) < address(tokenB)) {
            token0Contract = tokenA;
            token1Contract = tokenB;
            amount0 = amountTokenA;
            amount1 = amountTokenB;
        } else {
            token0Contract = tokenB;
            token1Contract = tokenA;
            amount0 = amountTokenB;
            amount1 = amountTokenA;
        }

        Currency currency0 = Currency.wrap(address(token0Contract));
        Currency currency1 = Currency.wrap(address(token1Contract));
        console2.log("Pool ordering currency0", Currency.unwrap(currency0), "currency1", Currency.unwrap(currency1));

        // 2. Approvals for Permit2 -> PositionManager & Router
        token0Contract.approve(permit2Addr, type(uint256).max);
        token1Contract.approve(permit2Addr, type(uint256).max);
        token0Contract.approve(positionManagerAddr, type(uint256).max);
        token1Contract.approve(positionManagerAddr, type(uint256).max);
        token0Contract.approve(routerAddr, type(uint256).max);
        token1Contract.approve(routerAddr, type(uint256).max);
        permit2.approve(address(token0Contract), positionManagerAddr, type(uint160).max, type(uint48).max);
        permit2.approve(address(token1Contract), positionManagerAddr, type(uint160).max, type(uint48).max);
        permit2.approve(address(token0Contract), routerAddr, type(uint160).max, type(uint48).max);
        permit2.approve(address(token1Contract), routerAddr, type(uint160).max, type(uint48).max);

        // 3. Initialize a new V4 pool wired to PegGuardHook
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: DYNAMIC_FEE,
            tickSpacing: POOL_TICK_SPACING,
            hooks: IHooks(hookAddr)
        });
        positionManager.initializePool(poolKey, STARTING_PRICE);
        PoolId poolId = poolKey.toId();

        // 4. Configure PegGuard for the new pool & enforce allowlist policy
        hook.configurePool(
            poolKey,
            PegGuardHook.ConfigurePoolParams({
                priceFeedId0: priceId0,
                priceFeedId1: priceId1,
                baseFee: baseFee,
                maxFee: maxFee,
                minFee: minFee,
                reserveCutBps: reserveCutBps,
                volatilityThresholdBps: volBps,
                depegThresholdBps: depegBps
            })
        );
        hook.setLiquidityPolicy(poolKey, true);
        hook.updateLiquidityAllowlist(poolKey, positionManagerAddr, true);
        hook.updateLiquidityAllowlist(poolKey, routerAddr, true);
        hook.updateLiquidityAllowlist(poolKey, admin, true);

        // 5. Program keeper + JIT policies for the pool
        PegGuardKeeper.KeeperConfig memory keeperCfg = PegGuardKeeper.KeeperConfig({
            alertBps: vm.envUint("KEEPER_ALERT_BPS"),
            crisisBps: vm.envUint("KEEPER_CRISIS_BPS"),
            jitActivationBps: vm.envUint("KEEPER_JIT_BPS"),
            modeCooldown: vm.envUint("KEEPER_MODE_COOLDOWN"),
            jitCooldown: vm.envUint("KEEPER_JIT_COOLDOWN")
        });
        keeper.setKeeperConfig(poolKey, keeperCfg);

        PegGuardJITManager.PoolJITConfig memory jitCfg = PegGuardJITManager.PoolJITConfig({
            tickLower: int24(int256(vm.envInt("JIT_TICK_LOWER"))),
            tickUpper: int24(int256(vm.envInt("JIT_TICK_UPPER"))),
            maxDuration: uint64(vm.envUint("JIT_MAX_DURATION")),
            reserveShareBps: vm.envUint("JIT_RESERVE_SHARE_BPS")
        });
        jit.configurePool(poolKey, jitCfg);
        hook.setTargetRange(poolKey, jitCfg.tickLower, jitCfg.tickUpper);
        _logSnapshot(hook, poolKey, "Configured pool");

        // 6. Add liquidity via PositionManager
        uint160 sqrtPriceX96 = STARTING_PRICE;
        int24 midTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int24 tickLower = _truncateTick(midTick - 600, POOL_TICK_SPACING);
        int24 tickUpper = _truncateTick(midTick + 600, POOL_TICK_SPACING);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtLower, sqrtUpper, amount0, amount1);

        bytes memory hookData = bytes("");
        bytes memory actions = abi.encodePacked(
            uint8(uint256(Actions.MINT_POSITION)),
            uint8(uint256(Actions.SETTLE_PAIR)),
            uint8(uint256(Actions.SWEEP)),
            uint8(uint256(Actions.SWEEP))
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0, amount1, admin, hookData);
        params[1] = abi.encode(currency0, currency1);
        params[2] = abi.encode(currency0, admin);
        params[3] = abi.encode(currency1, admin);

        bytes memory unlock = abi.encode(actions, params);
        positionManager.modifyLiquidities(unlock, block.timestamp + 1 hours);

        // Optional reserve top-up (requires admin to hold the hook's reserve token on this chain)
        uint256 reserveTopUp = vm.envOr("USERFLOW_RESERVE_AMOUNT", uint256(0));
        if (reserveTopUp > 0) {
            address reserveToken = hook.reserveToken();
            IERC20(reserveToken).approve(hookAddr, reserveTopUp);
            hook.fundReserve(poolKey, reserveTopUp);
            console2.log("Funded hook reserve with", reserveTopUp, "units of", reserveToken);
        }

        // 7. Execute a single-pool swap through the hooked pool
        bool zeroForOne = Currency.unwrap(currency0) == address(token0Contract);
        uint256 amountIn = zeroForOne
            ? vm.envOr("USERFLOW_SWAP_AMOUNT0", uint256(10_000 * 1e6))
            : vm.envOr("USERFLOW_SWAP_AMOUNT1", uint256(2 ether));
        router.swapExactTokensForTokens(amountIn, 0, zeroForOne, poolKey, hookData, admin, block.timestamp + 5 minutes);
        console2.log("Swap executed zeroForOne?", zeroForOne, "amountIn", amountIn);

        // 8. Ask the keeper to evaluate & broadcast a mode update for the new pool
        keeper.evaluateAndUpdate(poolKey);
        _logSnapshot(hook, poolKey, "Post-swap & keeper");

        // Optionally seed the JIT manager and run a flash burst to demonstrate rapid response
        uint256 jitSeed0 = vm.envOr("USERFLOW_JIT_FUND_TOKEN0", uint256(0));
        uint256 jitSeed1 = vm.envOr("USERFLOW_JIT_FUND_TOKEN1", uint256(0));
        if (jitSeed0 > 0) {
            token0Contract.transfer(jitAddr, jitSeed0);
            console2.log("Seeded JIT manager with", jitSeed0, "of token0");
        }
        if (jitSeed1 > 0) {
            token1Contract.transfer(jitAddr, jitSeed1);
            console2.log("Seeded JIT manager with", jitSeed1, "of token1");
        }

        uint128 jitLiquidity = uint128(uint256(vm.envOr("USERFLOW_JIT_LIQUIDITY", uint256(0))));
        uint256 jitAmount0Max = vm.envOr("USERFLOW_JIT_AMOUNT0_MAX", uint256(0));
        uint256 jitAmount1Max = vm.envOr("USERFLOW_JIT_AMOUNT1_MAX", uint256(0));
        if (jitLiquidity > 0) {
            try jit.flashBurst(poolKey, jitLiquidity, jitAmount0Max, jitAmount1Max, address(0), bytes("")) returns (
                uint256 spent0, uint256 spent1, uint256 out0, uint256 out1
            ) {
                console2.log("Flash burst complete");
                console2.log("  token0 spent/out", spent0, out0);
                console2.log("  token1 spent/out", spent1, out1);
            } catch (bytes memory err) {
                console2.log("Flash burst reverted, raw error:");
                console2.logBytes(err);
            }
        }

        vm.stopBroadcast();

        console2.log("Test pool currency0", Currency.unwrap(currency0));
        console2.log("Test pool currency1", Currency.unwrap(currency1));
        console2.logBytes32(PoolId.unwrap(poolId));
    }

    function _truncateTick(int24 tick, int24 spacing) internal pure returns (int24) {
        return (tick / spacing) * spacing;
    }

    function _logSnapshot(PegGuardHook hook, PoolKey memory key, string memory label) internal {
        (PegGuardHook.PoolConfig memory cfg, PegGuardHook.PoolState memory st) = hook.getPoolSnapshot(key);
        console2.log("----", label, "----");
        console2.log("Mode", uint256(st.mode), "JIT active", st.jitLiquidityActive);
        console2.log("Base/Min/Max fees", cfg.baseFee, cfg.minFee, cfg.maxFee);
        console2.log("ReserveBalance", st.reserveBalance, "LastOverrideFee", st.lastOverrideFee);
    }
}

