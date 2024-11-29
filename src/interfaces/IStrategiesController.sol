// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IStrategiesController {
    function addStrategy(uint256 id, address strategy) external;
    function removeStrategy(uint256 id) external;
    function getStrategyAddress(uint256 _id) external view returns (address);
}
