// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {PegGuardHook} from "../src/PegGuardHook.sol";
import {PegGuardKeeper} from "../src/PegGuardKeeper.sol";
import {PegGuardJITManager} from "../src/PegGuardJITManager.sol";

/// @notice Deploys and configures multiple PegGuard pools from a JSON config file
/// @dev JSON format:
/// {
///   "pools": [
///     {
///       "currency0": "0x...",
///       "currency1": "0x...",
///       "fee": 8388608,
///       "tickSpacing": 60,
///       "priceFeedId0": "0x...",
///       "priceFeedId1": "0x...",
///       "baseFee": 3000,
///       "maxFee": 50000,
///       "minFee": 500,
///       "reserveCutBps": 2000,
///       "volatilityThresholdBps": 100,
///       "depegThresholdBps": 50,
///       "targetTickLower": -600,
///       "targetTickUpper": 600,
///       "enforceAllowlist": false,
///       "keeper": {
///         "alertBps": 100,
///         "crisisBps": 200,
///         "jitActivationBps": 150,
///         "modeCooldown": 300,
///         "jitCooldown": 60
///       },
///       "jit": {
///         "tickLower": -300,
///         "tickUpper": 300,
///         "maxDuration": 3600,
///         "reserveShareBps": 1000
///       }
///     }
///   ]
/// }
contract MultiPoolDeployScript is Script {
    using CurrencyLibrary for Currency;

    struct PoolConfig {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        bytes32 priceFeedId0;
        bytes32 priceFeedId1;
        uint24 baseFee;
        uint24 maxFee;
        uint24 minFee;
        uint256 reserveCutBps;
        uint256 volatilityThresholdBps;
        uint256 depegThresholdBps;
        int24 targetTickLower;
        int24 targetTickUpper;
        bool enforceAllowlist;
        KeeperConfig keeper;
        JITConfig jit;
    }

    struct KeeperConfig {
        uint256 alertBps;
        uint256 crisisBps;
        uint256 jitActivationBps;
        uint256 modeCooldown;
        uint256 jitCooldown;
    }

    struct JITConfig {
        int24 tickLower;
        int24 tickUpper;
        uint64 maxDuration;
        uint256 reserveShareBps;
    }

    function run() external {
        address hookAddress = vm.envAddress("PEG_GUARD_HOOK");
        address keeperAddress = vm.envAddress("PEG_GUARD_KEEPER");
        address jitManagerAddress = vm.envAddress("PEG_GUARD_JIT_MANAGER");
        address deployer = vm.envAddress("PEG_GUARD_ADMIN");
        address positionManager = vm.envOr("POSITION_MANAGER", address(0));

        string memory configPath = vm.envString("POOL_CONFIG_JSON");
        string memory configJson = vm.readFile(configPath);
        bytes memory configBytes = vm.parseJson(configJson);

        PoolConfig[] memory pools = abi.decode(configBytes, (PoolConfig[]));

        vm.startBroadcast(deployer);

        PegGuardHook hook = PegGuardHook(hookAddress);
        PegGuardKeeper keeper = PegGuardKeeper(keeperAddress);
        PegGuardJITManager jitManager = PegGuardJITManager(jitManagerAddress);

        for (uint256 i = 0; i < pools.length; i++) {
            PoolConfig memory pool = pools[i];
            console2.log("Configuring pool", i);

            PoolKey memory poolKey = PoolKey({
                currency0: Currency.wrap(pool.currency0),
                currency1: Currency.wrap(pool.currency1),
                fee: pool.fee == 0 ? LPFeeLibrary.DYNAMIC_FEE_FLAG : pool.fee,
                tickSpacing: pool.tickSpacing,
                hooks: IHooks(hookAddress)
            });

            // Configure hook
            hook.configurePool(
                poolKey,
                PegGuardHook.ConfigurePoolParams({
                    priceFeedId0: pool.priceFeedId0,
                    priceFeedId1: pool.priceFeedId1,
                    baseFee: pool.baseFee,
                    maxFee: pool.maxFee,
                    minFee: pool.minFee,
                    reserveCutBps: pool.reserveCutBps,
                    volatilityThresholdBps: pool.volatilityThresholdBps,
                    depegThresholdBps: pool.depegThresholdBps
                })
            );

            // Set target range if specified
            if (pool.targetTickLower != 0 || pool.targetTickUpper != 0) {
                hook.setTargetRange(poolKey, pool.targetTickLower, pool.targetTickUpper);
            }

            // Configure allowlist
            if (pool.enforceAllowlist) {
                hook.setLiquidityPolicy(poolKey, true);
            }
            hook.updateLiquidityAllowlist(poolKey, jitManagerAddress, true);
            hook.updateLiquidityAllowlist(poolKey, deployer, true);
            hook.updateLiquidityAllowlist(poolKey, keeperAddress, true);
            if (positionManager != address(0)) {
                hook.updateLiquidityAllowlist(poolKey, positionManager, true);
            }

            // Configure keeper
            keeper.setKeeperConfig(
                poolKey,
                PegGuardKeeper.KeeperConfig({
                    alertBps: pool.keeper.alertBps,
                    crisisBps: pool.keeper.crisisBps,
                    jitActivationBps: pool.keeper.jitActivationBps,
                    modeCooldown: pool.keeper.modeCooldown,
                    jitCooldown: pool.keeper.jitCooldown
                })
            );

            // Configure JIT manager
            jitManager.configurePool(
                poolKey,
                PegGuardJITManager.PoolJITConfig({
                    tickLower: pool.jit.tickLower,
                    tickUpper: pool.jit.tickUpper,
                    maxDuration: pool.jit.maxDuration,
                    reserveShareBps: pool.jit.reserveShareBps
                })
            );

            console2.log("Pool configured:", i);
        }

        vm.stopBroadcast();
    }
}

