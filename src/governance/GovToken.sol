// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

contract GovToken is ERC20, Owned {
    error Not_Allowed();

    constructor(string memory name, string memory symbol) ERC20(name, symbol, 18) Owned(msg.sender) {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        revert Not_Allowed();
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        revert Not_Allowed();
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        revert Not_Allowed();
    }
}
