// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.26;

import {AggregatorV3Interface} from "chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Ownable} from "v4-periphery/lib/permit2/lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "v4-periphery/lib/permit2/lib/solmate/src/utils/ReentrancyGuard.sol";

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

/**
 * @title DexProfitWars
 * @author em_mutable
 *
 * @notice DexProfitWars is a Uniswap V4 hook that gamifies trading by running periodic contests
 *         where traders compete based on their trade profits calculated in USD. Converting trade
 *         values to USD using on-chain oracle price feeds (for ETH, token0, token1, and gas prices)
 *         allows for an objective, cross-token comparison of performance. The contest operates over
 *         a 2‑day window and can be started or stopped at the discretion of the contract owner.
 *         When a contest is active, any trade that achieves a profit above a 2% threshold (in basis
 *         points) is eligible to be recorded on the contest leaderboard.
 *
 *         The leaderboard is maintained as a fixed-size array of 3 winners, ensuring that on-chain
 *         computations remain gas efficient. Each time an eligible trade is executed, the contract
 *         checks if the trader already has an entry. If so, it updates the trader's record only if
 *         the new trade is better. If not, the trade is inserted into the leaderboard if there is
 *         an open slot or if it outperforms the current worst entry.
 *         Ties are resolved by comparing profit percentages first, then by the earlier trade
 *         timestamp, and finally by higher trade volume in USD.
 *
 *         The contract uses oracles to fetch current price data for gas, ETH, token0, and token1.
 *         Oracle data is updated at defined intervals and validated for freshness to ensure accurate
 *         and current pricing; once verified, the values are cached to minimize repetitive on-chain
 *         computations. Calculating values in USD ensures fair comparisons across different token
 *         pairs and enables consistent contest performance metrics.
 *
 *         This design paves the way for future enhancements, including reward distribution mechanisms
 *         where winners can earn token rewards to encourage trading in the pair pool and competition.
 *         Moreover, the leaderboard system and potential reward system, lends itself to various
 *         applications such as airdrops, memecoin launches, and even copy-trading platforms, where
 *         users can opt in to have high-performing trades automatically executed on their behalf for
 *         a fee.
 *
 * @dev    The contract currently assumes all tokens adhere to an 18-decimal standard for simplicity in
 *         value conversion. Future iterations will accommodate tokens with different decimal precisions.
 *
 *         The contract caches oracle data (gas price, ETH price, token0 price, and token1 price) to reduce
 *         gas costs, with updates occurring at an hourly interval to balance efficiency and data freshness.
 *
 */
contract DexProfitWars is BaseHook, Ownable, ReentrancyGuard {
    using BalanceDeltaLibrary for BalanceDelta;

    // ======================= Custom Errors ======================
    error InvalidGasPrice();
    error GasPriceStale();
    error InvalidEthPrice();
    error EthPriceStale();
    error InvalidToken0Price();
    error Token0PriceStale();
    error InvalidToken1Price();
    error Token1PriceStale();
    error ContestAlreadyActive();
    error NoActiveContest();

    // ========================= Events =========================
    event ContestStarted(uint256 indexed contestId, uint64 contestEndTime);
    event ContestEnded(uint256 indexed contestId);
    event LeaderboardUpdated(address indexed trader, int256 profitPercentage, uint128 tradeVolumeUSD, uint64 timestamp);
    event TraderStatsUpdated(
        address indexed trader,
        uint128 totalTrades,
        uint128 profitableTrades,
        int128 bestTradePercentage,
        uint128 totalBonusPoints,
        uint64 lastTradeTimestamp
    );
    event OracleCacheUpdated(uint64 timestamp);

    // ===================== Structures =====================
    struct TraderStats {
        uint128 totalTrades;
        uint128 profitableTrades;
        int128 bestTradePercentage; // personal best in basis points
        uint128 totalBonusPoints;
        uint64 lastTradeTimestamp;
    }

    // pepresents an individual record in the trading contest leaderboard
    struct LeaderboardEntry {
        address trader;
        int256 profitPercentage; // profit in basis points
        uint128 tradeVolumeUSD;  // trade volume in USD assuming 18 decimals
        uint64 timestamp;
    }

    // the leaderboard for a given contest window holds up to 3 entries
    struct Leaderboard {
        LeaderboardEntry[3] entries;
    }

    // ==================== Global State ====================
    mapping(uint256 => Leaderboard) private pastContestLeaderboards;
    mapping(address => uint256) public snapshotGas;
    mapping(address => TraderStats) public traderStats;

    bool public contestActive;
    uint64 public contestEndTime;
    uint128 public currentContestId;

    IPoolManager public immutable manager;
    Leaderboard private currentLeaderboard;

    // ====================== Constants ====================
    // 2% profit minimum profit threshold expressed in basis points
    uint256 constant MINIMUM_PROFIT_BPS = 200;
    // using multiplier 1e4 so 2% = 200 bps
    uint256 constant BPS_MULTIPLIER = 1e4;
    // fixed-point 1.0 with 18 decimals
    uint256 constant ONE = 1e18;
    // ONE * ONE
    uint256 constant ONE_SQUARED = 1e36;
    uint256 constant CONTEST_DURATION = 2 days;
    uint256 public constant ORACLE_CACHE_INTERVAL = 1 minutes;
    uint256 public constant MAX_ORACLE_AGE = 1 hours;

    AggregatorV3Interface public immutable gasPriceOracle;
    AggregatorV3Interface public immutable token0PriceOracle; // token0 price in USD
    AggregatorV3Interface public immutable token1PriceOracle; // token1 price in USD
    AggregatorV3Interface public immutable ethUsdOracle;

    // ====================== Immutables ====================
    uint8 private immutable gasPriceOracleDecimals;
    uint8 private immutable token0PriceOracleDecimals;
    uint8 private immutable token1PriceOracleDecimals;
    uint8 private immutable ethUsdOracleDecimals;

    // ==================== Oracle Cashing ===================
    uint128 private cachedGasPrice;
    uint128 private cachedEthPriceUSD;
    uint128 private cachedToken0PriceUSD;
    uint128 private cachedToken1PriceUSD;
    uint64 private lastOracleCacheUpdate;

    // ========================================== CONSTRUCTOR ===========================================
    /**
     * @notice Initializes the DexProfitWars contract.
     *
     * @dev Sets up the contract by storing the pool manager address and initializing the Chainlink
     *      oracles for gas price, token0, token1, and ETH/USD. It also retrieves and stores each
     *      oracle's decimal precision for accurate price scaling in subsequent profit calculations.
     *
     * @param _manager                      The address of the Uniswap V4 pool manager contract.
    * @param _gasPriceOracle                The address of the gas price Chainlink oracle.
    * @param _token0PriceOracle             The address of the Token0/USD Chainlink price feed.
    * @param _token1PriceOracle             The address of the Token1/USD Chainlink price feed.
    * @param _ethUsdOracle                  The address of the ETH/USD Chainlink price feed.
     */
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
     * @return                               Hooks.Permissions struct indicating which hook functions
     *                                       are active.
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
    /**
     * @notice Executes the pre-swap hook logic.
     *
     * @dev This function is called by the pool manager before a swap is executed. It decodes the
     *      provided hookData to extract the trader’s address and then records the trader’s current gas
     *      balance. This snapshot is later used to calculate the gas consumed during the swap for
     *      profit/loss computations. It returns the beforeSwap function selector, a balance delta
     *      and the pool fee from the key.
     *
     * @param key                           The pool key containing token pair and fee information.
     * @param hookData                      Encoded data containing the trader's address.
     *
     * @return selector                     The function selector for the beforeSwap hook.
     * @return delta                        A balance delta.
     * @return fee                          The fee value extracted from the pool key.
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

    /**
     * @notice Executes the post-swap hook logic.
     *
     * @dev This function is called by the pool manager immediately after a swap completes.
     *      It first checks if the active contest has expired and, if so, archives the current contest.
     *      Then, it decodes the hook data to determine the trader’s address and calculates the gas used
     *      during the swap using a previously stored gas snapshot. The function refreshes the cached oracle
     *      prices, converts the traded token amounts into USD, and computes the net profit or loss in basis
     *      points after subtracting gas costs. Trader statistics are updated accordingly—only profitable
     *      trades that exceed a 2% profit threshold are eligible to update the leaderboard. Ties are resolved
     *      first by the trade timestamp and then by trade volume.
     *
     * @param params                        The swap parameters, including direction and exact input amount.
     * @param delta                         The balance delta representing the amounts of tokens exchanged during
     *                                      the swap.
     * @param hookData                      Encoded data containing the trader's address.
     *
     * @return selector                     The function selector for the afterSwap hook.
     * @return returnDelta                  A token settlement delta.
     */
    function _afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override onlyPoolManager nonReentrant returns (bytes4, int128) {
        if (contestActive && block.timestamp >= contestEndTime) {
            _archiveCurrentContest();
        }

        // decode hookData to get the trader
        address trader = abi.decode(hookData, (address));

        // retrieve gas snapshot
        uint256 gasBefore = snapshotGas[trader];
        uint256 gasUsed = gasBefore > gasleft() ? (gasBefore - gasleft()) : 0;

        // refresh oracle cache if necessary
        _updateOracleCache();
        uint128 avgGasPrice = cachedGasPrice;
        uint128 ethPriceUSD = cachedEthPriceUSD;
        uint128 token0PriceUSD = cachedToken0PriceUSD;
        uint128 token1PriceUSD = cachedToken1PriceUSD;

        // calculate gas cost in USD
        uint256 gasCostUSD = ((gasUsed * avgGasPrice) * ethPriceUSD) / ONE_SQUARED;

        // determine token amounts exchanged
        int128 amt0 = delta.amount0();
        int128 amt1 = delta.amount1();
        uint256 tokensSpent;
        uint256 tokensGained;
        if (params.zeroForOne) {
            tokensSpent = amt0 < 0 ? uint256(uint128(-amt0)) : 0;
            tokensGained = amt1 > 0 ? uint256(uint128(amt1)) : 0;
        } else {
            tokensSpent = amt1 < 0 ? uint256(uint128(-amt1)) : 0;
            tokensGained = amt0 > 0 ? uint256(uint128(amt0)) : 0;
        }

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

        // calculate profit percentage in basis points
        int256 profitPercentage;
        if (valueInUSD == 0) {
            profitPercentage = 0;
        } else if (valueOutUSD > valueInUSD + gasCostUSD) {
            profitPercentage = int256(((valueOutUSD - (valueInUSD + gasCostUSD)) * BPS_MULTIPLIER) / valueInUSD);
        } else {
            profitPercentage = -int256((((valueInUSD + gasCostUSD) - valueOutUSD) * BPS_MULTIPLIER) / valueInUSD);
        }

        // update trader stats
        TraderStats storage stats = traderStats[trader];
        stats.totalTrades = uint128(stats.totalTrades + 1);
        if (profitPercentage > 0) {
            stats.profitableTrades = uint128(stats.profitableTrades + 1);
            if (profitPercentage > stats.bestTradePercentage) {
                stats.bestTradePercentage = int128(profitPercentage);
            }
        }
        stats.lastTradeTimestamp = uint64(block.timestamp);
        emit TraderStatsUpdated(
            trader,
            stats.totalTrades,
            stats.profitableTrades,
            stats.bestTradePercentage,
            stats.totalBonusPoints,
            stats.lastTradeTimestamp
        );

        // if contest is active, update the leaderboard for qualifying trades
        if (contestActive && profitPercentage > int256(MINIMUM_PROFIT_BPS)) {
            _updateLeaderboard(trader, profitPercentage, valueInUSD, uint64(block.timestamp));
        }

        // clear snapshot
        delete snapshotGas[trader];
        return (BaseHook.afterSwap.selector, 0);
    }

    // ========================================== VIEW FUNCTIONS ========================================
    /**
     * @notice Retrieves the trading statistics for a specific trader.
     *
     * @dev Returns a tuple containing the total number of trades, the number of profitable trades,
     *      the best / highest trade profit percentage in basis points, the total bonus points earned,
     *      and the timestamp of the trader's last trade.
     *
     * @param trader                        The address of the trader.
     *
     * @return totalTrades                  The total number of trades executed by the trader.
     * @return profitableTrades             The number of trades that were profitable.
     * @return bestTradePercentage          The highest profit percentage (in basis points) achieved by the trader.
     * @return totalBonusPoints             The total bonus points accumulated by the trader.
     * @return lastTradeTimestamp           The timestamp of the trader's most recent trade.
     */
    function getTraderStats(address trader) public view returns (uint256, uint256, int256, uint256, uint256) {
        TraderStats memory stats = traderStats[trader];

        return (stats.totalTrades, stats.profitableTrades, stats.bestTradePercentage, stats.totalBonusPoints, stats.lastTradeTimestamp);
    }

    /**
     * @notice Retrieves the leaderboard for a specific contest.
     *
     * @dev Returns the fixed-size array of three leaderboard entries for the contest identified
     *      by contestId.
     *
     * @param contestId                     The identifier of the contest.
     *
     * @return                              An array of three LeaderboardEntry structs representing
     *                                      the leaderboard for the contest.
     */
    function getContestLeaderboard(uint256 contestId) external view returns (LeaderboardEntry[3] memory) {
        return pastContestLeaderboards[contestId].entries;
    }

    /**
     * @notice Retrieves the current contest's leaderboard.
     *
     * @dev Returns the leaderboard entries for the ongoing or most recently ended contest.
     *
     * @return                              An array of three LeaderboardEntry structs representing
     *                                      the current contest's leaderboard winners.
     */
    function getCurrentLeaderboard() external view returns (LeaderboardEntry[3] memory) {
        return currentLeaderboard.entries;
    }

    /**
     * @notice Retrieves the archived leaderboard for a past contest.
     *
     * @dev Returns the leaderboard entries for the contest identified by contestId from the archive.
     *
     * @param contestId                     The identifier of the past contest.
     *
     * @return                              An array of three LeaderboardEntry structs representing
     *                                      the archived leaderboard.
     */
    function getPastContestLeaderboard(uint256 contestId) external view returns (LeaderboardEntry[3] memory) {
        return pastContestLeaderboards[contestId].entries;
    }

    // ======================================= RESTRICTED FUNCTIONS =======================================
    /**
     * @notice Initiates a new 2-day contest.
     *
     * @dev Increments the contest identifier, resets the current leaderboard, sets the contest end time
     *      to the current block timestamp plus the contest duration, and forces an immediate update of the
     *      oracle cache to ensure fresh price data.
     */
    function startContest() external onlyOwner nonReentrant {
        if (contestActive) revert ContestAlreadyActive();

        currentContestId++;
        contestActive = true;
        contestEndTime = uint64(block.timestamp + CONTEST_DURATION);

        delete currentLeaderboard;
        // force an immediate oracle update
        lastOracleCacheUpdate = 0;

        _updateOracleCache();
        emit ContestStarted(currentContestId, contestEndTime);
    }

    /**
     * @notice Ends the active contest.
     *
     * @dev This function manually terminates the current contest by archiving the active leaderboard
     *      into pastContestLeaderboards and marking the contest as inactive.
     */
    function endContest() external onlyOwner nonReentrant {
        if (!contestActive) revert NoActiveContest();

        _archiveCurrentContest();
        emit ContestEnded(currentContestId);
    }

    // ========================================= HELPER FUNCTIONS ========================================
    /**
     * @notice Archives the current contest leaderboard and deactivates the contest.
     *
     * @dev This internal function stores the current leaderboard in the pastContestLeaderboards mapping
     *      using the currentContestId as the key, and then sets the contestActive flag to false.
     */
    function _archiveCurrentContest() internal {
        pastContestLeaderboards[currentContestId] = currentLeaderboard;
        contestActive = false;
    }

    /**
     * @notice Refreshes and caches oracle price data if the cache interval has elapsed.
     *
     * @dev Checks whether the time elapsed since the last update exceeds ORACLE_CACHE_INTERVAL.
     *      If so, it fetches the latest data from the gas price, ETH, token0, and token1 Chainlink
     *      oracles. For each oracle, it verifies that the returned answer is positive and not stale.
     *      It then scales the prices to 18 decimals, caches them, and updates the lastOracleCacheUpdate
     *      timestamp.
     */
    function _updateOracleCache() internal {
        uint256 currentTime = block.timestamp;
        if (currentTime - lastOracleCacheUpdate >= ORACLE_CACHE_INTERVAL) {
            // update gas price
            (, int256 gasAnswer, , uint256 gasTimestamp,) = gasPriceOracle.latestRoundData();
            if (gasAnswer <= 0) revert InvalidGasPrice();
            if (block.timestamp - gasTimestamp > MAX_ORACLE_AGE) revert GasPriceStale();

            cachedGasPrice = uint128(_scalePrice(uint256(gasAnswer), gasPriceOracleDecimals, 18));

            // update ETH price
            (, int256 ethAnswer, , uint256 ethTimestamp, ) = ethUsdOracle.latestRoundData();
            if (ethAnswer <= 0) revert InvalidEthPrice();
            if (currentTime - ethTimestamp > MAX_ORACLE_AGE) revert EthPriceStale();

            cachedEthPriceUSD = uint128(_scalePrice(uint256(ethAnswer), ethUsdOracleDecimals, 18));

            // update token0 price
            (, int256 token0Answer, , uint256 token0Timestamp, ) = token0PriceOracle.latestRoundData();
            if (token0Answer <= 0) revert InvalidToken0Price();
            if (currentTime - token0Timestamp > MAX_ORACLE_AGE) revert Token0PriceStale();

            cachedToken0PriceUSD = uint128(_scalePrice(uint256(token0Answer), token0PriceOracleDecimals, 18));

            // update token1 price
            (, int256 token1Answer, , uint256 token1Timestamp, ) = token1PriceOracle.latestRoundData();
            if (token1Answer <= 0) revert InvalidToken1Price();
            if (currentTime - token1Timestamp > MAX_ORACLE_AGE) revert Token1PriceStale();

            cachedToken1PriceUSD = uint128(_scalePrice(uint256(token1Answer), token1PriceOracleDecimals, 18));

            lastOracleCacheUpdate = uint64(currentTime);
            emit OracleCacheUpdated(lastOracleCacheUpdate);
        }
    }

    /**
     * @notice Updates the current contest leaderboard with a new trade record for a trader.
     *
     * @dev The function checks if the trader already exists in the current leaderboard. If so, it
     *      updates the trader’s entry only if the new trade's profit percentage is better. If the
     *      trader is not already on the leaderboard, it inserts the new record into an empty slot
     *      if available; otherwise, it replaces the worst performing entry if the new trade
     *      outperforms it. Finally, the leaderboard is re-sorted in descending order.
     *      This mechanism ensures that the leaderboard always reflects the trader’s best trade.
     *
     * @param trader                        The address of the trader whose trade is being recorded.
     * @param profitPercentage              The profit percentage in basis points of the trade.
     * @param tradeVolumeUSD                The USD value of the trade scaled to 18 decimals.
     * @param timestamp                     The block timestamp at which the trade occurred.
     */
    function _updateLeaderboard(
        address trader,
        int256 profitPercentage,
        uint256 tradeVolumeUSD,
        uint64 timestamp
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
                lb.entries[indexFound] = LeaderboardEntry(trader, profitPercentage, uint128(tradeVolumeUSD), timestamp);

                emit LeaderboardUpdated(trader, profitPercentage, uint128(tradeVolumeUSD), timestamp);
            } else {
                return;
            }
        } else {
            // if trader is not present, look for an empty slot
            bool inserted = false;
            for (uint8 i = 0; i < 3; i++) {
                if (lb.entries[i].trader == address(0)) {
                    lb.entries[i] = LeaderboardEntry(trader, profitPercentage, uint128(tradeVolumeUSD), timestamp);
                    inserted = true;

                    emit LeaderboardUpdated(trader, profitPercentage, uint128(tradeVolumeUSD), timestamp);
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
                    lb.entries[worstIndex] = LeaderboardEntry(trader, profitPercentage, uint128(tradeVolumeUSD), timestamp);

                    emit LeaderboardUpdated(trader, profitPercentage, uint128(tradeVolumeUSD), timestamp);
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

    /**
     * @notice Compares a new trade against an existing leaderboard entry.
     *
     * @dev Determines if a new trade is better than an existing leaderboard entry based on
     *      a prioritized comparison: first by higher profit percentage, then by an earlier timestamp,
     *      and finally by a higher trade volume in USD. If the existing entry has a zero address for
     *      the trader i.e. an empty slot, the new trade is automatically considered better.
     *
     * @param profitA                       The profit percentage in basis points of the new trade.
     * @param timestampA                    The timestamp of the new trade.
     * @param volumeA                       The trade volume in USD scaled to 18 decimals of the new trade.
     * @param entryB                        The existing leaderboard entry to compare against.
     *
     * @return                              True if the new trade is better than the existing entry,
     *                                      false otherwise.
     */
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

    /**
     * @notice Scales a price value from its original fixed-point precision to a target precision.
     *
     * @dev If the original number of decimals (priceDecimals) is less than the targetDecimals,
     *      the price is multiplied by 10^(targetDecimals - priceDecimals). If it is greater,
     *      the price is divided by 10^(priceDecimals - targetDecimals). If both are equal,
     *      the original price is returned unchanged.
     *
     * @param price                         The original price value.
     * @param priceDecimals                 The number of decimals in the original price.
     * @param targetDecimals                The desired number of decimals.
     *
     * @return                              The price scaled to the target decimal precision.
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
}
