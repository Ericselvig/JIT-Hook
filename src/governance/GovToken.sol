// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

contract GovToken is ERC20 {
    constructor(
        string memory name,
        string memory symbol
    ) ERC20(name, symbol, 18) {}
}