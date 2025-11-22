// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title PegGuardReserveLib
/// @notice Library for reserve calculations and rebate logic
library PegGuardReserveLib {
    uint256 public constant MIN_RESERVE_CUT_BPS = 2000; // 20%
    uint256 public constant MAX_RESERVE_CUT_BPS = 5000; // 50%
    uint256 public constant MIN_REBATE_BPS = 500; // 0.05%
    uint256 public constant REBATE_SCALE_BPS = 10; // 0.001% per 10 bps reduction

    /// @notice Calculate rebate amount from reserve balance using Sentinel's logic
    /// @param reserveBalance The current reserve balance
    /// @param depegReductionBps The reduction in depeg (in basis points) achieved by the trade
    /// @return rebateAmount The calculated rebate amount in reserve token
    function calculateRebate(uint256 reserveBalance, uint256 depegReductionBps)
        internal
        pure
        returns (uint256 rebateAmount)
    {
        if (reserveBalance == 0) return 0;

        // Sentinel's rebate formula: MIN_REBATE_BPS + (depeg reduction * REBATE_SCALE_BPS)
        uint256 rebateBps = MIN_REBATE_BPS;
        if (depegReductionBps > 0) {
            rebateBps += (depegReductionBps / 10) * REBATE_SCALE_BPS;
        }

        // Calculate rebate amount from reserve balance
        rebateAmount = (reserveBalance * rebateBps) / 10_000;

        // Cap rebate at available reserve
        if (rebateAmount > reserveBalance) {
            rebateAmount = reserveBalance;
        }
    }

    /// @notice Clamp reserve cut to valid range
    /// @param cutBps The reserve cut in basis points
    /// @return The clamped reserve cut
    function clampReserveCut(uint256 cutBps) internal pure returns (uint256) {
        if (cutBps < MIN_RESERVE_CUT_BPS) return MIN_RESERVE_CUT_BPS;
        if (cutBps > MAX_RESERVE_CUT_BPS) return MAX_RESERVE_CUT_BPS;
        return cutBps;
    }
}

