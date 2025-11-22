// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {PegGuardFlashBorrower} from "../src/flash/PegGuardFlashBorrower.sol";
import {AddressConstants} from "./constants/AddressConstants.sol";

contract DeployFlashBorrowerScript is Script {
    function run() external {
        address jitManager = vm.envAddress("PEG_GUARD_JIT_MANAGER");
        address admin = vm.envAddress("PEG_GUARD_ADMIN");

        // Support canonical Aave address or direct env var
        address aavePool;
        try vm.envAddress("AAVE_POOL") returns (address pool) {
            aavePool = pool;
        } catch {
            uint256 network = vm.envOr("NETWORK_ID", uint256(0));
            aavePool = AddressConstants.getAavePool(network);
        }

        vm.startBroadcast(admin);
        PegGuardFlashBorrower borrower = new PegGuardFlashBorrower(jitManager, aavePool, admin);
        vm.stopBroadcast();

        console2.log("PegGuardFlashBorrower:", address(borrower));
        console2.log("Aave Pool:", aavePool);
    }
}
