// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IFlashLoanSimpleReceiver {
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool);

    function ADDRESSES_PROVIDER() external view returns (address);

    function POOL() external view returns (address);
}
