// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PythStructs} from "./PythStructs.sol";

interface IPyth {
    function getPriceUnsafe(bytes32 id) external view returns (PythStructs.Price memory);
}
