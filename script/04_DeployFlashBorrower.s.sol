// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {PegGuardFlashBorrower} from "../src/flash/PegGuardFlashBorrower.sol";

contract DeployFlashBorrowerScript is Script {
    function run() external {
        address jitManager = vm.envAddress("PEG_GUARD_JIT_MANAGER");
        address aavePool = vm.envAddress("AAVE_POOL");
        address admin = vm.envAddress("PEG_GUARD_ADMIN");

        vm.startBroadcast(admin);
        PegGuardFlashBorrower borrower = new PegGuardFlashBorrower(jitManager, aavePool, admin);
        vm.stopBroadcast();

        console2.log("PegGuardFlashBorrower:", address(borrower));
    }
}
