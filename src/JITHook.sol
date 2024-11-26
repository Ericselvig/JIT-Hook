// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IStrategiesController} from "./interfaces/IStrategiesController.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";

contract JITHook is BaseHook {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    AggregatorV3Interface public token0PriceFeed;
    AggregatorV3Interface public token1PriceFeed;

    uint256 public swapThreshold; // swap threshold in USD (8 decimals)
    IStrategiesController public controller;
    IPositionManager public positionManager;
    uint256 public currentPositionId;
    uint256 public currentActiveStrategyId;

    constructor(
        IPoolManager _manager,
        address _strategiesController,
        uint256 _threshold,
        address _token0PriceFeed,
        address _token1PriceFeed,
        address _posManager
    ) BaseHook(_manager) {
        controller = IStrategiesController(_strategiesController);
        swapThreshold = _threshold;
        token0PriceFeed = AggregatorV3Interface(_token0PriceFeed);
        token1PriceFeed = AggregatorV3Interface(_token1PriceFeed);
        positionManager = IPositionManager(_posManager);
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
                afterInitialize: false,
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
                (, price, , , ) = token0PriceFeed.latestRoundData();
            } else {
                precision = 10 ** token1Decimals;
                (, price, , , ) = token1PriceFeed.latestRoundData();
            }
        } else {
            if (params.amountSpecified < 0) {
                amountSpecified = -amountSpecified;
                precision = 10 ** token1Decimals;
                (, price, , , ) = token1PriceFeed.latestRoundData();
            } else {
                precision = 10 ** token0Decimals;
                (, price, , , ) = token0PriceFeed.latestRoundData();
            }
        }

        // this should be in USD (8 decimals)
        uint256 amountToSwap = (uint256(amountSpecified) * uint256(price)) / precision;

        if (amountToSwap >= swapThreshold) {
            uint256 amountWithdrawn = _withdrawFromStrategy(
                currentActiveStrategyId
            );
            // TODO add amount0 and amount1
            // who decides the liquidity range before adding liqudity?
            _addLiquidityToPool(key, 0, 0, 0, 0, 0);
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
    function deposit(uint256 amount0, uint256 amount1, PoolKey calldata key) external {
        ERC20(Currency.unwrap(key.currency0)).transferFrom(msg.sender, address(this), amount0);
        ERC20(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), amount1);

        if(amount0 > 0) {
            _depositToStrategy(currentActiveStrategyId, key.currency0, amount0);
        } 
        if(amount1 > 0) {
            _depositToStrategy(currentActiveStrategyId, key.currency1, amount1);
        }

        // todo emit event
    }

    // funds transferred to small LPs from external protocol
    function withdraw(uint256 amount0, uint256 amount1, PoolKey calldata key) external {
        uint256 withdrawAmount = _withdrawFromStrategy(currentActiveStrategyId);

        // todo calculate token amount for the user, and transfer to user 
        // todo multiple user wil store funds here, when one user call this only his liquidty should be removed and transferred to user NOT ALL
    }

    // redeem what ? yeild tokens from external protocol OR swap fees ?
    function redeem() external {}

    function _depositToStrategy(
        uint256 _id,
        address _token,
        uint256 _amount
    ) internal {
        IStrategy(controller.getStrategyAddress(_id)).deposit(_token, _amount);
    }

    function _withdrawFromStrategy(uint256 _id) internal returns (uint256) {
        return IStrategy(controller.getStrategyAddress(_id)).withdraw();
    }

    function _addLiquidityToPool(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max
    ) internal returns (int256 liquidityDelta) {
        // note mint liquidity or add liquidity, liquidity will be provided by non JIT LPs as well ? 
        bytes memory actions = abi.encodePacked(
            Actions.MINT_POSITION,
            Actions.SETTLE_PAIR
        );
        bytes[] memory params = new bytes[](2);
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
}
