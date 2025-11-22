// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Interface for external actors triggered during a flash burst.
interface IBurstExecutor {
    function onBurst(bytes calldata data) external;
}
