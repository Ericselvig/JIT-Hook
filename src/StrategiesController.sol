// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IStrategiesController} from "./interfaces/IStrategiesController.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

contract StrategiesController is Ownable, IStrategiesController {
    error StrategyAlreadyExists();

    mapping(uint256 id => address) private _strategies;

    constructor() Ownable(msg.sender) {}

    function addStrategy(uint256 id, address strategy) external onlyOwner {
        if (_strategies[id] != address(0)) {
            revert StrategyAlreadyExists();
        }
        _strategies[id] = strategy;
    }

    function removeStrategy(uint256 id) external onlyOwner {
        delete _strategies[id];
    }

    function getStrategyAddress(uint256 _id) external view returns (address) {
        return _strategies[_id];
    }
}
