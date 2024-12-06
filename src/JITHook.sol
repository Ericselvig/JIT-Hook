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
 * @author Yash Goyal & Naman Mohanani
 */
contract JITHook is BaseHook, Owned {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    // Errors
    error Slippage_Too_High();

    mapping(Currency currency => AggregatorV3Interface priceFeed) priceFeeds;
    // TODO pool => strategy ID

    uint256 public swapThreshold; // swap threshold in USD (8 decimals)
    IStrategiesController public controller;
    IPositionManager public positionManager;
    uint256 public currentPositionId;

    // TODO remove
    uint256 public currentActiveStrategyId;

    // mapping(PoolKey => GovToken) public govTokens;
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
     * @dev hook to initialize the governance token for a pool
     * note not creating different tokens for each pool
     */
    // function afterInitialize(
    //     address,
    //     PoolKey calldata key,
    //     uint160,
    //     int24
    // ) external override returns (bytes4) {
    //     string memory name = string.concat(
    //         "Governance token: ",
    //         ERC20(Currency.unwrap(key.currency0)).symbol(),
    //         "-",
    //         ERC20(Currency.unwrap(key.currency1)).symbol(),
    //         Strings.toString(key.fee)
    //     );
    //     string memory symbol = string.concat(
    //         ERC20(Currency.unwrap(key.currency0)).symbol(),
    //         "-",
    //         ERC20(Currency.unwrap(key.currency1)).symbol(),
    //         Strings.toString(key.fee)
    //     );
    //     govTokens[key.toId()] = new GovToken(name, symbol);

    //     return this.afterInitialize.selector;
    // }

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

        // Converting swap amount into USD as well to compare 
        if (_getSwapAmount(key, params) >= swapThreshold) {
            // withdraw funds from external swap before adding to the pool and
            // check if internal swap is required before adding liquidity
            (
                uint256 amount0ToAddInPool,
                uint256 amount1ToAddInPool
            ) = _withdrawAndSwap(key);

            (, int24 tick, , ) = StateLibrary.getSlot0(poolManager, key.toId());

            // add liquidity to pool
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

    // remove liquidity from pool and add to external protocol
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        // 1. remove liquidity from pool
        // 2. add liquidity to external protocol

        // TODO are 0, 0 ok?
        _removeLiquidityFromPool(0, 0);
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

        // fee distribution ???????????
        return (this.afterSwap.selector, 0);
    }

    // smaller LPs will call this function, funds added to external protocol
    // note the user must deposit the pair of funds to the hook with the same ratio as the pool, otherwise it will not be accepted
    function deposit(
        Currency currency,
        uint256 amount
    ) external {
        
        ERC20(Currency.unwrap(currency)).transferFrom(
            msg.sender,
            address(this),
            amount
        );

        // TODO instead of minting amounts directly, calculate the total USD value and mint that
        if (amount > 0) {
            (, int256 price, , ,) = priceFeeds[currency].latestRoundData();
            uint256 usdValue = (uint256(price) * amount) / 1e8;

            // deposit to strategy (currency => amount)
            _depositToStrategy(currentActiveStrategyId, currency, amount);
            // mint gove Token => usdValue 
            govToken.mint(msg.sender, usdValue);
        }

        // todo emit event
    }

    // funds transferred to small LPs from external protocol
    // TODO 
    // key: currency0, currency1 => not deposited in external protocol because no one deposited it ?????
    // without key, what tokens will returned ? 
    function withdraw(PoolKey calldata key) external {
        // TODO (later) amount specific withdrawl
        // TODO give tokens on basis of staked tokens ratio
        // Ex: staked $1000 USDC and $1000 ETH so give 50-50
        // GovToken govToken = govTokens[key.toId()];
        uint256 userBalance = govToken.balanceOf(msg.sender);
        uint256 totalSupply = govToken.totalSupply();
        uint256 userShare = (userBalance * 1e8) / totalSupply;

        // TODO calculate both token amounts to withdraw and give to user
        uint256 amount0;
        uint256 amount1;

        govToken.burn(msg.sender, userBalance);

        _withdrawFromStrategy(currentActiveStrategyId, key.currency0, amount0);
        _withdrawFromStrategy(currentActiveStrategyId, key.currency1, amount1);

        ERC20(Currency.unwrap(key.currency0)).transfer(
            msg.sender,
            amount0
        );
        ERC20(Currency.unwrap(key.currency1)).transfer(
            msg.sender,
            amount1
        );

        // todo calculate token amount for the user, and transfer to user
        // todo multiple user wil store funds here, when one user call this only his liquidty should be removed and transferred to user NOT ALL
    }

    // redeem what ? yeild tokens from external protocol OR swap fees ?
    function redeem() external {}

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
        // note mint liquidity or add liquidity, liquidity will be provided by non JIT LPs as well ?
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
    function _removeLiquidityFromPool(
        uint128 amount0Min,
        uint128 amount1Min
    ) internal {
        // decrease liquidity + take pair (transfer fee revenue) ? OR directly burn position
        bytes memory actions = abi.encodePacked(Actions.BURN_POSITION);
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(currentPositionId, amount0Min, amount1Min, "");
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

        // this should be in USD (8 decimals)
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


        // not withdrawing the entire balance, 
        // because in future we will allow user to withdraw some specific amount of funds [right now it is complete balance]
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
        // current price ratio 
        (, int24 tick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);

        // P = y/x 
        uint256 currentPrice = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18) >> 192;

        // x token A, y token B
        // x -> y
        // (x - dx) / (y + dy) = pool ratio

        // amount pair in this hook contract => in ratio wrt to the pool ratio
        // our ratio is (x * P) / y
        // if ratio = 1e18, we are in perfect ratio
        // if ratio > 1e18, we have too much token0 relative to token1
        // if ratio < 1e18, we have too much token1 relative to token0
        uint256 ourRatio = (token0Balance * currentPrice) / token1Balance;

        if (ourRatio > 1e18) {
            // We have too much token0 relative to token1
            uint256 excessAmount0 = token0Balance - ((token1Balance * 1e18) / currentPrice);
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
            // We have too much token1 relative to token0
            uint256 excessAmount1 = token1Balance - ((token0Balance * currentPrice) / 1e18);
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
        uint256 newToken0Balance = ERC20(Currency.unwrap(key.currency0)).balanceOf(address(this));
        uint256 newToken1Balance = ERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
        return (newToken0Balance, newToken1Balance);
            
    }
}
