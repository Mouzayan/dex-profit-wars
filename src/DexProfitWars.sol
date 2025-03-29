// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol"; // REMOVE
import {AggregatorV3Interface} from "chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Ownable} from "v4-periphery/lib/permit2/lib/openzeppelin-contracts/contracts/access/Ownable.sol";

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
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
 *         - Add bonus locking period - IMPORTANT
 *         - Add Copy Trading feature
 *         - Add events, add custom errors
 *         - Reentrancy, CEI ??
 */
contract DexProfitWars is BaseHook, Ownable {
    using BalanceDeltaLibrary for BalanceDelta;

    // ===================== Structures =====================
    // struct to track trader statistics
    struct TraderStats {
        uint256 totalTrades;
        uint256 profitableTrades;
        int256 bestTradePercentage; // personal best in basis points
        uint256 totalBonusPoints;
        uint256 lastTradeTimestamp;
    }

    // pepresents an individual record in the trading contest leaderboard
    struct LeaderboardEntry {
        address trader;
        int256 profitPercentage; // profit in basis points
        uint256 tradeVolumeUSD;  // trade dollar volume
        uint256 timestamp;
    }

    // the leaderboard for a given contest window holds up to 3 entries
    struct Leaderboard {
        LeaderboardEntry[3] entries;
    }

    // =================== State Variables ==================
    // Archive past contest leaderboards, keyed by contestId
    mapping(uint256 => Leaderboard) private pastContestLeaderboards;

    // gas snapshot for each trader
    mapping(address => uint256) public snapshotGas;
    // trader stats
    mapping(address => TraderStats) public traderStats;

    bool public contestActive;
    uint256 public contestEndTime;
    uint256 public currentContestId;

    IPoolManager manager;
    // the current contest leaderboard
    Leaderboard private currentLeaderboard;

    // ====================== Constants ====================
    // constants DOES THIS NEED TO BE PRIVATE?
    // 2% profit minimum profit threshold expressed in basis points
    uint256 constant MINIMUM_PROFIT_BPS = 200;
    // using multiplier 1e4 so 2% = 200 bps
    uint256 constant BPS_MULTIPLIER = 1e4;
    // fixed-point 1.0 with 18 decimals
    uint256 constant ONE = 1e18;
    // 1e18 * 1e18
    uint256 constant ONE_SQUARED = 1e36;
    uint256 constant CONTEST_DURATION = 2 days;

    // price oracle interfaces
    AggregatorV3Interface public gasPriceOracle;
    AggregatorV3Interface public token0PriceOracle; // token0 price in USD
    AggregatorV3Interface public token1PriceOracle; // token1 price in USD
    AggregatorV3Interface public ethUsdOracle;

    // ====================== Immutables ====================
    // oracle decimals
    uint8 private immutable gasPriceOracleDecimals;
    uint8 private immutable token0PriceOracleDecimals;
    uint8 private immutable token1PriceOracleDecimals;
    uint8 private immutable ethUsdOracleDecimals;

    // ==================== Oracle Cashing ===================
    uint256 private cachedGasPrice;
    uint256 private cachedEthPriceUSD;
    uint256 private cachedToken0PriceUSD;
    uint256 private cachedToken1PriceUSD;
    uint256 private lastOracleCacheUpdate;
    uint256 constant ORACLE_CACHE_INTERVAL = 1 minutes;

    // ============================================= ERRORS =============================================
    // Create separate errors file
    // error DPW_StalePrice(uint256 timestamp);
    // error DPW_InvalidPrice(int256 price);

    // ========================================== CONSTRUCTOR ===========================================
    // /** FOX NATSPEC
    //  * @notice Sets up the DexProfitWars contract by initializing the pool manager and price oracles,
    //  *         and storing their decimal precision values.
    //  *
    //  * @param _manager                      The Uniswap V4 pool manager contract address.
    //  * @param _ethUsdOracle                 The address of the ETH/USD Chainlink price feed.
    //  * @param _token0UsdOracle              The address of the Token0/USD Chainlink price feed.
    //  * @param _token1UsdOracle              The address of the Token1/USD Chainlink price feed.
    //  */
    constructor(
        IPoolManager _manager,
        address _gasPriceOracle,
        address _token0PriceOracle,
        address _token1PriceOracle,
        address _ethUsdOracle
    )
        BaseHook(_manager)
    {
        manager = _manager;

        gasPriceOracle = AggregatorV3Interface(_gasPriceOracle);
        gasPriceOracleDecimals = gasPriceOracle.decimals();

        token0PriceOracle = AggregatorV3Interface(_token0PriceOracle);
        token0PriceOracleDecimals = token0PriceOracle.decimals();

        token1PriceOracle = AggregatorV3Interface(_token1PriceOracle);
        token1PriceOracleDecimals = token1PriceOracle.decimals();

        ethUsdOracle = AggregatorV3Interface(_ethUsdOracle);
        ethUsdOracleDecimals = ethUsdOracle.decimals();
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
            beforeSwap: true, // record gas snapshot
            afterSwap: true, // compute PnL swapDelta and gas cost from oracle
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // =========================================== HOOK CALLBACKS ==========================================
    // TODO: MOVE TO INTERNAL FUNCTIONS
    /** _beforeSwap records the trader’s pre-swap gas balance. FIX NATSPEc
     * @notice Before-swap hook: record the price and gas usage so we can do PnL calculations later.
     * In _beforeSwap, we record the trader's initial token balances and the gas left.
     */
    /**
     * @notice Records the initial state before a swap occurs, including gas usage and price.
     *         This data is used to calculate profit/loss and gas costs in afterSwap.
     *
     * @param key                           The pool key containing token pair and fee information.
     *
     * @return                              The function selector to indicate successful hook execution.
     */
    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata hookData
    ) internal override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        // decode hookData
        address trader = abi.decode(hookData, (address));
        snapshotGas[trader] = gasleft();

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, key.fee);
    }

    // TODO: MOVE TO INTERNAL FUNCTIONS
    /** Compute PnL using the swapDelta and gas cost from the Chainlink oracle.
     * // Compute the net profit percentage in USD terms.
     * @notice After-swap hook: do PnL logic and update user stats. No token settlement here anymore.
     * In _afterSwap, we compute how much the trader's balances changed.

     * @notice Calculates the profit/loss after a swap completes, including gas costs,
     *         and updates trader statistics if profit threshold is met.
     *         The _afterSwap hook is called by the PoolManager after a swap completes.
     *         It instructs the PoolManager to transfer the output tokens to this hook contract.
     *
     * @dev This function is only callable by the PoolManager.
     *
     * @param params                        The swap parameters including amount and direction.
     * @param delta                         The balance changes resulting from the swap.
     * @param hookData                      /////// TODO: ADD this
     *
     * @return                              The function selector to indicate successful hook execution.
     */
    function _afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override onlyPoolManager returns (bytes4, int128) {
        // if contest is active but the contest period has ended, archive the contest
        if (contestActive && block.timestamp >= contestEndTime) {
            _archiveCurrentContest();
        }

        // decode hookData to get the trader
        (address trader) = abi.decode(hookData, (address));

        // retrieve gas snapshot
        uint256 gasBefore = snapshotGas[trader];
        uint256 gasUsed = gasBefore > gasleft() ? (gasBefore - gasleft()) : 0;

        // refresh oracle cache if necessary
        _updateOracleCache();
        uint256 avgGasPrice = cachedGasPrice;
        uint256 ethPriceUSD = cachedEthPriceUSD;
        uint256 token0PriceUSD = cachedToken0PriceUSD;
        uint256 token1PriceUSD = cachedToken1PriceUSD;

        // calculate gas cost in USD
        uint256 gasCostUSD = ((gasUsed * avgGasPrice) * ethPriceUSD) / ONE_SQUARED;

        // determine token amounts exchanged
        int128 amt0 = delta.amount0();
        int128 amt1 = delta.amount1();
        uint256 tokensSpent;
        uint256 tokensGained;
        if (params.zeroForOne) {
            // userSpent = negative of amt0 if amt0 < 0
            tokensSpent = amt0 < 0 ? uint256(uint128(-amt0)) : 0;
            tokensGained = amt1 > 0 ? uint256(uint128(amt1)) : 0;
        } else {
            // userSpent = negative of amt1 if amt1 < 0
            tokensSpent = amt1 < 0 ? uint256(uint128(-amt1)) : 0;
            tokensGained = amt0 > 0 ? uint256(uint128(amt0)) : 0;
        }
        console.log("CONTRACT tokensSpent: -------------", tokensSpent);
console.log("CONTRACT token0PriceUSD: ------------------", token0PriceUSD);

        // convert token amounts to USD values assuming 18 decimals
        uint256 valueInUSD;
        uint256 valueOutUSD;
        if (params.zeroForOne) {
            valueInUSD = (tokensSpent * token0PriceUSD) / ONE;
            valueOutUSD = (tokensGained * token1PriceUSD) / ONE;
        } else {
            valueInUSD = (tokensSpent * token1PriceUSD) / ONE;
            valueOutUSD = (tokensGained * token0PriceUSD) / ONE;
        }
console.log("CONTRACT valueInUSD: --------------", valueInUSD);
        // calculate profit percentage in basis points
        int256 profitPercentage;
        if (valueOutUSD > valueInUSD + gasCostUSD) {
            profitPercentage = int256(((valueOutUSD - (valueInUSD + gasCostUSD)) * BPS_MULTIPLIER) / valueInUSD);
        } else {
            profitPercentage = -int256((((valueInUSD + gasCostUSD) - valueOutUSD) * BPS_MULTIPLIER) / valueInUSD);
        }
        console.log("HOOK: profitPercentage (bps):", profitPercentage);

        // update trader stats
        TraderStats storage stats = traderStats[trader];
        stats.totalTrades++;
        if (profitPercentage > 0) {
            stats.profitableTrades++;
            if (profitPercentage > stats.bestTradePercentage) {
                stats.bestTradePercentage = profitPercentage;
            }
        }
        stats.lastTradeTimestamp = block.timestamp;

        // if contest is active, update the leaderboard for qualifying trades
        if (contestActive && profitPercentage > int256(MINIMUM_PROFIT_BPS)) {
            _updateLeaderboard(trader, profitPercentage, valueInUSD, block.timestamp);
        }

        // clear snapshot
        delete snapshotGas[trader];
        return (BaseHook.afterSwap.selector, 0);
    }

    // ======================================== MUTATIVE FUNCTIONS ========================================
    /** TODO: FIX NATSPEC
     * @notice Starts a new 2-day contest.
     *         Resets the current leaderboard, increments the contestId,
     *         sets the contest end time, and forces an immediate oracle update.
     *
     * @dev Only the owner can start a contest.
     */
    function startContest() external onlyOwner {
        require(!contestActive, "Contest already active");

        currentContestId++;
        contestActive = true;
        contestEndTime = block.timestamp + CONTEST_DURATION;

        delete currentLeaderboard;
        // force an immediate oracle update
        lastOracleCacheUpdate = 0;

        _updateOracleCache();
    }

    /** TODO: FIX NATSPEC
     * @notice Ends the current contest manually.
     *         Archives the current leaderboard into pastContestLeaderboards.
     *
     * @dev Only the owner can end a contest.
     */
    function endContest() external onlyOwner {
        require(contestActive, "No active contest");

        _archiveCurrentContest();
    }

    // ========================================= GETTER FUNCTIONS =======================================
    // ADD NATSPEC
    function getTraderStats(address trader) public view returns (uint256, uint256, int256, uint256, uint256) {
        TraderStats memory stats = traderStats[trader];
        return (stats.totalTrades, stats.profitableTrades, stats.bestTradePercentage, stats.totalBonusPoints, stats.lastTradeTimestamp);
    }

    /** TODO: FIX NATSPEC
     * @notice Returns the leaderboard for a given contest by contestId
     */
    function getContestLeaderboard(uint256 contestId) external view returns (LeaderboardEntry[3] memory) {
        return pastContestLeaderboards[contestId].entries;
    }

    /** TODO: FIX NATSPEC
     * @notice Returns the current contest's leaderboard even if the contest is over.
     */
    function getCurrentLeaderboard() external view returns (LeaderboardEntry[3] memory) {
        return currentLeaderboard.entries;
    }

    // TODO: FIX NATSPEC
    function getPastContestLeaderboard(uint256 contestId) external view returns (LeaderboardEntry[3] memory) {
        return pastContestLeaderboards[contestId].entries;
    }

    // ========================================= HELPER FUNCTIONS ========================================
    // TODO: FIX NATSPEC
    // Internal function to archive the current contest and mark contest as inactive.
    function _archiveCurrentContest() internal {
        pastContestLeaderboards[currentContestId] = currentLeaderboard;
        contestActive = false;
    }

    // TODO: NATSPEC
    // updates the oracle cache if the cache interval has passed
    function _updateOracleCache() internal {
        if (block.timestamp - lastOracleCacheUpdate >= ORACLE_CACHE_INTERVAL) {
            // update gas price
            (, int256 gasAnswer, , ,) = gasPriceOracle.latestRoundData();
            require(gasAnswer > 0, "Invalid gas price");

            uint256 _gasPrice = _scalePrice(uint256(gasAnswer), gasPriceOracleDecimals, 18);
            cachedGasPrice = _gasPrice;

            // update ETH price
            (, int256 ethAnswer, , ,) = ethUsdOracle.latestRoundData();
            require(ethAnswer > 0, "Invalid eth price");

            uint256 _ethPrice = _scalePrice(uint256(ethAnswer), ethUsdOracleDecimals, 18);
            cachedEthPriceUSD = _ethPrice;

            // update token0 price
            (, int256 token0Answer, , ,) = token0PriceOracle.latestRoundData();
            require(token0Answer > 0, "Invalid token0 price");

            uint256 _token0Price = _scalePrice(uint256(token0Answer), token0PriceOracleDecimals, 18);
            cachedToken0PriceUSD = _token0Price;

            // update token1 price
            (, int256 token1Answer, , ,) = token1PriceOracle.latestRoundData();
            require(token1Answer > 0, "Invalid token1 price");

            uint256 _token1Price = _scalePrice(uint256(token1Answer), token1PriceOracleDecimals, 18);
            cachedToken1PriceUSD = _token1Price;

            lastOracleCacheUpdate = block.timestamp;
        }
    }

    // TODO: NATSPEC
    // _updateLeaderboard updates the leaderboard for the current trading contest window
    // if the trader already has an entry, it updates it only if the new trade is better
    // otherwise, it inserts the new entry if there is space or if it beats the worst entry
    function _updateLeaderboard(
        address trader,
        int256 profitPercentage,
        uint256 tradeVolumeUSD,
        uint256 timestamp
    ) internal {
        Leaderboard storage lb = currentLeaderboard;

        // check if the trader already exists in the leaderboard
        bool found = false;
        uint8 indexFound = 0;
        for (uint8 i = 0; i < 3; i++) {
            if (lb.entries[i].trader == trader) {
                found = true;
                indexFound = i;
                break;
            }
        }

        if (found) {
            // only update if the new trade is better than the current record
            if (_isBetter(profitPercentage, timestamp, tradeVolumeUSD, lb.entries[indexFound])) {
                lb.entries[indexFound] = LeaderboardEntry(trader, profitPercentage, tradeVolumeUSD, timestamp);
            } else {
                return;
            }
        } else {
            // if trader is not present, look for an empty slot
            bool inserted = false;
            for (uint8 i = 0; i < 3; i++) {
                if (lb.entries[i].trader == address(0)) {
                    lb.entries[i] = LeaderboardEntry(trader, profitPercentage, tradeVolumeUSD, timestamp);
                    inserted = true;
                    break;
                }
            }
            if (!inserted) {
                // all slots are filled, find the worst entry
                uint8 worstIndex = 0;
                for (uint8 i = 1; i < 3; i++) {
                    if (!_isBetter(
                        lb.entries[i].profitPercentage,
                        lb.entries[i].timestamp,
                        lb.entries[i].tradeVolumeUSD,
                        lb.entries[worstIndex]
                    )) {
                        worstIndex = i;
                    }
                }
                // replace the worst entry if the new trade is better
                if (_isBetter(profitPercentage, timestamp, tradeVolumeUSD, lb.entries[worstIndex])) {
                    lb.entries[worstIndex] = LeaderboardEntry(trader, profitPercentage, tradeVolumeUSD, timestamp);
                } else {
                    return;
                }
            }
        }
        // re-sort the leaderboard in descending order
        for (uint8 i = 0; i < 3; i++) {
            for (uint8 j = i + 1; j < 3; j++) {
                if (_isBetter(
                    lb.entries[j].profitPercentage,
                    lb.entries[j].timestamp,
                    lb.entries[j].tradeVolumeUSD,
                    lb.entries[i]
                )) {
                    LeaderboardEntry memory temp = lb.entries[i];
                    lb.entries[i] = lb.entries[j];
                    lb.entries[j] = temp;
                }
            }
        }
    }

    // TODO: NATSPEC
    // _isBetter compares a new trade (profit, timestamp, volume) against an existing leaderboard entry
    // It returns true if the new trade is better.
    // Comparison order:
    // 1. higher profit percentage wins
    // 2. if equal, the earlier timestamp wins
    // 3. if still equal, the higher trade volume wins
    function _isBetter(
        int256 profitA,
        uint256 timestampA,
        uint256 volumeA,
        LeaderboardEntry memory entryB
    ) internal pure returns (bool) {
        if (entryB.trader == address(0)) {
            return true;
        }

        if (profitA > entryB.profitPercentage) {
            return true;
        } else if (profitA < entryB.profitPercentage) {
            return false;
        }

        if (timestampA < entryB.timestamp) {
            return true;
        } else if (timestampA > entryB.timestamp) {
            return false;
        }

        if (volumeA > entryB.tradeVolumeUSD) {
            return true;
        }

        return false;
    }

    /** TODO: NATSPEC
     * @dev Scales a price from `priceDecimals` to `targetDecimals`.
     * unction is designed to adjust a price value from one fixed-point precision (number of decimals) to another
     * This ensures that all price values are standardized to the same number of decimals (in this case, 18)
     */
    function _scalePrice(
        uint256 price,
        uint8 priceDecimals,
        uint8 targetDecimals
    ) internal pure returns (uint256) {
        //if the source decimals are lower than the target decimals
        if (priceDecimals < targetDecimals) {
            return price * (10 ** (targetDecimals - priceDecimals));
        // if the source decimals are higher than the target decimals
        } else if (priceDecimals > targetDecimals) {
            return price / (10 ** (priceDecimals - targetDecimals));
        }
        // if they are equal
        return price;
    }

    // // TODO: NATSPEC
    // // --- Helper function: Get average gas price from the gasPriceOracle
    // function _getAverageGasPrice() internal view returns (uint256) {
    //     (, int256 answer, , ,) = gasPriceOracle.latestRoundData();
    //     require(answer > 0, "Invalid gas price");

    //     // convert to uint256 and scale based on the oracle decimals
    //     uint256 gasPrice = uint256(answer);

    //     // oracle has 8 decimals, scale to 18 decimals:
    //     if (gasPriceOracleDecimals < 18) {
    //         gasPrice = gasPrice * (10 ** (18 - gasPriceOracleDecimals));
    //     } else if (gasPriceOracleDecimals > 18) {
    //         gasPrice = gasPrice / (10 ** (gasPriceOracleDecimals - 18));
    //     }

    //     return gasPrice;
    // }

    // // TODO: NATSPEC
    // // --- Helper: Get oracle price scaled to 18 decimals ---
    // function _getOraclePrice(AggregatorV3Interface oracle, uint8 decimals) internal view returns (uint256) {
    //     (, int256 answer, , , ) = oracle.latestRoundData();
    //     require(answer > 0, "Invalid price");

    //     uint256 price = uint256(answer);

    //     if (decimals < 18) {
    //         price = price * (10 ** (18 - decimals));
    //     } else if (decimals > 18) {
    //         price = price / (10 ** (decimals - 18));
    //     }

    //     return price;
    // }
}
