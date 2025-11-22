// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract PegGuardFeeHelper {
    struct FeeComputation {
        uint24 feeFloor;
        uint24 maxFee;
        uint24 minFee;
        uint256 reserveCutBps;
        uint256 depegBps;
        bool worsensDepeg;
    }

    struct FeeResult {
        uint24 dynamicFee;
        uint24 feeDelta;
        uint256 reserveAmount;
        bool isPenalty;
    }

    function compute(FeeComputation calldata input) external pure returns (FeeResult memory result) {
        if (input.worsensDepeg) {
            uint24 penalty = uint24((input.depegBps / 10) * 100);
            result.dynamicFee = input.feeFloor + penalty;
            if (result.dynamicFee > input.maxFee) result.dynamicFee = input.maxFee;
            if (result.dynamicFee > input.feeFloor) {
                result.feeDelta = result.dynamicFee - input.feeFloor;
            }
            result.reserveAmount = (uint256(result.feeDelta) * input.reserveCutBps) / 10_000;
            result.isPenalty = true;
        } else {
            uint24 rebate = uint24((input.depegBps / 20) * 50);
            uint24 dynamicFee;
            if (rebate >= input.feeFloor || input.feeFloor - rebate < input.minFee) {
                dynamicFee = input.minFee;
            } else {
                dynamicFee = input.feeFloor - rebate;
            }
            if (dynamicFee < input.minFee) dynamicFee = input.minFee;
            result.dynamicFee = dynamicFee;
            if (input.feeFloor > dynamicFee) {
                result.feeDelta = input.feeFloor - dynamicFee;
            }
        }
    }
}

