// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";


/**
 * Router that unlocks the manager before calling swap, allowing the DexProfitWars hook to run.
 */
contract DexProfitWarsRouter is IUnlockCallback {
    IPoolManager public manager;

    address public dexProfitWarsHook;

    constructor(IPoolManager _manager, address _dexProfitWarsHook) {
        manager = _manager;
        dexProfitWarsHook = _dexProfitWarsHook;
    }

    /** TODO: FIX NATSPEC
     * @notice Called externally by a trader to perform an exact-input swap.
     * The trader must have approved this router for the input token.
     */
    function doSwap(
        PoolKey calldata key,
        uint256 inputAmount,
        bool zeroForOne
    ) external {
        // encode the callback data
        bytes memory callbackData = abi.encode(msg.sender, key, inputAmount, zeroForOne);

        // unlock the manager and trigger unlockCallback
        manager.unlock(callbackData);
    }

    /** TODO: FIX
     * @notice Called by the pool manager during unlock.
     * In this unlocked context, we:
     *  1. Transfer input tokens from the trader to this router.
     *  2. Sync and settle them into the manager.
     *  3. Call swap (with hookData that tells the hook who the trader is).
     */
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "Only manager");

        // decode callback data.
        (address trader, PoolKey memory key, uint256 inputAmount, bool zeroForOne) =
            abi.decode(data, (address, PoolKey, uint256, bool));

        // transfer input tokens from the trader to this router
        address tokenIn = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);
        IERC20(tokenIn).transferFrom(trader, address(this), inputAmount);

        // sync and settle tokens into the manager
        Currency currencyIn = zeroForOne ? key.currency0 : key.currency1;
        manager.sync(currencyIn);
        // transfer the input tokens from this router into the manager
        currencyIn.transfer(address(manager), uint128(inputAmount));
        manager.settle();

        // build swap parameters for an exact-input swap
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(inputAmount), // negative means exact input
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        // pass hookData in swap so the hook knows who initiated the swap
        BalanceDelta delta = manager.swap(key, params, abi.encode(trader));

        return abi.encode(delta);
    }
}
