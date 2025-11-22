// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {PegGuardHook} from "../src/PegGuardHook.sol";
import {PegGuardKeeper} from "../src/PegGuardKeeper.sol";
import {PegGuardJITManager} from "../src/PegGuardJITManager.sol";
import {AddressConstants} from "./constants/AddressConstants.sol";

contract ConfigurePegGuardScript is Script {
    using CurrencyLibrary for Currency;

    function run() external {
        address hookAddress = vm.envAddress("PEG_GUARD_HOOK");
        address keeperAddress = vm.envAddress("PEG_GUARD_KEEPER");
        address jitManagerAddress = vm.envAddress("PEG_GUARD_JIT_MANAGER");
        address deployer = vm.envAddress("PEG_GUARD_ADMIN");
        address positionManager = _tryEnvAddress("POSITION_MANAGER");

        uint24 poolFeeFlag = uint24(vm.envOr("POOL_KEY_FEE", uint256(LPFeeLibrary.DYNAMIC_FEE_FLAG)));

        // Support canonical addresses via env vars or fallback to direct addresses
        address currency0 = _getTokenAddress("POOL_CURRENCY0");
        address currency1 = _getTokenAddress("POOL_CURRENCY1");

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: poolFeeFlag,
            tickSpacing: int24(int256(vm.envInt("POOL_TICK_SPACING"))),
            hooks: IHooks(hookAddress)
        });

        vm.startBroadcast(deployer);

        PegGuardHook hook = PegGuardHook(hookAddress);
        hook.configurePool(
            poolKey,
            PegGuardHook.ConfigurePoolParams({
                priceFeedId0: vm.envBytes32("PRICE_FEED_ID0"),
                priceFeedId1: vm.envBytes32("PRICE_FEED_ID1"),
                baseFee: uint24(vm.envUint("POOL_BASE_FEE")),
                maxFee: uint24(vm.envUint("POOL_MAX_FEE")),
                minFee: uint24(vm.envUint("POOL_MIN_FEE")),
                reserveCutBps: vm.envOr("POOL_RESERVE_CUT_BPS", uint256(0)),
                volatilityThresholdBps: vm.envOr("POOL_VOLATILITY_THRESHOLD_BPS", uint256(0)),
                depegThresholdBps: vm.envOr("POOL_DEPEG_THRESHOLD_BPS", uint256(0))
            })
        );

        // Optional target tick range
        try vm.envInt("TARGET_TICK_LOWER") returns (int256 lowerRaw) {
            int24 lower = int24(lowerRaw);
            int24 upper = int24(int256(vm.envInt("TARGET_TICK_UPPER")));
            hook.setTargetRange(poolKey, lower, upper);
        } catch {}

        bool enforceAllowlist = vm.envOr("POOL_ENFORCE_ALLOWLIST", false);
        if (enforceAllowlist) {
            hook.setLiquidityPolicy(poolKey, enforceAllowlist);
        }
        hook.updateLiquidityAllowlist(poolKey, jitManagerAddress, true);
        hook.updateLiquidityAllowlist(poolKey, deployer, true);
        hook.updateLiquidityAllowlist(poolKey, keeperAddress, true);
        if (positionManager != address(0)) {
            hook.updateLiquidityAllowlist(poolKey, positionManager, true);
        }

        PegGuardKeeper keeper = PegGuardKeeper(keeperAddress);
        keeper.setKeeperConfig(
            poolKey,
            PegGuardKeeper.KeeperConfig({
                alertBps: vm.envUint("KEEPER_ALERT_BPS"),
                crisisBps: vm.envUint("KEEPER_CRISIS_BPS"),
                jitActivationBps: vm.envUint("KEEPER_JIT_BPS"),
                modeCooldown: vm.envUint("KEEPER_MODE_COOLDOWN"),
                jitCooldown: vm.envUint("KEEPER_JIT_COOLDOWN")
            })
        );

        PegGuardJITManager jitManager = PegGuardJITManager(jitManagerAddress);
        jitManager.configurePool(
            poolKey,
            PegGuardJITManager.PoolJITConfig({
                tickLower: int24(int256(vm.envInt("JIT_TICK_LOWER"))),
                tickUpper: int24(int256(vm.envInt("JIT_TICK_UPPER"))),
                maxDuration: uint64(vm.envUint("JIT_MAX_DURATION")),
                reserveShareBps: vm.envUint("JIT_RESERVE_SHARE_BPS")
            })
        );

        vm.stopBroadcast();
    }

    function _tryEnvAddress(string memory key) internal view returns (address value) {
        try vm.envAddress(key) returns (address addr) {
            value = addr;
        } catch {
            value = address(0);
        }
    }

    /// @notice Get token address from env var, with fallback to canonical addresses
    /// @dev Supports both direct addresses and token symbols (WETH, USDC, USDT, DAI)
    function _getTokenAddress(string memory key) internal view returns (address) {
        // Try to read as direct address first
        try vm.envAddress(key) returns (address addr) {
            return addr;
        } catch {
            // Try to read as token symbol and look up canonical address
            try vm.envString(key) returns (string memory symbol) {
                uint256 network = vm.envOr("NETWORK_ID", uint256(0)); // 0 = mainnet, 1 = sepolia
                return AddressConstants.getTokenAddress(network, symbol);
            } catch {
                revert(string.concat("ConfigurePegGuard: missing ", key));
            }
        }
    }
}
