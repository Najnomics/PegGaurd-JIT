// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPyth} from "../../src/oracle/interfaces/IPyth.sol";
import {PythStructs} from "../../src/oracle/interfaces/PythStructs.sol";

contract MockPyth is IPyth {
    mapping(bytes32 => PythStructs.Price) public prices;

    function setPrice(bytes32 id, int64 price, uint64 conf) external {
        prices[id] = PythStructs.Price({price: price, conf: conf, expo: -8, publishTime: block.timestamp});
    }

    function getPriceUnsafe(bytes32 id) external view returns (PythStructs.Price memory) {
        PythStructs.Price memory price = prices[id];
        require(price.publishTime != 0, "MockPyth: price not set");
        return price;
    }
}
