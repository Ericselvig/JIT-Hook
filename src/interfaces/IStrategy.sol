// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IStrategy {
    function deposit(address token, uint256 amount) external;
    function withdraw(address token, uint256 amount) external returns (uint256);
    function getBalance(address token0, address token1) external view returns (uint256, uint256);
    function redeemYeild() external;
}
