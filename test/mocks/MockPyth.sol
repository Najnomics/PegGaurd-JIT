// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractPyth} from "@pythnetwork/pyth-sdk-solidity/AbstractPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {PythErrors} from "@pythnetwork/pyth-sdk-solidity/PythErrors.sol";

contract MockPyth is AbstractPyth {
    mapping(bytes32 => PythStructs.PriceFeed) priceFeeds;
    uint64 public validTimePeriod = 3600;
    uint public singleUpdateFeeInWei = 0;

    function setPrice(bytes32 id, int64 price, uint64 conf) external {
        PythStructs.PriceFeed memory feed;
        feed.id = id;
        feed.price.price = price;
        feed.price.conf = conf;
        feed.price.expo = -8;
        feed.price.publishTime = block.timestamp;
        feed.emaPrice = feed.price;
        priceFeeds[id] = feed;
    }

    function queryPriceFeed(bytes32 id) public view override returns (PythStructs.PriceFeed memory) {
        if (priceFeeds[id].id == 0) revert PythErrors.PriceFeedNotFound();
        return priceFeeds[id];
    }

    function priceFeedExists(bytes32 id) public view override returns (bool) {
        return priceFeeds[id].id != 0;
    }

    function getValidTimePeriod() public view override returns (uint) {
        return validTimePeriod;
    }

    function getUpdateFee(bytes[] calldata) public view override returns (uint) {
        return singleUpdateFeeInWei;
    }

    function updatePriceFeeds(bytes[] calldata) public payable override {
        // Mock implementation - no-op for testing
    }

    function parsePriceFeedUpdates(
        bytes[] calldata,
        bytes32[] calldata priceIds,
        uint64,
        uint64
    ) external payable override returns (PythStructs.PriceFeed[] memory feeds) {
        feeds = new PythStructs.PriceFeed[](priceIds.length);
        for (uint i = 0; i < priceIds.length; i++) {
            if (priceFeedExists(priceIds[i])) {
                feeds[i] = queryPriceFeed(priceIds[i]);
            }
        }
    }
}
