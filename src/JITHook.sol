// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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

    // mapping(PoolKey => GovToken) public govTokens;
    mapping(PoolId => GovToken) public govTokens;

    constructor(
        IPoolManager _manager,
        address _strategiesController,
        uint256 _threshold,
        address _posManager
    ) BaseHook(_manager) Owned(msg.sender) {
        controller = IStrategiesController(_strategiesController);
        swapThreshold = _threshold;
        positionManager = IPositionManager(_posManager);
    }

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

    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24
    ) external override returns (bytes4) {
        string memory name = string.concat(
            "Governance token: ",
            ERC20(Currency.unwrap(key.currency0)).symbol(),
            "-",
            ERC20(Currency.unwrap(key.currency1)).symbol()
        );
        string memory symbol = string.concat(
            ERC20(Currency.unwrap(key.currency0)).symbol(),
            "-",
            ERC20(Currency.unwrap(key.currency1)).symbol()
        );
        govTokens[key.toId()] = new GovToken(name, symbol);

        return this.afterInitialize.selector;
    }

    // if swap is big => remove lquidity from external protocol and add liquidity
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        // 1. detect big swap
        // 2. remove liquidity from external protocol
        // 3. add liquidity to pool
        if (msg.sender == address(this)) {
            return (
                this.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                0
            );
        }

        if (_getSwapAmount(key, params) >= swapThreshold) {
            // current price ratio

            if (!_checkIfHookHasEnoughBalance(key, params)) {
                return (
                    this.beforeSwap.selector,
                    BeforeSwapDeltaLibrary.ZERO_DELTA,
                    0
                );
            }

            // withdraw funds from external swap before adding to the pool

            // check if internal swap is required before adding liquidity
            (
                uint256 requiredAmount0AccordingToCurrentPoolRatio,
                uint256 requiredAmount1AccordingToCurrentPoolRatio
            ) = _swap(key);

            // add liquidity to pool
            _addLiquidityToPool(
                key,
                0,
                0,
                uint128(requiredAmount0AccordingToCurrentPoolRatio),
                uint128(requiredAmount1AccordingToCurrentPoolRatio)
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

        _removeLiquidityFromPool(0, 0);
        //_depositToStrategy(_id, _token, _amount);
        // fee distribution ???????????
        return (this.afterSwap.selector, 0);
    }

    // smaller LPs will call this function, funds added to external protocol
    // note the user must deposit the pair of funds to the hook with the same ratio as the pool, otherwise it will not be accepted
    function deposit(
        uint256 amount0,
        uint256 amount1,
        PoolKey calldata key
    ) external {
        // getting price from pool manager
        (, int24 tick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        // note not sure about the math here ?
        uint256 price = (uint256(sqrtPriceX96) *
            uint256(sqrtPriceX96) *
            1e18) >> 192;
        uint256 expectedAmount1 = (amount0 * price) / 1e18;
        uint256 expectedAmount0 = (amount1 * 1e18) / price;
        // 2% tolerance
        require(
            amount0 >= (expectedAmount0 * 98) / 100 &&
                amount0 <= (expectedAmount0 * 101) / 100 &&
                amount1 >= (expectedAmount1 * 98) / 100 &&
                amount1 <= (expectedAmount1 * 101) / 100,
            "amount not in pool ratio"
        );
        // require(amount1 >= expectedAmount1 * 98 / 100 && amount1 <= expectedAmount1 * 101 / 100, "amounts too small");

        ERC20(Currency.unwrap(key.currency0)).transferFrom(
            msg.sender,
            address(this),
            amount0
        );
        ERC20(Currency.unwrap(key.currency1)).transferFrom(
            msg.sender,
            address(this),
            amount1
        );

        if (amount0 > 0) {
            _depositToStrategy(currentActiveStrategyId, key.currency0, amount0);
            govTokens[key.toId()].mint(msg.sender, amount0);
        }
        if (amount1 > 0) {
            _depositToStrategy(currentActiveStrategyId, key.currency1, amount1);
            govTokens[key.toId()].mint(msg.sender, amount1);
        }

        // todo emit event
    }

    // funds transferred to small LPs from external protocol
    // note what if when the user withdraw pair of tokens, that ratio is changed
    // we accept deposit in proper ratio so we must withdraw in current ratio as well
    // INTERNAL SWAP
    function withdraw(
        uint256 amount0,
        uint256 amount1,
        PoolKey calldata key
    ) external {
        GovToken govToken = govTokens[key.toId()];
        uint256 userBalance = govToken.balanceOf(msg.sender);
        uint256 totalSupply = govToken.totalSupply();
        uint256 userShare = (userBalance * 1e18) / totalSupply;
        uint256 maxWithdrawAmountToken0 = (amount0 * userShare) / 1e18;
        uint256 maxWithdrawAmountToken1 = (amount1 * userShare) / 1e18;

        require(
            amount0 <= maxWithdrawAmountToken0 &&
                amount1 <= maxWithdrawAmountToken1
        );
        govToken.burn(msg.sender, amount0);
        govToken.burn(msg.sender, amount1);

        uint256 withdrawAmountToken0 = _withdrawFromStrategy(
            currentActiveStrategyId,
            key.currency0,
            amount0
        );
        uint256 withdrawAmountToken1 = _withdrawFromStrategy(
            currentActiveStrategyId,
            key.currency1,
            amount1
        );
        ERC20(Currency.unwrap(key.currency0)).transfer(
            msg.sender,
            withdrawAmountToken0
        );
        ERC20(Currency.unwrap(key.currency1)).transfer(
            msg.sender,
            withdrawAmountToken1
        );

        // todo calculate token amount for the user, and transfer to user
        // todo multiple user wil store funds here, when one user call this only his liquidty should be removed and transferred to user NOT ALL
    }

    // redeem what ? yeild tokens from external protocol OR swap fees ?
    function redeem() external {}

    function _depositToStrategy(
        uint256 _id,
        Currency _currency,
        uint256 _amount
    ) internal {
        address _token = Currency.unwrap(_currency);
        IStrategy(controller.getStrategyAddress(_id)).deposit(_token, _amount);
    }

    function _withdrawFromStrategy(
        uint256 _id,
        Currency _currency,
        uint256 amount
    ) internal returns (uint256) {
        address token = Currency.unwrap(_currency);
        return
            IStrategy(controller.getStrategyAddress(_id)).withdraw(
                token,
                amount
            );
    }

    function _getBalanceFromStrategy(
        uint256 _id,
        PoolKey calldata key
    ) internal returns (uint256 balanceOfToken0, uint256 balanceOfToken1) {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        (balanceOfToken0, balanceOfToken1) = IStrategy(
            controller.getStrategyAddress(_id)
        ).getBalance(token0, token1);
    }

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

    function _removeLiquidityFromPool(
        uint128 amount0Min,
        uint128 amount1Min
    ) internal returns (uint256 amount0, uint256 amount1) {
        // decrease liquidity + take pair (transfer fee revenue) ? OR directly burn position
        bytes memory actions = abi.encodePacked(Actions.BURN_POSITION);
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(currentPositionId, amount0Min, amount1Min, "");
        delete currentPositionId;

        positionManager.modifyLiquiditiesWithoutUnlock(actions, params);
    }

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

    function _checkIfHookHasEnoughBalance(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) internal returns (bool) {
        (
            uint256 token0Balance,
            uint256 token1Balance
        ) = _getBalanceFromStrategy(currentActiveStrategyId, key);

        uint256 amountSpecified = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        // check if we have enough funds to cover the swap before adding liquidity
    }

    function _swap(
        PoolKey calldata key
    ) internal returns (uint256 amount0, uint256 amount1) {
        (
            uint256 token0Balance,
            uint256 token1Balance
        ) = _getBalanceFromStrategy(currentActiveStrategyId, key);
        
        (, int24 tick, , ) = StateLibrary.getSlot0(poolManager, key.toId());
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        uint256 currentPoolPrice = (uint256(sqrtPriceX96) *
            uint256(sqrtPriceX96) *
            1e18) >> 192;

        uint256 amountWithdrawn0 = _withdrawFromStrategy(
            currentActiveStrategyId,
            key.currency0,
            token0Balance
        );
        uint256 amountWithdrawn1 = _withdrawFromStrategy(
            currentActiveStrategyId,
            key.currency1,
            token1Balance
        );

        uint256 amount0 = (token1Balance * 1e18) / currentPoolPrice;
        uint256 amount1 = (token0Balance * currentPoolPrice) / 1e18;

        if (token0Balance > amount0) {
            // swap token0 for token1
            poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: true,
                    amountSpecified: int256(token0Balance - amount0),
                    sqrtPriceLimitX96: 0
                }),
                ""
            );
        } else if (token1Balance > amount1) {
            // swap token1 for token0
            uint256 excessAmount1 = token1Balance - amount1;
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
    }
}
