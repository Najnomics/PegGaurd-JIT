// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title PegGuardLiquidityLib
/// @notice Library for liquidity enforcement logic
library PegGuardLiquidityLib {
    error UnauthorizedLiquidityProvider();

    /// @notice Enforce allowlist policy for liquidity operations
    /// @param isAllowlisted Whether the sender is allowlisted
    /// @param mustBeAllowlisted Whether allowlist enforcement is required
    function enforceAddPolicy(bool isAllowlisted, bool mustBeAllowlisted) internal pure {
        if (!mustBeAllowlisted) return;
        if (isAllowlisted) return;
        revert UnauthorizedLiquidityProvider();
    }
}

