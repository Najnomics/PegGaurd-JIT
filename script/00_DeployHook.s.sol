// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {BaseScript} from "./base/BaseScript.sol";

import {PegGuardHook} from "../src/PegGuardHook.sol";

/// @notice Mines the address and deploys the PegGuardHook contract
contract DeployHookScript is BaseScript {
    function _envOrAddress(string memory key, address fallbackValue) internal view returns (address) {
        try vm.envAddress(key) returns (address value) {
            return value;
        } catch {
            return fallbackValue;
        }
    }

    function run() public {
        address pythAdapter = _envOrAddress("PYTH_ADAPTER", address(0));
        address reserveToken = _envOrAddress("RESERVE_TOKEN", address(0));
        address admin = _envOrAddress("PEG_GUARD_ADMIN", deployerAddress);

        require(pythAdapter != address(0), "DeployHookScript: PYTH_ADAPTER env missing");
        require(reserveToken != address(0), "DeployHookScript: RESERVE_TOKEN env missing");

        // hook contracts must have specific flags encoded in the address
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        // Mine a salt that will produce a hook address with the correct flags
        bytes memory constructorArgs = abi.encode(poolManager, pythAdapter, reserveToken, admin);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(PegGuardHook).creationCode, constructorArgs);

        // Deploy the hook using CREATE2
        vm.startBroadcast();
        PegGuardHook hook = new PegGuardHook{salt: salt}(poolManager, pythAdapter, reserveToken, admin);
        vm.stopBroadcast();

        require(address(hook) == hookAddress, "DeployHookScript: Hook Address Mismatch");
    }
}
