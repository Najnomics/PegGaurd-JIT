// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title PegGuardFeeLib
/// @notice Library for fee calculations (depeg computation, mode premiums)
library PegGuardFeeLib {
    uint24 public constant ALERT_FEE_PREMIUM = 200; // 0.02%
    uint24 public constant CRISIS_FEE_PREMIUM = 600; // 0.06%
    uint24 public constant JIT_ACTIVE_PREMIUM = 100; // 0.01%

    /// @notice Compute depeg percentage in basis points
    /// @param price0 Price of token 0
    /// @param price1 Price of token 1
    /// @return depegBps Depeg percentage in basis points
    function computeDepegBps(int64 price0, int64 price1) internal pure returns (uint256 depegBps) {
        int256 diff = int256(price0) - int256(price1);
        if (diff < 0) diff = -diff;
        int256 denomSigned = int256(price1);
        uint256 denom = uint256(denomSigned >= 0 ? denomSigned : -denomSigned);
        if (denom == 0) denom = 1;
        return (uint256(diff) * 10_000) / denom;
    }

    /// @notice Get fee premium for a given pool mode (accepts uint8 to work with any enum)
    /// @param mode The pool mode as uint8 (0=Calm, 1=Alert, 2=Crisis)
    /// @return premium The fee premium in basis points
    function modePremium(uint8 mode) internal pure returns (uint24 premium) {
        if (mode == 1) return ALERT_FEE_PREMIUM; // Alert
        if (mode == 2) return CRISIS_FEE_PREMIUM; // Crisis
        return 0; // Calm
    }
}

