// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IStrategiesController} from "./interfaces/IStrategiesController.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {GovToken} from "./governance/GovToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title JITHook
 * @notice The main hook to facilitate JIT liquidity provision and yield farming
 * @author Yash Goyal & Naman Mohnani
 */
contract JITHook is BaseHook, Owned {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    mapping(Currency currency => AggregatorV3Interface priceFeed) priceFeeds;

    uint256 public swapThreshold; // swap threshold in USD (8 decimals)
    IStrategiesController public controller;
    IPositionManager public positionManager;
    uint256 public currentPositionId;
    uint256 public currentActiveStrategyId;
    GovToken public govToken;

    constructor(
        IPoolManager _manager,
        address _strategiesController,
        uint256 _threshold,
        address _posManager
    ) BaseHook(_manager) Owned(msg.sender) {
        controller = IStrategiesController(_strategiesController);
        swapThreshold = _threshold;
        positionManager = IPositionManager(_posManager);
        govToken = new GovToken("GovTkn", "GVT");
    }

    /**
     * @notice set the chainlink price feeds for the given currency
     * @param currency the currency for which the price feed is to be set
     * @param priceFeed the address of the chainlink price feed
     */
    function setPriceFeed(
        Currency currency,
        address priceFeed
    ) external onlyOwner {
        priceFeeds[currency] = AggregatorV3Interface(priceFeed);
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    /**
     * @dev detect big swap and provide liquidity to the pool
     */
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        if (msg.sender == address(this)) {
            return (
                this.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                0
            );
        }

        if (_getSwapAmount(key, params) >= swapThreshold) {
            (
                uint256 amount0ToAddInPool,
                uint256 amount1ToAddInPool
            ) = _withdrawAndSwap(key);

            (, int24 tick, , ) = StateLibrary.getSlot0(poolManager, key.toId());

            _addLiquidityToPool(
                key,
                tick - key.tickSpacing,
                tick + key.tickSpacing,
                uint128(amount0ToAddInPool),
                uint128(amount1ToAddInPool)
            );
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @dev remove liquidity from pool and deposit to strategy
     */
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        _removeLiquidityFromPool();
        _depositToStrategy(
            currentActiveStrategyId,
            key.currency0,
            IERC20(Currency.unwrap(key.currency0)).balanceOf(address(this))
        );
        _depositToStrategy(
            currentActiveStrategyId,
            key.currency1,
            IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this))
        );

        return (this.afterSwap.selector, 0);
    }

    /**
     * @notice deposit funds to the hook to be used in JIT Liquidity provision
     * @param currency the currency to be deposited
     * @param amount the amount to be deposited
     * @dev mints USD equivalent of govTokens
     */
    function deposit(Currency currency, uint256 amount) external {
        ERC20(Currency.unwrap(currency)).transferFrom(
            msg.sender,
            address(this),
            amount
        );

        if (amount > 0) {
            (, int256 price, , , ) = priceFeeds[currency].latestRoundData();
            uint256 usdValue = (uint256(price) * amount) / 1e8;
            _depositToStrategy(currentActiveStrategyId, currency, amount);
            govToken.mint(msg.sender, usdValue);
        }
    }

    /**
     * @notice withdraw funds from the hook
     * @dev withdraws from strategy and transfers the funds to the user
     */
    function withdraw(PoolKey calldata key) external {
        uint256 userBalance = govToken.balanceOf(msg.sender);
        uint256 totalSupply = govToken.totalSupply();
        uint256 userShare = (userBalance * 1e8) / totalSupply;

        uint256 amount0;
        uint256 amount1;

        govToken.burn(msg.sender, userBalance);

        _withdrawFromStrategy(currentActiveStrategyId, key.currency0, amount0);
        _withdrawFromStrategy(currentActiveStrategyId, key.currency1, amount1);

        ERC20(Currency.unwrap(key.currency0)).transfer(msg.sender, amount0);
        ERC20(Currency.unwrap(key.currency1)).transfer(msg.sender, amount1);
    }

    /**
     * @dev deposits funds to the strategy
     */
    function _depositToStrategy(
        uint256 _id,
        Currency _currency,
        uint256 _amount
    ) internal {
        address _token = Currency.unwrap(_currency);
        IStrategy(controller.getStrategyAddress(_id)).deposit(_token, _amount);
    }

    /**
     * @dev withdraws funds from the strategy
     */
    function _withdrawFromStrategy(
        uint256 _id,
        Currency _currency,
        uint256 amount
    ) internal {
        address token = Currency.unwrap(_currency);
        IStrategy(controller.getStrategyAddress(_id)).withdraw(token, amount);
    }

    /**
     * @dev gets the staked balances of both the pool tokens
     */
    function _getBalanceFromStrategy(
        uint256 _id,
        PoolKey calldata key
    ) internal view returns (uint256 balanceOfToken0, uint256 balanceOfToken1) {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        (balanceOfToken0, balanceOfToken1) = IStrategy(
            controller.getStrategyAddress(_id)
        ).getBalance(token0, token1);
    }

    /**
     * @dev mints a new LP position, used  in beforeSwap hook
     */
    function _addLiquidityToPool(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Max,
        uint128 amount1Max
    ) internal returns (int256 liquidityDelta) {
        bytes memory actions = abi.encodePacked(
            Actions.MINT_POSITION,
            Actions.SETTLE_PAIR
        );
        bytes[] memory params = new bytes[](2);

        (, int24 currTick, , ) = StateLibrary.getSlot0(poolManager, key.toId());

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            TickMath.getSqrtPriceAtTick(currTick),
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Max,
            amount1Max
        );

        params[0] = abi.encode(
            key,
            tickLower,
            tickUpper,
            liquidity,
            amount0Max,
            amount1Max,
            address(this),
            ""
        );

        params[1] = abi.encode(key.currency0, key.currency1);

        positionManager.modifyLiquiditiesWithoutUnlock(actions, params);

        currentPositionId = positionManager.nextTokenId() - 1;
    }

    /**
     * @dev burns this contract's LP position, used in afterSwap hook
     */
    function _removeLiquidityFromPool() internal {
        bytes memory actions = abi.encodePacked(Actions.BURN_POSITION);
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(currentPositionId, 0, 0, "");
        delete currentPositionId;

        positionManager.modifyLiquiditiesWithoutUnlock(actions, params);
    }

    /**
     * @dev gets the swap amount in USD
     */
    function _getSwapAmount(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) internal view returns (uint256 amountToSwap) {
        uint256 precision;
        int256 price;
        int256 amountSpecified = params.amountSpecified;
        uint256 token0Decimals = ERC20(Currency.unwrap(key.currency0))
            .decimals();
        uint256 token1Decimals = ERC20(Currency.unwrap(key.currency1))
            .decimals();

        if (params.zeroForOne) {
            if (params.amountSpecified < 0) {
                precision = 10 ** token0Decimals;
                amountSpecified = -amountSpecified;
                (, price, , , ) = priceFeeds[key.currency0].latestRoundData();
            } else {
                precision = 10 ** token1Decimals;
                (, price, , , ) = priceFeeds[key.currency1].latestRoundData();
            }
        } else {
            if (params.amountSpecified < 0) {
                amountSpecified = -amountSpecified;
                precision = 10 ** token1Decimals;
                (, price, , , ) = priceFeeds[key.currency1].latestRoundData();
            } else {
                precision = 10 ** token0Decimals;
                (, price, , , ) = priceFeeds[key.currency0].latestRoundData();
            }
        }

        amountToSwap = (uint256(amountSpecified) * uint256(price)) / precision;
    }

    /**
     * @dev withdraws funds from external protocol and swaps them to maintain the pool ratio
     */
    function _withdrawAndSwap(
        PoolKey calldata key
    ) internal returns (uint256 amount0, uint256 amount1) {
        (
            uint256 token0Balance,
            uint256 token1Balance
        ) = _getBalanceFromStrategy(currentActiveStrategyId, key);

        _withdrawFromStrategy(
            currentActiveStrategyId,
            key.currency0,
            token0Balance
        );
        _withdrawFromStrategy(
            currentActiveStrategyId,
            key.currency1,
            token1Balance
        );

        (, int24 tick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);

        uint256 currentPrice = (uint256(sqrtPriceX96) *
            uint256(sqrtPriceX96) *
            1e18) >> 192;

        uint256 ourRatio = (token0Balance * currentPrice) / token1Balance;

        if (ourRatio > 1e18) {
            uint256 excessAmount0 = token0Balance -
                ((token1Balance * 1e18) / currentPrice);
            poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: true,
                    amountSpecified: int256(excessAmount0),
                    sqrtPriceLimitX96: 0
                }),
                ""
            );
        } else if (ourRatio < 1e18) {
            uint256 excessAmount1 = token1Balance -
                ((token0Balance * currentPrice) / 1e18);
            poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: false,
                    amountSpecified: int256(excessAmount1),
                    sqrtPriceLimitX96: 0
                }),
                ""
            );
        }
        uint256 newToken0Balance = ERC20(Currency.unwrap(key.currency0))
            .balanceOf(address(this));
        uint256 newToken1Balance = ERC20(Currency.unwrap(key.currency1))
            .balanceOf(address(this));
        return (newToken0Balance, newToken1Balance);
    }
}
