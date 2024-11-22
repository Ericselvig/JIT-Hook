// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IProtocol {
    
    function deposit(address user, uint256 amount) external;
    function withdraw(address user) external returns (uint256);
    function redeemYeild() external;
}