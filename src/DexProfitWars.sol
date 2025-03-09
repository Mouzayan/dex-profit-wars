// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol"; // Is THIS NEEDED ????
import {AggregatorV3Interface} from "chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";

/**
 * @title DexProfitWars
 * @author em_mutable
 * @notice DexProfitWars is a gamified trading enhancement protocol built into a Uniswap V4 hook.
 *         It rewards skilled traders with bonus tokens funded by sponsors. Sponsors (protocols,
 *         DAOs, or projects) deposit reward tokens into the bonus pool and define custom reward
 *         parameters for the specific trading pairs.
 *
 *         Core Mechanics
 *         Trading Brackets & Rewards:
 *              - Trades are categorized into three size brackets:
 *                  1. Small: 0.01 - 0.1 ETH
 *                  2. Medium: 0.1 - 1 ETH
 *                  3. Large: 1 - 10 ETH
 *              - Each bracket maintains separate leaderboards in the UI
 *
 *         Profit Calculation
 *              - Profit calculation uses percentage-based returns within each bracket:
 *                  - Traders ranked by percentage return on their trades
 *                  - Example: 10% profit on small trade beats 8% profit on large trade
 *                  - Minimum 2% profit required to qualify
 *
 *         Reward Pool Distribution
 *              - Based on total value of the reward pool :
 *                  1. Small Pool (< 1000 USDC equivalent)
 *                      Single winner (100%) or Two winners (70/30)
 *                  2. Standard Pool (1000-10000 USDC equivalent)
 *                      Three winners (50/30/20)
 *                  3. Large Pool (> 10000 USDC equivalent)
 *                      Five winners (40/25/15/12/8)
 *
 *         Sponsor Mechanics:
 *              - One active sponsor pool at a time
 *              - Sponsors provide reward tokens separate from the trading pair
 *              - 48-hour grace period between sponsor transitions
 *              - Unclaimed rewards returnable to sponsor after reward pool expiration
 *
 *         Reward Distribution:
 *              - Triggered after:
 *                  - Trading window completion (e.g. 7 days)
 *                  - Mandatory cooldown period (e.g. 24 hours)
 *              - Automatic distribution to qualifying traders
 *              - Rewards paid in sponsor's designated token
 *
 *         Sponsor Customizable Parameters:
 *              - Trading window duration
 *              - Bonus pool size and token
 *              - Trade size limits per bracket
 *              - Minimum profit thresholds
 *              - Cooldown periods
 *
 *         Anti-manipulation safeguards:
 *             1. Trade Controls
 *                 - Bracket-specific size limits
 *                 - Time delays between trades
 *                 - Rate limiting per wallet
 *             2. Economic Security
 *                 - Maximum slippage tolerance
 *                 - Pool utilization limits
 *                 - Minimum profit requirements
 *             3. MEV Protection
 *                 - Distribution delays
 *
 *         This mechanism could play into memecoin launches / airdrops etc..
 *
 *         TODO:
 *         - Remove EXCESS COMMENTS
 *         - Deal w/ partial exits
 *         - Partial exits
 *         - Track positions as swaps occur
 *         - Write interface
 *         - How to be gas effificent since swap PnL is calcualted at every swap
 *         - Do we need more so[histicated price validation?
 *         - Do we need circuit breakers?
 */
contract DexProfitWars is BaseHook {
    using CurrencyLibrary for Currency; // needed ???
    using BalanceDeltaLibrary for BalanceDelta; // needed ???

    struct TradeTracking {
        uint256 tokenInAmount;
        uint256 tokenOutAmount;
        uint160 sqrtPriceX96Before; // Price before swap
        uint160 sqrtPriceX96After; // Price after swap
        uint256 timestamp;
    }

    // Struct to track trader statistics
    struct TraderStats {
        uint256 totalTrades;
        uint256 profitableTrades;
        int256 bestTradePercentage;
        uint256 totalProfitUsd;
        uint256 lastTradeTimestamp;
    }

    // Mapping to store trader statistics
    mapping(address => TraderStats) public traderStats;

    struct SwapGasTracking {
        uint256 gasStart;
        uint160 sqrtPriceX96Before;
    }

    mapping(address => SwapGasTracking) public swapGasTracker;

    // Gas price caching
    // Make these private??????
    uint256 public lastGasPriceUpdate;
    uint256 public cachedGasPrice;
    uint256 public constant GAS_PRICE_UPDATE_INTERVAL = 1 hours;

    // Gas cost thresholds
    // Make these private??????
    uint256 public constant MAX_GAS_COST_USD = 50 * 1e18; // $50 max gas cost
    uint256 public constant MAX_GAS_COST_BASIS_POINTS = 100; // 1% of trade value

    // Oracle staleness thresholds
    // Make these private??????
    uint256 public constant MAX_ORACLE_AGE = 1 hours;

    // Price oracle interfaces
    // Make these private??????
    AggregatorV3Interface public ethUsdOracle;
    AggregatorV3Interface public token0UsdOracle;
    AggregatorV3Interface public token1UsdOracle;

    // Oracle decimals
    uint8 private immutable ethUsdDecimals;
    uint8 private immutable token0UsdDecimals;
    uint8 private immutable token1UsdDecimals;

    // Create separate errors file
    error DPW_StalePrice(uint256 timestamp);
    error DPW_InvalidPrice(int256 price);

    // ========================================== CONSTRUCTOR ===========================================

    /**
     * @notice Sets up the DexProfitWars contract by initializing the pool manager and price oracles,
     *         and storing their decimal precision values.
     *
     * @param _manager                      The Uniswap V4 pool manager contract address.
     * @param _ethUsdOracle                 The address of the ETH/USD Chainlink price feed.
     * @param _token0UsdOracle              The address of the Token0/USD Chainlink price feed.
     * @param _token1UsdOracle              The address of the Token1/USD Chainlink price feed.
     */
    constructor(IPoolManager _manager, address _ethUsdOracle, address _token0UsdOracle, address _token1UsdOracle)
        BaseHook(_manager)
    {
        // Initialize price feed interfaces
        ethUsdOracle = AggregatorV3Interface(_ethUsdOracle); // Creates interface to ETH/USD price feed
        token0UsdOracle = AggregatorV3Interface(_token0UsdOracle); // Creates interface to Token0/USD price feed
        token1UsdOracle = AggregatorV3Interface(_token1UsdOracle); // Creates interface to Token1/USD price feed

        // Store decimal precision values to avoid repeated external calls
        ethUsdDecimals = ethUsdOracle.decimals(); // Stores ETH/USD feed decimal precision
        token0UsdDecimals = token0UsdOracle.decimals(); // Stores Token0/USD feed decimal precision
        token1UsdDecimals = token1UsdOracle.decimals(); // Stores Token1/USD feed decimal precision
    }

    /**
     * @notice Returns the hook's permissions for various Uniswap V4 pool operations.
     *         This hook requires permissions for beforeSwap, afterSwap, and afterAddLiquidity
     *         to track trades and manage profit calculations.
     *
     * @return Hooks.Permissions struct indicating which hook functions are active
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true, // Hook before swap to store initial state
            afterSwap: true, // Hook after swap to calculate profits
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /**
     * @notice Records the initial state before a swap occurs, including gas usage and price.
     *         This data is used to calculate profit/loss and gas costs in afterSwap.
     *
     * @param sender                        The address initiating the swap.
     * @param key                           The pool key containing token pair and fee information.
     * @param params                        The swap parameters including amount and direction.
     *
     * @return                              The function selector to indicate successful hook execution.
     */
    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params)
        external
        returns (bytes4)
    {
        // Get current sqrt price from pool
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());

        // Store gas usage and price data for this swap
        swapGasTracker[sender] = SwapGasTracking({
            gasStart: gasleft(), // Record remaining gas
            sqrtPriceX96Before: sqrtPriceX96 // Record starting price
        });

        return (this.beforeSwap.selector); // Return function selector to indicate success
    }

    /**
     * @notice Calculates the profit/loss after a swap completes, including gas costs,
     *         and updates trader statistics if profit threshold is met.
     *
     * @param sender                        The address that initiated the swap.
     * @param key                           The pool key containing token pair and fee information.
     * @param params                        The swap parameters including amount and direction.
     * @param delta                         The balance changes resulting from the swap.
     *
     * @return                              The function selector to indicate successful hook execution.
     */
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta
    ) external returns (bytes4) {
        // Retrieve stored gas and price data from before swap
        SwapGasTracking memory tracking = swapGasTracker[sender];

        // Calculate total gas used in swap
        uint256 gasUsed = tracking.gasStart - gasleft();

        // Get final price after swap completion
        (uint160 sqrtPriceX96After,,,) = poolManager.getSlot0(key.toId());

        // Get current gas price for cost calculation
        uint256 gasPrice = tx.gasprice;

        // Calculate percentage profit/loss including gas costs
        int256 profitPercentage =
            _calculateSwapPnL(delta, tracking.sqrtPriceX96Before, sqrtPriceX96After, gasUsed, gasPrice);

        // Clean up gas tracking
        delete swapGasTracker[sender];

        // If profit exceeds 2% threshold, update trader's statistics
        if (profitPercentage >= 2_000_000) {
            // 2% = 2_000_000
            _updateTraderStats(sender, delta, profitPercentage);
        }

        // Return function selector to indicate success
        return (this.afterSwap.selector, 0);
    }

    /**
     * @notice Updates trader statistics after a profitable trade.
     *
     * @param trader                        The address of the trader.
     * @param delta                         The balance changes from the swap.
     * @param profitPercentage              The calculated profit percentage (scaled by 1e6).
     */
    function _updateTraderStats(address trader, BalanceDelta delta, int256 profitPercentage) internal {
        TraderStats storage stats = traderStats[trader];

        // Update trade counts
        stats.totalTrades++;
        stats.profitableTrades++;

        // Update best trade percentage if this trade was better
        if (profitPercentage > stats.bestTradePercentage) {
            stats.bestTradePercentage = profitPercentage;
        }

        // Calculate and update total profit in USD
        uint256 tradeValueUsd = _calculateTradeValueUsd(delta);
        uint256 profitUsd = (tradeValueUsd * uint256(profitPercentage)) / 1e6;
        stats.totalProfitUsd += profitUsd;

        // Update last trade timestamp
        stats.lastTradeTimestamp = block.timestamp;
    }

    /**
     * @notice Calculates the percentage profit/loss for a swap including gas costs.
     *
     * @param delta                         The balance changes from the swap.
     * @param sqrtPriceX96Before            Price before swap in Q96 format.
     * @param sqrtPriceX96After             Price after swap in Q96 format.
     * @param gasUsed                       Amount of gas used in the swap.
     * @param gasPrice                      Current gas price in Wei.
     * @param tradeValueUsd                 USD value of the trade.
     *
     * @return profitPercentage             The profit/loss as a percentage (scaled by 1e6, where 1_000_000 = 100%)
     */
    function _calculateSwapPnL(
        BalanceDelta delta,
        uint160 sqrtPriceX96Before,
        uint160 sqrtPriceX96After,
        uint256 gasUsed,
        uint256 gasPrice,
        uint256 tradeValueUsd
    ) internal pure returns (int256 profitPercentage) {
        // Convert sqrt price to regular price
        uint256 priceBeforeX96 = uint256(sqrtPriceX96Before) * uint256(sqrtPriceX96Before);
        uint256 priceAfterX96 = uint256(sqrtPriceX96After) * uint256(sqrtPriceX96After);

        // Get absolute values of tokens swapped
        uint256 tokenInAmount = delta.amount0 > 0 ? uint256(delta.amount0) : uint256(delta.amount1);
        uint256 tokenOutAmount = delta.amount0 > 0 ? uint256(-delta.amount1) : uint256(-delta.amount0);

        // Calculate values (in terms of one token)
        uint256 valueIn = tokenInAmount * priceBeforeX96;
        uint256 valueOut = tokenOutAmount * priceAfterX96;

        // Calculate gas costs
        uint256 gasCostWei = gasUsed * _getGasPrice();
        uint256 gasCostInTokens = _convertGasCostToTokens(gasCostWei, priceBeforeX96, tradeValueUsd);

        // Subtract gas costs from value out
        if (valueOut > gasCostInTokens) {
            valueOut -= gasCostInTokens;
        } else {
            // If gas costs exceed value out, trade is a loss
            return -1_000_000; // -100%
        }

        // Calculate percentage profit/loss
        // Scale by 1e6 for precision (100% = 1_000_000)
        if (valueOut > valueIn) {
            profitPercentage = int256(((valueOut - valueIn) * 1e6) / valueIn);
        } else {
            profitPercentage = -int256(((valueIn - valueOut) * 1e6) / valueIn);
        }
    }

    /**
     * @notice Gets the current gas price with caching to optimize gas costs.
     *         Updates cache only if the current cache is older than GAS_PRICE_UPDATE_INTERVAL.
     *
     * @return                              Current gas price in Wei, either fresh or cached value.
     *
     * @dev Uses a caching mechanism to reduce the frequency of storage updates:
     *      - Updates cache only after GAS_PRICE_UPDATE_INTERVAL (1 hour)
     *      - Returns cached value if within update interval
     */
    function _getGasPrice() internal returns (uint256) {
        if (block.timestamp >= lastGasPriceUpdate + GAS_PRICE_UPDATE_INTERVAL) {
            // Update cache with current gas price
            cachedGasPrice = tx.gasprice;
            // Record update timestamp
            lastGasPriceUpdate = block.timestamp;
            // Return fresh value
            return cachedGasPrice;
        }

        // Return cached value if still valid
        return cachedGasPrice;
    }

    // ========================================== VIEW FUNCTIONS =========================================
    /**
     * @notice Converts gas costs in Wei to token value with thresholds.
     *
     * @param gasCostWei                    Gas cost in Wei.
     * @param priceX96                      Current pool price in Q96 format.
     * @param tradeValueUsd                 USD value of the trade.
     *
     * @return tokenCost                    Gas cost converted to token value.
     *
     * @dev Applies two thresholds:
     *      - Maximum USD value (MAX_GAS_COST_USD)
     *      - Maximum percentage of trade value (MAX_GAS_COST_BASIS_POINTS)
     *      Returns the lower of the two limits
     */
    function _convertGasCostToTokens(uint256 gasCostWei, uint256 priceX96, uint256 tradeValueUsd)
        internal
        view
        returns (uint256 tokenCost)
    {
        // Get normalized prices from oracles
        // Gets validated ETH/USD price
        uint256 ethUsdPrice = _getSafeOraclePrice(ethUsdOracle, ethUsdDecimals);
        // Gets validated token/USD price
        uint256 tokenUsdPrice = _getSafeOraclePrice(token0UsdOracle, token0UsdDecimals);

        // Converts gas cost from Wei to USD
        uint256 gasCostUsd = (gasCostWei * ethUsdPrice) / 1e18;

        // First threshold check: Caps gas cost at maximum USD value
        if (gasCostUsd > MAX_GAS_COST_USD) {
            gasCostUsd = MAX_GAS_COST_USD;
        }

        // Second threshold check
        uint256 maxGasCostByValue = (tradeValueUsd * MAX_GAS_COST_BASIS_POINTS) / 10_000;
        if (gasCostUsd > maxGasCostByValue) {
            gasCostUsd = maxGasCostByValue;
        }

        // Convert USD gas cost to token amount
        tokenCost = (gasCostUsd * 1e18) / tokenUsdPrice;

        // Scales result to Q96 format for pool compatibility
        tokenCost = (tokenCost * priceX96) >> 96;
    }

    /**
     * @notice Calculates the USD value of a trade using oracle prices.
     *
     * @param delta                         The balance changes from the swap.
     *
     * @return                              The USD value of the trade.
     */
    function _calculateTradeValueUsd(BalanceDelta delta) internal view returns (uint256) {
        // Get token amounts
        uint256 amount0 = delta.amount0 > 0 ? uint256(delta.amount0) : uint256(-delta.amount0);
        uint256 amount1 = delta.amount1 > 0 ? uint256(delta.amount1) : uint256(-delta.amount1);

        // Get token prices in USD
        uint256 token0Price = _getSafeOraclePrice(token0UsdOracle, token0UsdDecimals);
        uint256 token1Price = _getSafeOraclePrice(token1UsdOracle, token1UsdDecimals);

        // Calculate total value (taking larger of the two values)
        uint256 value0 = (amount0 * token0Price) / 1e18;
        uint256 value1 = (amount1 * token1Price) / 1e18;

        return value0 > value1 ? value0 : value1;
    }

    /**
     * @notice Retrieves and validates the latest price from a Chainlink oracle,
     *         ensuring the price is fresh and normalizing to 18 decimals.
     *
     * @param oracle                        The Chainlink price feed aggregator interface.
     * @param decimals                      The number of decimals used by the oracle.
     *
     * @return                              The normalized price with 18 decimals.
     *
     * @dev Reverts if:
     *      - Price is stale (older than MAX_ORACLE_AGE)
     *      - Round is not complete
     *      - Price is zero or negative
     *      - Normalized price is zero
     */
    function _getSafeOraclePrice(AggregatorV3Interface oracle, uint8 decimals) internal view returns (uint256) {
        // Get latest price data from oracle
        (
            uint80 roundId,
            int256 price,
            , // Unused startedAt timestamp
            uint256 updatedAt,
            uint80 answeredInRound
        ) = oracle.latestRoundData(); // Gets latest price data from Chainlink oracle

        // Check if price is stale
        if (block.timestamp - updatedAt > MAX_ORACLE_AGE) {
            // Checks if price is too old
            revert DPW_StalePrice(updatedAt);
        }

        // Ensure round is complete
        if (answeredInRound < roundId) {
            revert DPW_StalePrice(updatedAt);
        }

        // Validate price is positive
        if (price <= 0) {
            revert DPW_InvalidPrice(price);
        }

        // Normalize to 18 decimals
        uint256 normalizedPrice;
        if (decimals < 18) {
            normalizedPrice = uint256(price) * 10 ** (18 - decimals); // Multiplies up if oracle uses fewer decimals
        } else if (decimals > 18) {
            normalizedPrice = uint256(price) / 10 ** (decimals - 18); // Divides down if oracle uses more decimals
        } else {
            normalizedPrice = uint256(price); // Uses price as-is if already 18 decimals
        }

        // Final validation of normalized price
        if (normalizedPrice == 0) revert DPW_InvalidPrice(price);

        return normalizedPrice;
    }
}

