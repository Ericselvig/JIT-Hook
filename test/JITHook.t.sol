// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {PositionDescriptor} from "v4-periphery/src/PositionDescriptor.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {JITHook} from "../src/JITHook.sol";
import {StrategiesController} from "../src/StrategiesController.sol";

// add mock pricefeed contract

contract JITHookTest is Test, Deployers, DeployPermit2 {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    IWETH9 public _WETH9 = IWETH9(address(new WETH()));

    Currency public token0;
    Currency public token1;
    JITHook public hook;
    PositionManager posm;
    // MockPriceFeed priceFeed0;
    // MockPriceFeed priceFeed1;

    uint256 constant THRESHOLD = 1e6 * 1e8;

    function setUp() public {
        StrategiesController controller = new StrategiesController();

        deployFreshManagerAndRouters();
        deployPosm();

        //(token0, token1) = deployAndMint2Currencies();
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags);
        deployCodeTo(
            "JITHook.sol",
            abi.encode(
                address(manager),
                address(controller),
                THRESHOLD,
                address(posm)
            ),
            hookAddress
        );
        hook = JITHook(hookAddress);

        MockERC20(Currency.unwrap(token0)).approve(
            address(hook),
            type(uint256).max
        );
        MockERC20(Currency.unwrap(token1)).approve(
            address(hook),
            type(uint256).max
        );

        // priceFeed0 = new MockPriceFeed();
        // priceFeed1 = new MockPriceFeed();
        // hook.setPriceFeeds(token0, priceFeed0);
        // hook.setPriceFeeds(token1, priceFeed1);

        // Initialize a pool with these two tokens
        (key, ) = initPool(token0, token1, hook, 3000, SQRT_PRICE_1_1);
    }

    function deployPosm() internal {
        IAllowanceTransfer permit2 = IAllowanceTransfer(deployPermit2());
        PositionDescriptor positionDescriptor = new PositionDescriptor(
            manager,
            0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
            "ETH"
        );
        posm = new PositionManager(
            manager,
            permit2,
            100_000,
            positionDescriptor,
            _WETH9
        );
    }

    function test_deposit() public {
        uint256 depositAmount = 1e8;
        uint256 initialUserBalance = MockERC20(Currency.unwrap(token0))
            .balanceOf(address(this));
        uint256 initialHookBalance = MockERC20(Currency.unwrap(token0))
            .balanceOf(address(hook));
        // deposit
        hook.deposit(token0, depositAmount);

        // Get final balances
        uint256 finalUserBalance = MockERC20(Currency.unwrap(token0)).balanceOf(
            address(this)
        );
        uint256 finalHookBalance = MockERC20(Currency.unwrap(token0)).balanceOf(
            address(hook)
        );

        // Check token transfer
        assertEq(finalUserBalance, initialUserBalance - depositAmount);
        assertEq(finalHookBalance, initialHookBalance + depositAmount);

        // use mock pricefeed for amount of govTokens
        uint256 expectedGovTokens;
        assertEq(
            hook.govToken().balanceOf(address(this)),
            expectedGovTokens
        );
    }
}
