// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {PegGuardKeeper} from "../src/PegGuardKeeper.sol";
import {PegGuardJITManager} from "../src/PegGuardJITManager.sol";

contract DeployKeeperAndJITScript is Script {
    function run() external {
        address hook = vm.envAddress("PEG_GUARD_HOOK");
        address positionManager = vm.envAddress("POSITION_MANAGER");
        address permit2 = vm.envAddress("PERMIT2");
        address treasury = vm.envOr("TREASURY", vm.envAddress("PEG_GUARD_ADMIN"));
        address admin = vm.envAddress("PEG_GUARD_ADMIN");

        vm.startBroadcast(admin);

        PegGuardKeeper keeper = new PegGuardKeeper(hook, admin);
        console2.log("PegGuardKeeper:", address(keeper));

        PegGuardJITManager jitManager = new PegGuardJITManager(hook, positionManager, permit2, treasury, admin);
        console2.log("PegGuardJITManager:", address(jitManager));

        vm.stopBroadcast();
    }
}

