// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IProtocol} from "src/IProtocol.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";



contract JITHook is BaseHook {

    uint256 immutable threshold;

    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    IProtocol public yeildProtocol;
    // IPoolManager public poolManager;

    constructor(IPoolManager _manager, IProtocol _yeildProtocol, uint256 _threshold) BaseHook(_manager) {
        yeildProtocol = _yeildProtocol;
        poolManager = _manager;
        threshold = _threshold;
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
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if(uint256(params.amountSpecified) >= threshold) {
            uint256 amountWithdrawn = _withdrawFromExternalProtocol();
            // todo add amount0 and amount1
            _addLiquidityToPool(poolManager, key, 0, 0);
        }
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // remove liquidity from pool and add to external protocol
    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        returns (bytes4, int128)
    {
        _removeLiquidityFromPool(poolManager, key, 0);
        _depositToExternalProtocol(address(this), 0);
        return (this.afterSwap.selector, 0);
    }

    // smaller LPs will call this function, funds added to external protocol
    function deposit() external {}

    // funds transferred to small LPs from external protocol
    function withdraw() external {}

    // redeem what ? yeild tokens from external protocol OR swap fees ?
    function redeem() external {}

    function _depositToExternalProtocol(address user, uint256 amount) internal {
        yeildProtocol.deposit(address(this), amount);
    }

    function _withdrawFromExternalProtocol() internal returns (uint256) {
        yeildProtocol.withdraw(address(this));
    }

    function _addLiquidityToPool(IPoolManager PoolManager, PoolKey memory key, uint256 amount0, uint256 amount1) internal returns (int256 liquidityDelta) {

        ERC20(Currency.unwrap(key.currency0)).approve(address(poolManager), amount0);
        ERC20(Currency.unwrap(key.currency1)).approve(address(poolManager), amount1);
        // todo set tick upper and lower for params in both add and rmeove liquidity from pool
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({ 
            tickLower: 0,
            tickUpper: 0,
            liquidityDelta: 0,
            salt: bytes32(0)
        });

        poolManager.modifyLiquidity(key, params, "");
    }

    function _removeLiquidityFromPool(IPoolManager PoolManager, PoolKey memory key, uint256 liquidityPercentage) internal returns (uint256 amount0, uint256 amount1) {
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: 0,
            tickUpper: 0,
            liquidityDelta: 0,
            salt: bytes32(0)
        });

        (BalanceDelta delta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(key, params, "");
        amount0 = uint256(int256((-delta.amount0())));
        amount1 = uint256(int256((-delta.amount1())));
    }
}
