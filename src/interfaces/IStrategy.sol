// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IStrategy {
    
    function deposit(address token, uint256 amount) external;
    function withdraw() external returns (uint256);
    function redeemYeild() external;
}