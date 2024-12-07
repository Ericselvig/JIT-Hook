// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {JITHook} from "../src/JITHook.sol";

// add mock pricefeed contract

contract JITHookTest is Test, Deployers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    Currency public token0;
    Currency public token1;
    JITHook public hook;
    // MockPriceFeed priceFeed0;
    // MockPriceFeed priceFeed1;

    function setUp() public {
        deployFreshManagerAndRouters();

        (token0, token1) = deployAndMint2Currencies();
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags);
        deployCodeTo("JITHook.sol", abi.encode(), hookAddress);
        hook = JITHook(hookAddress);

        MockERC20(Currency.unwrap(token0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(hook), type(uint256).max);

        // priceFeed0 = new MockPriceFeed();
        // priceFeed1 = new MockPriceFeed();
        // hook.setPriceFeeds(token0, priceFeed0);
        // hook.setPriceFeeds(token1, priceFeed1);

        // Initialize a pool with these two tokens
        (key,) = initPool(token0, token1, hook, 3000, SQRT_PRICE_1_1);
    }

    function test_deposit() public {
        uint256 depositAmount = 1e8;
        uint256 initialUserBalance = MockERC20(Currency.unwrap(token0)).balanceOf(address(this));
        uint256 initialHookBalance = MockERC20(Currency.unwrap(token0)).balanceOf(address(hook));
        // deposit
        hook.deposit(token0, depositAmount);

        // Get final balances
        uint256 finalUserBalance = MockERC20(Currency.unwrap(token0)).balanceOf(address(this));
        uint256 finalHookBalance = MockERC20(Currency.unwrap(token0)).balanceOf(address(hook));

        // Check token transfer
        assertEq(finalUserBalance, initialUserBalance - depositAmount);
        assertEq(finalHookBalance, initialHookBalance + depositAmount);

        // use mock pricefeed for amount of govTokens
        uint256 expectedGovTokens;
        assertEq(hook.govToken().balanceOf(address(this)), expectedGovTokens);
    }
}
