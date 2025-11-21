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

contract ConfigurePegGuardScript is Script {
    using CurrencyLibrary for Currency;

    function run() external {
        address hookAddress = vm.envAddress("PEG_GUARD_HOOK");
        address keeperAddress = vm.envAddress("PEG_GUARD_KEEPER");
        address jitManagerAddress = vm.envAddress("PEG_GUARD_JIT_MANAGER");
        address deployer = vm.envAddress("PEG_GUARD_ADMIN");

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(vm.envAddress("POOL_CURRENCY0")),
            currency1: Currency.wrap(vm.envAddress("POOL_CURRENCY1")),
            fee: uint24(vm.envUint("POOL_FEE")),
            tickSpacing: int24(int256(vm.envInt("POOL_TICK_SPACING"))),
            hooks: IHooks(hookAddress)
        });

        vm.startBroadcast(deployer);

        PegGuardHook hook = PegGuardHook(hookAddress);
        hook.configurePool(poolKey, PegGuardHook.ConfigurePoolParams({
            priceFeedId0: vm.envBytes32("PRICE_FEED_ID0"),
            priceFeedId1: vm.envBytes32("PRICE_FEED_ID1"),
            baseFee: uint24(vm.envUint("POOL_BASE_FEE")),
            maxFee: uint24(vm.envUint("POOL_MAX_FEE")),
            minFee: uint24(vm.envUint("POOL_MIN_FEE"))
        }));

        PegGuardKeeper keeper = PegGuardKeeper(keeperAddress);
        keeper.setKeeperConfig(poolKey, PegGuardKeeper.KeeperConfig({
            alertBps: vm.envUint("KEEPER_ALERT_BPS"),
            crisisBps: vm.envUint("KEEPER_CRISIS_BPS"),
            jitActivationBps: vm.envUint("KEEPER_JIT_BPS"),
            modeCooldown: vm.envUint("KEEPER_MODE_COOLDOWN"),
            jitCooldown: vm.envUint("KEEPER_JIT_COOLDOWN")
        }));

        PegGuardJITManager jitManager = PegGuardJITManager(jitManagerAddress);
        jitManager.configurePool(poolKey, PegGuardJITManager.PoolJITConfig({
            tickLower: int24(int256(vm.envInt("JIT_TICK_LOWER"))),
            tickUpper: int24(int256(vm.envInt("JIT_TICK_UPPER"))),
            maxDuration: uint64(vm.envUint("JIT_MAX_DURATION")),
            reserveShareBps: vm.envUint("JIT_RESERVE_SHARE_BPS")
        }));

        vm.stopBroadcast();
    }
}
