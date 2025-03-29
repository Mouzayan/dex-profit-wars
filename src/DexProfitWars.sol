// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol"; // REMOVE
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
 *         Ties are resolved by comparing profit percentages first, then by the earlier trade timestamp,
 *         and finally by higher trade volume in USD.
 *
 *         The contract uses oracles to fetch current price data for gas, ETH, token0, and token1. Oracle
 *         data is updated at defined intervals and validated for freshness to ensure accurate and current
 *         pricing; once verified, the values are cached to minimize repetitive on-chain computations.
 *         Calculating values in USD ensures fair comparisons across different token pairs and enables
 *         consistent contest performance metrics.
 *
 *         This design paves the way for future enhancements, including reward distribution mechanisms
 *         where winners can earn token rewards to encourage trading in the pair pool and competition.
 *         Moreover, the leaderboard system and potential reward system, lends itself to various applications
 *         such as airdrops, memecoin launches, and even copy-trading platforms, where users can opt in to
 *         have high-performing trades automatically executed on their behalf for a fee.
 *
 * @dev    The contract currently assumes all tokens adhere to an 18-decimal standard for simplicity in value
 *         conversion. Future iterations will accommodate tokens with different decimal precisions.
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
    // struct to track trader statistics
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

    // =================== State Variables ==================
    mapping(uint256 => Leaderboard) private pastContestLeaderboards;
    mapping(address => uint256) public snapshotGas;
    mapping(address => TraderStats) public traderStats;

    bool public contestActive;
    uint64 public contestEndTime;
    uint128 public currentContestId;

    IPoolManager public immutable manager;
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
    // ONE * ONE
    uint256 constant ONE_SQUARED = 1e36;
    uint256 constant CONTEST_DURATION = 2 days;
    uint256 public constant ORACLE_CACHE_INTERVAL = 1 minutes;
    // maximum age for oracle data
    uint256 public constant MAX_ORACLE_AGE = 1 hours;

    // price oracle interfaces
    AggregatorV3Interface public immutable gasPriceOracle;
    AggregatorV3Interface public immutable token0PriceOracle; // token0 price in USD
    AggregatorV3Interface public immutable token1PriceOracle; // token1 price in USD
    AggregatorV3Interface public immutable ethUsdOracle;

    // ====================== Immutables ====================
    // oracle decimals
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
        if (valueInUSD == 0) {
            profitPercentage = 0;
        } else if (valueOutUSD > valueInUSD + gasCostUSD) {
            profitPercentage = int256(((valueOutUSD - (valueInUSD + gasCostUSD)) * BPS_MULTIPLIER) / valueInUSD);
        } else {
            profitPercentage = -int256((((valueInUSD + gasCostUSD) - valueOutUSD) * BPS_MULTIPLIER) / valueInUSD);
        }
        console.log("HOOK: profitPercentage (bps):", profitPercentage);

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

    // ======================================== MUTATIVE FUNCTIONS ========================================
    /** TODO: FIX NATSPEC
     * @notice Starts a new 2-day contest.
     *         Resets the current leaderboard, increments the contestId,
     *         sets the contest end time, and forces an immediate oracle update.
     *
     * @dev Only the owner can start a contest.
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

    /** TODO: FIX NATSPEC
     * @notice Ends the current contest manually.
     *         Archives the current leaderboard into pastContestLeaderboards.
     *
     * @dev Only the owner can end a contest.
     */
    function endContest() external onlyOwner nonReentrant {
        if (!contestActive) revert NoActiveContest();

        _archiveCurrentContest();
        emit ContestEnded(currentContestId);
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

    // TODO: NATSPEC
    // _updateLeaderboard updates the leaderboard for the current trading contest window
    // if the trader already has an entry, it updates it only if the new trade is better
    // otherwise, it inserts the new entry if there is space or if it beats the worst entry
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
}
