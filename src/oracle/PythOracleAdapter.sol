// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

/// @notice Lightweight adapter around Pyth price feeds that exposes normalized helpers
/// used by the PegGuard hook.
contract PythOracleAdapter {
    IPyth public immutable pyth;

    uint256 public maxStaleness = 60; // seconds

    error StalePrice();

    constructor(address _pyth) {
        pyth = IPyth(_pyth);
    }

    function getPriceWithConfidence(bytes32 priceFeedId)
        external
        view
        returns (int64 price, uint64 conf, uint256 publishTime)
    {
        PythStructs.Price memory pythPrice = pyth.getPriceUnsafe(priceFeedId);
        if (block.timestamp - pythPrice.publishTime > maxStaleness) revert StalePrice();
        return (pythPrice.price, pythPrice.conf, pythPrice.publishTime);
    }

    function computeConfRatioBps(int64 price, uint64 conf) external pure returns (uint256) {
        if (price == 0) return 0;
        uint256 absPrice = price > 0 ? uint256(uint64(price)) : uint256(uint64(-price));
        return (uint256(conf) * 10_000) / absPrice;
    }

    function setMaxStaleness(uint256 _maxStaleness) external {
        maxStaleness = _maxStaleness;
    }
}
