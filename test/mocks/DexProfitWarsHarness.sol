// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.26;

import {BalanceDelta, toBalanceDelta, BDelta} from "v4-core/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {DexProfitWars} from "../../src/DexProfitWars.sol";

contract DexProfitWarsHarness is DexProfitWars {
    constructor(
        IPoolManager _manager,
        address _gasPriceOracle,
        address _token0PriceOracle,
        address _token1PriceOracle,
        address _ethUsdOracle
    )
        DexProfitWars(_manager, _gasPriceOracle, _token0PriceOracle, _token1PriceOracle, _ethUsdOracle)
    {
        // If needed, run any special setup for testing here
    }

    // This harness function is public so your Foundry test can call it,
    // but it calls _afterSwap internally, which is allowed because
    // DexProfitWarsHarness inherits DexProfitWars.
    function harnessAfterSwap(
        address trader,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BDelta delta,
        bytes calldata hookData
    ) external {
        // Now we can call _afterSwap because it's internal and we're in a derived contract.
        _afterSwap(trader, key, params, delta, hookData);
    }

    // Optionally, you can also add a convenience function for "testSimulateTrade" if you like:
    /**
     * Utility function testSimulateTrade
     * This helper function (which you add to your contract for testing) simulates
     * a swap by letting you specify the amount of tokens spent and tokens received.
     * With our fixed mock oracle prices (token0 = $1 and token1 = $2), the profit
     * percentage is computed as:
     * The profit percentage is computed approximately as:
     * profitBps = (((2 * tokensGained) - tokensSpent) * 1e4) / tokenSpent;
     * Therefore:
     * tokensGained = tokensSpent * ((10000 + P) / (2 * 10000));
     * We choose tokensGained based on a desired profit (e.g. 300, 400, 500, etc.).
     */
    function harnessSimulateTrade(
        address trader,
        uint256 tokensSpent,
        uint256 tokensGained,
        bool zeroForOne,
        PoolKey calldata key
    ) external {
        // (1) Convert to int128
        int256 castSpent = int256(tokensSpent);
        int256 castGained = int256(tokensGained);
        int128 sSpent = int128(castSpent);
        int128 sGained = int128(castGained);

        // (2) Decide sign
        int128 a0;
        int128 a1;
        if (zeroForOne) {
            a0 = -sSpent;
            a1 = sGained;
        } else {
            a0 = sGained;
            a1 = -sSpent;
        }

        // (3) Build BalanceDelta
        BDelta delta = toBalanceDelta(a0, a1);

        // (4) Build SwapParams
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: zeroForOne ? -int256(tokensSpent) : int256(tokensSpent),
            sqrtPriceLimitX96: 0
        });

        // (5) Call _afterSwap via harness
        _afterSwap(trader, key, params, delta, abi.encode(trader));
    }
}