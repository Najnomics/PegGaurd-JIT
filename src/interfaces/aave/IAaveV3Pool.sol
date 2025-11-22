// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IAaveV3Pool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;

    function ADDRESSES_PROVIDER() external view returns (address);
}
