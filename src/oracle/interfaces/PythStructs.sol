// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library PythStructs {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }
}
