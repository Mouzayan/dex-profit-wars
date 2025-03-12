// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;
// TODO: CHECK IF SOME IMPORTS ARE NOT NEEDED !!!
import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {DexProfitWars} from "../src/DexProfitWars.sol";

/**
 * 1. Test that gas cost calculations correctly apply both USD and percentage-based thresholds
 * (MAX_GAS_COST_USD and MAX_GAS_COST_BASIS_POINTS).
 * 2. Test that oracle price fetching properly validates staleness, normalizes decimals,
 * and handles error cases.
 * 3. Test that trade value calculations correctly determine USD value using the
 * larger of token0/token1 amounts multiplied by their respective oracle prices.
 * 4. Test that profit percentage calculation ((valueOut - valueIn - gasCosts) / valueIn)
 * is accurate and properly scaled by 1e6.
 * 5. Test that trader statistics are only updated when profit exceeds the 2% threshold
 * (2_000_000).
 * 6. Test that trader statistics correctly track totalTrades, profitableTrades,
 * bestTradePercentage, totalProfitUsd, and lastTradeTimestamp.
 * 7. Test that the beforeSwap function properly stores initial gas and price state
 * for the swap.
 * 8. Test that the afterSwap function correctly uses the stored state to calculate final
 * profit/loss.
 * 9. Test edge cases where gas costs exceed trade value or when oracle prices are
 * invalid/stale.
 * 10. Test that multiple trades for the same trader accumulate statistics correctly over time.
 */

contract DexProfitWarsTest is Test, Deployers {
    using CurrencyLibrary for Currency;

    MockERC20 token; // our token to use in the ETH-TOKEN pool

    Currency ethCurrency = Currency.wrap(address(0)); // ETH
    Currency tokenCurrency;

    DexProfitWars hook;

    MockV3Aggregator ethUsdOracle;
    MockV3Aggregator token0UsdOracle;
    MockV3Aggregator token1UsdOracle;

    function setUp() public {
        // Deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();

        // Deploy mock price feeds
        // Chainlink typically uses 8 decimals
        ethUsdOracle = new MockV3Aggregator(8, 2000e8); // ETH = $2000
        token0UsdOracle = new MockV3Aggregator(8, 1e8); // TOKEN0 = $1
        token1UsdOracle = new MockV3Aggregator(8, 1e8); // TOKEN1 = $1

        // Deploy TOKEN contract
        token = new MockERC20("Test Token", "TEST", 18);
        tokenCurrency = Currency.wrap(address(token));

        // Mint a bunch of TOKEN to the contract for bonus rewards
        token.mint(address(this), 1000 ether);

        // Deploy hook to an address that has the proper flags set
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        deployCodeTo(
            "DexProfitWars.sol",
            abi.encode(
                manager,
                address(ethUsdOracle),
                address(token0UsdOracle),
                address(token1UsdOracle)
            ),
            address(flags)
        );

        // Deploy our hook
        hook = DexProfitWars(address(flags));

        // approve TOKEN for spending on the swap router and modify liquidity router
        // These variables are coming from the `Deployers` contract
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Initialize a pool
        (key,) = initPool(
            ethCurrency, // Currency 0
            tokenCurrency, // Currency
            hook, // Hook Contract
            3000, // Swap Fees
            SQRT_PRICE_1_1 // Initial Sqrt(P) value = 1
        );
    }

}