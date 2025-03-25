// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {console} from "forge-std/Test.sol"; // REMOVE
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol"; // Is THIS NEEDED ????
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {AggregatorV3Interface} from "chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol"; // ?? BOTH IMPORTS  NEEDED??
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol"; // ?? BOTH IMPROTS NEEDED??
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

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
 *         - Add bonus locking period - IMPORTANT
 *         - Add Copy Trading feature
 *         - Add events, add custom errors
 *         - Reentrancy, CEI ??
 */
contract DexProfitWars is BaseHook {
    using StateLibrary for IPoolManager;
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
        int256 bestTradePercentage; // personal best / best trade % within current bonus window
        uint256 totalBonusPoints;
        uint256 lastTradeTimestamp;
    }

    struct SwapGasTracking {
        uint256 gasStart;
        uint160 sqrtPriceX96Before;
    }

    // Mapping to store trader statistics
    mapping(address => TraderStats) public traderStats;
    mapping(address => SwapGasTracking) public swapGasTracker;
    // track reward tokens earned by each user
    mapping(address => uint256) public balanceOf;

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
    uint256 private constant MAX_ORACLE_AGE = 1 hours;
    uint256 private constant BONUS_WINDOW = 2 days; // VALUE TO BE RE-THOUGHT
    // 1e14 i.e., 0.0001 tokens per 1% profit
    uint256 constant BASE_BONUS_RATE = 1e14;
    uint256 constant MINIMUM_PROFIT_BPS = 200; // 2% minimum profit

    // Price oracle interfaces
    // Make these private??????
    AggregatorV3Interface public ethUsdOracle;
    AggregatorV3Interface public token0UsdOracle;
    AggregatorV3Interface public token1UsdOracle;

    // Oracle decimals
    uint8 private immutable ethUsdDecimals;
    uint8 private immutable token0UsdDecimals;
    uint8 private immutable token1UsdDecimals;

    IPoolManager manager;

    // ============================================= ERRORS =============================================
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
        manager = _manager;
        // Initialize price feed interfaces
        ethUsdOracle = AggregatorV3Interface(_ethUsdOracle); // Creates interface to ETH/USD price feed
        token0UsdOracle = AggregatorV3Interface(_token0UsdOracle); // Creates interface to Token0/USD price feed
        token1UsdOracle = AggregatorV3Interface(_token1UsdOracle); // Creates interface to Token1/USD price feed

        // Store decimal precision values to avoid repeated external calls
        ethUsdDecimals = ethUsdOracle.decimals(); // Stores ETH/USD feed decimal precision
        token0UsdDecimals = token0UsdOracle.decimals(); // Stores Token0/USD feed decimal precision
        token1UsdDecimals = token1UsdOracle.decimals(); // Stores Token1/USD feed decimal precision
    }

    // ========================================= HOOK PERMISSIONS =========================================
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
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // to store initial state
            afterSwap: true, // to calculate profits
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /** // TODO: FIX Natspec
     * @notice Allows a user to make a trade by sending tokens to the hook.
     *         The function pulls the user's tokens using transferFrom.
     *
     * @param key                           The pool key for the swap
     * @param tickToSellAt                  The tick at which the user wishes to sell
     * @param zeroForOne                    If true, user is selling currency0 for currency1; otherwise vice versa
     * @param inputAmount                   The amount of tokens the user is depositing
     *
     * @return tick                         The rounded tick at which the order is recorded
     */
    function makeTrade(
        PoolKey calldata key,
        int24 tickToSellAt,
        bool zeroForOne,
        uint256 inputAmount
    ) external returns (int24) {
        // round the requested tick down to the nearest multiple of tickSpacing
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);

        // determine which token is being sold
        address sellToken = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);

        // pull funds from the user to this contract
        // user must have approved this beforehand
        IERC20(sellToken).transferFrom(msg.sender, address(this), inputAmount);

        return tick;
    }

    // TODO: MOVE TO INTERNAL FUNCTIONS
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
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal
      override
      returns (bytes4, BeforeSwapDelta, uint24)
    {
        console.log("CONTRACT ENTERED BS");

        // Decode the trader and initial balances from hookData
        (
            address trader,
            uint256 token0Before,
            uint256 token1Before
        ) = abi.decode(hookData, (address, uint256, uint256));
        console.log("CONTRACT BS token0Before", token0Before);
        console.log("CONTRACT BS token1Before", token1Before);

        // store gas usage and price data for the swap
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        swapGasTracker[sender] = SwapGasTracking({
            gasStart: gasleft(), // Record remaining gas
            sqrtPriceX96Before: sqrtPriceX96 // Record starting price
        });

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, key.fee);
    }

    // TODO: MOVE TO INTERNAL FUNCTIONS
    /**
     * @notice Calculates the profit/loss after a swap completes, including gas costs,
     *         and updates trader statistics if profit threshold is met.
     *         The _afterSwap hook is called by the PoolManager after a swap completes.
     *         It instructs the PoolManager to transfer the output tokens to this hook contract.
     *
     * @dev This function is only callable by the PoolManager.
     *
     * @param sender                        The address that initiated the swap.
     * @param key                           The pool key containing token pair and fee information.
     * @param params                        The swap parameters including amount and direction.
     * @param delta                         The balance changes resulting from the swap.
     * @param hookData                      /////// TODO: ADD this
     *
     * @return                              The function selector to indicate successful hook execution.
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal
      override
      onlyPoolManager
      returns (bytes4, int128)
    {
        // decode the user address and before txn balances
        (
            address traderAddress,
            uint256 token0BeforeBal,
            uint256 token1BeforeBal
        ) = abi.decode(hookData, (address, uint256, uint256));
        console.log("CONTRACT AFTERSWAP: traderAddress", traderAddress);
        console.log("CONTRACT AFTERSWAP: token0BeforeBal", token0BeforeBal);
        console.log("CONTRACT AFTERSWAP: token1BeforeBal", token1BeforeBal);

        if (params.zeroForOne && delta.amount1() > 0) {
            uint128 amountOut = uint128(delta.amount1());
            // manager to take currency1 from its reserves and send it to this contract
            manager.take(key.currency1, address(this), amountOut);
        } else if (!params.zeroForOne && delta.amount0() > 0) {
            uint128 amountOut = uint128(delta.amount0());
            // if opposite swap direction, take currency0
            manager.take(key.currency0, address(this), amountOut);
        }

        // Compute how much trader actually spent/received
        (uint256 token0Change, uint256 token1Change) = _computeTokenChanges(
            traderAddress,
            key,
            params.zeroForOne,
            token0BeforeBal,
            token1BeforeBal
        );
        console.log("CONTRACT AS token0Change", token1Change);
        console.log("CONTRACT AS token1Change", token1Change);

        // retrieve gas usage
        (
            uint160 sqrtPriceX96After,
            uint256 gasUsed,
            uint256 gasPrice,
            uint160 sqrtPriceX96Before
        ) = _getPnLParameters(sender, key);

        // calculate profit percentage
        int256 profitPercentage = _calculateSwapPnL_UserBalances(
            token0Change,
            token1Change,
            sqrtPriceX96Before,
            sqrtPriceX96After,
            gasUsed,
            gasPrice,
            params.zeroForOne
        );
        //console.log("CONTRACT AS profitPercentage", profitPercentage);

        // update stats for the actual trader
        _updateTraderStats(traderAddress, profitPercentage);

        delete swapGasTracker[sender];
        return (this.afterSwap.selector, 0);
    }

    // ADD NATSPEC
    function getTraderStats(address trader) public view returns (TraderStats memory) {
        return traderStats[trader];
    }

    // ========================================= HELPER FUNCTIONS ========================================
    // TODO NATSPEC
    function _getPnLParameters(address sender, PoolKey calldata key)
        internal
        returns (
            uint160 sqrtPriceX96After,
            uint256 gasUsed,
            uint256 gasPrice,
            uint160 sqrtPriceX96Before
        )
    {
        (sqrtPriceX96After,,,) = manager.getSlot0(key.toId());
        // Retrieve stored gas data from before swap
        SwapGasTracking memory tracking = swapGasTracker[sender];
        gasUsed = tracking.gasStart - gasleft();
        gasPrice = tx.gasprice;
        sqrtPriceX96Before = tracking.sqrtPriceX96Before;
    }

    // TODO NATSPEC
    function _computeTokenChanges(
        address trader,
        PoolKey calldata key,
        bool zeroForOne,
        uint256 token0BeforeBal,
        uint256 token1BeforeBal
    ) internal
      view
      returns (uint256 token0Change, uint256 token1Change)
    {
        ERC20 erc0 = ERC20(Currency.unwrap(key.currency0));
        ERC20 erc1 = ERC20(Currency.unwrap(key.currency1));

        console.log("CONTRACT COMPUTE TOKEN CHANGES token0BeforeBal,", token0BeforeBal);
        console.log("CONTRACT COMPUTE TOKEN CHANGES token1BeforeBal", token1BeforeBal);

        uint256 token0After = erc0.balanceOf(trader);
        uint256 token1After = erc1.balanceOf(trader);
        console.log("CONTRACT COMPUTE TOKEN CHANGES token0After", token0After);
        console.log("CONTRACT COMPUTE TOKEN CHANGES token1After", token1After);

        // compute how many tokens the user actually spent / gained
        if (zeroForOne) {
            // user spent token0, gained token1
            token0Change = (token0BeforeBal > token0After) ? (token0BeforeBal - token0After) : 0;
            token1Change = (token1After > token1BeforeBal) ? (token1After - token1BeforeBal) : 0;
        } else {
            // user spent token1, gained token0
            token0Change = (token0After > token0BeforeBal) ? (token0After - token0BeforeBal) : 0;
            token1Change = (token1BeforeBal > token1After) ? (token1BeforeBal - token1After) : 0;
        }

        // logs to show smaller deltas ***
        // e.g. scaled by 1e18 for readability if tokens have 18 decimals
        if (token0Change > 0) {
            console.log(
                "DexProfitWars: token0Spent (scaled) =",
                token0Change / 1e18
            );
        }
        if (token1Change > 0) {
            console.log(
                "DexProfitWars: token1Spent (scaled) =",
                token1Change / 1e18
            );
        }
    }

    // TODO: add Natspec
    function _getUserBalances(address trader, PoolKey calldata key)
        internal
        view
        returns (uint256 token0Balance, uint256 token1Balance)
    {
        ERC20 erc0 = ERC20(Currency.unwrap(key.currency0));
        ERC20 erc1 = ERC20(Currency.unwrap(key.currency1));

        token0Balance = erc0.balanceOf(trader);
        token1Balance = erc1.balanceOf(trader);
    }

    // TODO: add Natspec
    function _calculateSwapPnL_UserBalances(
        uint256 token0Spent,
        uint256 token1Gained,
        uint160 sqrtPriceX96Before,
        uint160 sqrtPriceX96After,
        uint256 gasUsed,
        uint256 gasPrice,
        bool zeroForOne
    )
        internal
        returns (int256 profitPercentage)
    {
        // 1. Convert Q96 sqrt price to a real price
        uint256 priceBefore = (uint256(sqrtPriceX96Before) * sqrtPriceX96Before) >> 192;
        uint256 priceAfter  = (uint256(sqrtPriceX96After)  * sqrtPriceX96After)  >> 192;

        // 2. Calculate the "value in" and "value out"
        //    If zeroForOne, userSpent token0, gained token1
        //    So valueIn is token0Spent * priceBefore, valueOut is token1Gained * priceAfter
        uint256 valueIn;
        uint256 valueOut;

        if (zeroForOne) {
            valueIn  = token0Spent * priceBefore;
            valueOut = token1Gained * priceAfter;
        } else {
            // The inverse: userSpent token1, gained token0
            // price is token1 per token0, so you might invert or handle carefully
            // For simplicity, assume token1Spent * (1 / priceBefore)
            // or do separate oracles for each side
            // ...
        }

        // 3. Subtract gas cost
        uint256 gasCostWei = gasUsed * _getGasPrice();
        uint256 gasCostInTokens = _convertGasCostToTokens(gasCostWei, priceBefore);
        if (valueOut <= gasCostInTokens) {
            return -1_000_000; // -100%
        }
        valueOut -= gasCostInTokens;

        // 4. Return final percentage
        if (valueOut > valueIn) {
            profitPercentage = int256(((valueOut - valueIn) * 1e6) / valueIn);
        } else {
            profitPercentage = -int256(((valueIn - valueOut) * 1e6) / valueIn);
        }
        console.log("CONTRACT profitPercentage", profitPercentage);
        return profitPercentage;
    }

    /**
     * @notice Updates trader statistics after a profitable trade.
     *
     * @param trader                        The address of the trader.
     * @param profitPercentage              The calculated profit percentage (scaled by 1e6).
     */
    function _updateTraderStats(address trader, int256 profitPercentage) internal {
        TraderStats storage stats = traderStats[trader];

        // Update trade counts
        stats.totalTrades++;
        // Only update profitable trade stats if we made it here
        // (we know profit exceeds minimum threshold from afterSwap check)
        // increment if trade is profitable
        if (profitPercentage > 0) { // Make sure this check is working
            stats.profitableTrades++;
        }

        // Calculate bonus points based on profit percentage
        uint256 bonusPoints = _calculateBonus(trader, profitPercentage);
        if (bonusPoints > 0) {
            stats.totalBonusPoints += bonusPoints;
            balanceOf[trader] += bonusPoints;
        }

        // Update best trade percentage if better
        if (profitPercentage > stats.bestTradePercentage) {
            stats.bestTradePercentage = profitPercentage;
        }

        stats.lastTradeTimestamp = block.timestamp;

        // REMOVE BELOW !!!
        TraderStats memory stats2 = traderStats[trader];
        console.log("CONTRACT traderStats[trader] totalTrades", stats2.totalTrades);
        console.log("CONTRACT traderStats[trader] profitableTrades", stats2.profitableTrades);
        console.log("CONTRACT traderStats[trader] bestTradePercentage", stats2.bestTradePercentage);
        console.log("CONTRACT traderStats[trader] totalBonusPoints", stats2.totalBonusPoints);
        console.log("CONTRACT traderStats[trader] lastTradeTimestamp", stats2.lastTradeTimestamp);
    }

    /**
     * @notice Calculates the percentage profit/loss for a swap including gas costs.
     *
     * @param delta                         The balance changes from the swap.
     * @param sqrtPriceX96Before            Price before swap in Q96 format.
     * @param sqrtPriceX96After             Price after swap in Q96 format.
     * @param gasUsed                       Amount of gas used in the swap.
     * @param gasPrice                      Current gas price in Wei.
     *
     * @return profitPercentage             The profit/loss as a percentage (scaled by 1e6, where 1_000_000 = 100%)
     */
    function _calculateSwapPnL(
        BalanceDelta delta,
        uint160 sqrtPriceX96Before,
        uint160 sqrtPriceX96After,
        uint256 gasUsed,
        uint256 gasPrice
    ) internal returns (int256 profitPercentage) {
        // convert Q96 sqrt price to an actual price (token1/token0)
        uint256 priceBefore = (uint256(sqrtPriceX96Before) * sqrtPriceX96Before) >> 192;
        uint256 priceAfter = (uint256(sqrtPriceX96After)  * sqrtPriceX96After)  >> 192;
        console.log("CONTRACT priceBefore", priceBefore);
        console.log("CONTRACT priceAfter", priceAfter);

        // Get the int128 values
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        console.log("CONTRACT amount0", amount0);
        console.log("CONTRACT amount1", amount1);

        // Get absolute values of tokens swapped
        uint256 tokenInAmount = amount0 > 0 ? uint256(uint128(amount0)) : uint256(uint128(amount1));
        uint256 tokenOutAmount = amount0 > 0 ? uint256(uint128(-amount1)) : uint256(uint128(-amount0));
        console.log("CONTRACT tokenInAmount", tokenInAmount);
        console.log("CONTRACT tokenOutAmount", tokenOutAmount);

        // Calculate values (in terms of one token)
        uint256 valueIn = tokenInAmount * priceBefore;
        uint256 valueOut = tokenOutAmount * priceAfter;
        console.log("CONTRACT valueIn", valueIn);
        console.log("CONTRACT valueOut", valueOut);

        // Calculate gas costs
        uint256 gasCostWei = gasUsed * _getGasPrice();
        uint256 gasCostInTokens = _convertGasCostToTokens(gasCostWei, priceBefore);
        console.log("CONTRACT gasCostWei", gasCostWei);
        console.log("CONTRACT gasCostInTokens", gasCostInTokens);

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

    /**
     * TODO: ADD Natspec
     */
    function _calculateBonus(address trader, int256 currentProfitPercentage)
        internal
        view
        returns (uint256)
    {
        // First check if profit is positive and convert to uint256 if it is
        // if yes then convert to uint256 for comparison with MINIMUM_PROFIT_BPS
        // profit in bps (1% = 100)
        if (currentProfitPercentage <= 0 || uint256(currentProfitPercentage) < MINIMUM_PROFIT_BPS) {
            return 0; // No bonus for negative profits or trades below 2% profit
        }

        TraderStats memory stats = traderStats[trader];
        // Check if we're still within the bonus window
        bool isWithinWindow = (block.timestamp - stats.lastTradeTimestamp) <= BONUS_WINDOW;

        // Use the best trade percentage from the window for bonus calculation
        int256 profitForBonus = isWithinWindow ?
            (currentProfitPercentage > stats.bestTradePercentage ? currentProfitPercentage : stats.bestTradePercentage) :
            currentProfitPercentage;

        // Convert basis points to percentage (divide by 100)
        uint256 bonus = uint256(profitForBonus) * BASE_BONUS_RATE / 100;

        return bonus;
    }

    /**
     * @notice Converts gas costs in Wei to token value with thresholds.
     *
     * @param gasCostWei                    Gas cost in Wei.
     * @param priceX96                      Current pool price in Q96 format.
     *
     * @return tokenCost                    Gas cost converted to token value.
     *
     * @dev Applies two thresholds:
     *      - Maximum USD value (MAX_GAS_COST_USD)
     *      - Maximum percentage of trade value (MAX_GAS_COST_BASIS_POINTS)
     *      Returns the lower of the two limits
     */
    function _convertGasCostToTokens(uint256 gasCostWei, uint256 priceX96)
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
        // Get the int128 values
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        // Get token amounts
        uint256 tokenAmount0 = amount0 > 0 ? uint256(uint128(amount0)) : uint256(uint128(-amount0));
        uint256 tokenAmount1 = amount1 > 0 ? uint256(uint128(amount1)) : uint256(uint128(-amount1));

        // Get token prices in USD
        uint256 token0Price = _getSafeOraclePrice(token0UsdOracle, token0UsdDecimals);
        uint256 token1Price = _getSafeOraclePrice(token1UsdOracle, token1UsdDecimals);

        // Calculate total value (taking larger of the two values)
        uint256 value0 = (tokenAmount0 * token0Price) / 1e18;
        uint256 value1 = (tokenAmount1 * token1Price) / 1e18;

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

    /**
     * @notice Helper function to round a tick down to the nearest usable tick.
     *
     * @param tick                         The original tick value.
     * @param tickSpacing                  The tick spacing for the pool.
     *
     * @return                             The rounded-down tick.
    */
    function getLowerUsableTick(int24 tick, int24 tickSpacing) public pure returns (int24) {
        int24 intervals = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) intervals--; // round toward negative infinity
        return intervals * tickSpacing;
    }
}
