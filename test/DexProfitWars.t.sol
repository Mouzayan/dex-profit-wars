// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.26;
// TODO: CHECK IF SOME IMPORTS ARE NOT NEEDED !!!

import {Test, console} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {DexProfitWarsHarness} from "./mocks/DexProfitWarsHarness.sol";
import {DexProfitWars} from "../src/DexProfitWars.sol";

// TODO: REMOVE CONSOLE.LOGS !!!!

contract DexProfitWarsTest is Test, Deployers {
    using StateLibrary for IPoolManager; // ???? NEEDED??
    using PoolIdLibrary for PoolKey; // ???? NEEDED??
    using CurrencyLibrary for Currency;

    DexProfitWars public hook;
    DexProfitWarsHarness public harness;
    PoolSwapTest public poolSwapTest;

    // token currencies in the pool
    Currency public token0;
    Currency public token1;

    // mock oracles
    MockV3Aggregator public ethUsdOracle;
    MockV3Aggregator public token0Oracle;
    MockV3Aggregator public token1Oracle;
    MockV3Aggregator public gasPriceOracle;

    address USER = makeAddr("USER");
    // four trader addresses for testing
    address TRADER1 = makeAddr("TRADER1");
    address TRADER2 = makeAddr("TRADER2");
    address TRADER3 = makeAddr("TRADER3");
    address TRADER4 = makeAddr("TRADER4");

    int256 constant SEND_VALUE_LARGE = 100e18;
    int256 constant SEND_VALUE_SMALL = 1e16;
    uint256 constant ONE = 1e18;
    uint256 constant FOUR = 4e18;
    uint256 constant INITIAL_LIQUIDITY = 500e18;
    uint256 constant SCALING_FACTOR = 1e9; // Needed ???
    uint256 constant MINIMUM_PROFIT_BPS = 200; // 2% minimum profit
    bool constant ZERO_FOR_ONE = true; // user trading token0 for token1

    // set GAS_PRICE in wei (15 gwei = 15e9 wei)
    uint256 constant GAS_PRICE = 15e9;

    function setUp() public {
        // deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();

        // deploy two test tokens
        (token0, token1) = deployMintAndApprove2Currencies();
        // mint user some tokens
        MockERC20(Currency.unwrap(token0)).mint(USER, 10000e18);
        MockERC20(Currency.unwrap(token1)).mint(USER, 10000e18);

        // approve the tokens for spending
        MockERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouter), type(uint256).max);

        // deploy mock oracles, 8 decimals for each
        // for ETH/USD oracle: 2000 USD per ETH → 2000e8
        ethUsdOracle = new MockV3Aggregator(8, 2000e8);
        // for token0/USD oracle: token0 = $1
        token0Oracle = new MockV3Aggregator(8, 1e8);
        // for token1/USD oracle: token1 = $2
        token1Oracle = new MockV3Aggregator(8, 2e8);
        // for gas price oracle: 15 gwei → 15e8
        gasPriceOracle = new MockV3Aggregator(8, 15e8);

        // deploy hook to an address with the proper flags
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags);

        bytes memory constructorArgs = abi.encode(
            address(manager),
            address(gasPriceOracle),
            address(token0Oracle),
            address(token1Oracle),
            address(ethUsdOracle)
        );

        deployCodeTo(
            "DexProfitWars.sol",
            constructorArgs,
            hookAddress
        );
        hook = DexProfitWars(hookAddress);
        hook.transferOwnership(address(this));

        // deploy DexProfitWarsHarness
        address harnessAddress = address(flags);

        deployCodeTo(
            "DexProfitWarsHarness.sol",
            constructorArgs,
            harnessAddress
        );
        harness = DexProfitWarsHarness(harnessAddress);
        harness.transferOwnership(address(this));

        // initialize the pool
        (key,) = initPool(
            token0,
            token1,
            hook,
            3000, // 0.3% swap fees
            SQRT_PRICE_1_1
        );

        // add initial liquidity to the pool
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int256(INITIAL_LIQUIDITY),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // set the gas price (in wei) for test txns
        vm.txGasPrice(GAS_PRICE);
    }

    // /**
    //  * Utility function testSimulateTrade
    //  * This helper function (which you add to your contract for testing) simulates
    //  * a swap by letting you specify the amount of tokens spent and tokens received.
    //  * With our fixed mock oracle prices (token0 = $1 and token1 = $2), the profit
    //  * percentage is computed as:
    //  * The profit percentage is computed approximately as:
    //  * profitBps = (((2 * tokensGained) - tokensSpent) * 1e4) / tokenSpent;
    //  * Therefore:
    //  * tokensGained = tokensSpent * ((10000 + P) / (2 * 10000));
    //  * We choose tokensGained based on a desired profit (e.g. 300, 400, 500, etc.).
    //  */
    // function testSimulateTrade(
    // address trader,
    // uint256 tokensSpent,
    // uint256 tokensGained,
    // bool zeroForOne
    // ) public {
    //     // NOTE:
    //     // for testing, we are assuming gasUsed = zero

    //     // convert uint256 to int256, then to int128
    //     int256 castSpent = int256(tokensSpent);
    //     int256 castGained = int256(tokensGained);
    //     int128 sSpent = int128(castSpent);
    //     int128 sGained = int128(castGained);

    //     int128 a0;
    //     int128 a1;
    //     if (zeroForOne) {
    //         a0 = -sSpent;
    //         a1 = sGained;
    //     } else {
    //         a0 = sGained;
    //         a1 = -sSpent;
    //     }

    //     BalanceDelta delta = toBalanceDelta(a0, a1);

    //     IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
    //         zeroForOne: zeroForOne,
    //         amountSpecified: zeroForOne ? -int256(tokensSpent) : int256(tokensSpent),
    //         sqrtPriceLimitX96: 0  // dummy value not used for profit calculations
    //     });

    //     hook._afterSwap(trader, key, params, delta, abi.encode(trader));
    // }

    function test_swapAtLoss() public {
        vm.warp(block.timestamp + 120);
        hook.startContest();

        vm.startPrank(USER);
        MockERC20(Currency.unwrap(token1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);

        // user's balances before the swap
        uint256 userToken0Before = token0.balanceOf(USER);
        uint256 userToken1Before = token1.balanceOf(USER);

        // get current tick from manager
        (, int24 currentTick, ,) = manager.getSlot0(key.toId());

        // select limit ~10 ticks below the current tick
        int24 tickLimit = currentTick - 10;
        uint160 sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(tickLimit);

        // build the swap params
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: ZERO_FOR_ONE,
            amountSpecified: -int256(1e8), // exact input of token0
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // build hook data
        bytes memory hookData = abi.encode(USER);

        // do the swap
        swapRouter.swap(key, params, testSettings, hookData);

        // after the swap, check user balances
        uint256 userToken0After = MockERC20(Currency.unwrap(token0)).balanceOf(USER);
        assertEq(userToken0Before - userToken0After, 1e8);

        // check USER's token1 balance increased
        uint256 userToken1After = token1.balanceOf(USER);
        assertGt(userToken1After, userToken1Before);

        // check that the hook recorded one trade
        (uint256 totalTrades,,,,) = hook.getTraderStats(USER);
        assertEq(totalTrades, 1);

        // check that the hook recorded zero profitable trades
        (,uint256 profitableTrades,,,) = hook.getTraderStats(USER);
        assertEq(profitableTrades, 0);

        vm.stopPrank();
    }

    function test_swapAtProfit() public {
        vm.warp(block.timestamp + 120);
        hook.startContest();

        vm.startPrank(USER);
        MockERC20(Currency.unwrap(token1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);

        // user's balances before the swap
        uint256 userToken0Before = token0.balanceOf(USER);
        uint256 userToken1Before = token1.balanceOf(USER);

        // get current tick from manager
        ( , int24 currentTick, ,) = manager.getSlot0(key.toId());

        // select limit ~10 ticks below the current tick
        int24 tickLimit = currentTick - 10;
        uint160 sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(tickLimit);

        // build the swap params
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: ZERO_FOR_ONE,
            amountSpecified: -int256(50e18), // exact input of token0
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // build hook data
        bytes memory hookData = abi.encode(USER);

        // do the swap and return balance delta
        BalanceDelta swapDelta = swapRouter.swap(key, params, testSettings, hookData);

        // how many token0 the user actually spend
        int128 amt0 = swapDelta.amount0();
        uint256 tokensSpent = amt0 < 0 ? uint256(uint128(-amt0)) : 0;

        // ater the swap, check user balances
        uint256 userToken0After = MockERC20(Currency.unwrap(token0)).balanceOf(USER);
        assertEq(userToken0Before - userToken0After, tokensSpent);

        // check USER's token1 balance increased
        uint256 userToken1After = token1.balanceOf(USER);
        assertGt(userToken1After, userToken1Before);

        // check that the hook recorded one trade
        (uint256 totalTrades,,,,) = hook.getTraderStats(USER);
        assertEq(totalTrades, 1);

        // check that the hook recorded one profitable trades
        (,uint256 profitableTrades,,,) = hook.getTraderStats(USER);
        assertEq(profitableTrades, 1);

        vm.stopPrank();
    }

    function test_twoProfitableSwaps() public {
        vm.warp(block.timestamp + 120);
        hook.startContest();

        vm.startPrank(USER);
        // approve tokens for swapping
        MockERC20(Currency.unwrap(token1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);

        // --------- first swap ---------
        // get the current pool tick
        ( , int24 currentTick, ,) = manager.getSlot0(key.toId());
        int24 tickLimit = currentTick - 10;
        uint160 sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(tickLimit);

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // build swap params
        IPoolManager.SwapParams memory params1 = IPoolManager.SwapParams({
            zeroForOne: ZERO_FOR_ONE,
            amountSpecified: -int256(70e18),
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        // build hook data
        bytes memory hookData = abi.encode(USER);

        // execute first swap
        swapRouter.swap(key, params1, testSettings, hookData);

        // check trader stats
        (uint256 totalTrades1, uint256 profitableTrades1, int256 bestTradePercentage1, ,) = hook.getTraderStats(USER);
        assertEq(totalTrades1, 1);
        assertEq(profitableTrades1, 1);
        assertGt(bestTradePercentage1, 0);

        // --------- second swap ---------
        // get the updated tick from the pool after the first swap
        ( , int24 currentTick2, ,) = manager.getSlot0(key.toId());
        int24 tickLimit2 = currentTick2 - 10;
        uint160 sqrtPriceLimitX96_2 = TickMath.getSqrtPriceAtTick(tickLimit2);

        // build swap params
        IPoolManager.SwapParams memory params2 = IPoolManager.SwapParams({
            zeroForOne: ZERO_FOR_ONE,
            amountSpecified: -int256(50e18),
            sqrtPriceLimitX96: sqrtPriceLimitX96_2
        });

        // execute the second swap
        swapRouter.swap(key, params2, testSettings, hookData);

        // check trader stats after first swap
        (uint256 totalTrades, uint256 profitableTrades, int256 bestTradePercentage, ,) = hook.getTraderStats(USER);
        assertEq(totalTrades, 2);
        assertEq(profitableTrades, 2);
        // best trade percentage is updated to the highest one
        assertGe(bestTradePercentage, bestTradePercentage1);
        vm.stopPrank();
    }

    // forge test --match-path test/DexProfitWars.t.sol --match-test test_leaderboardThreeTradersProfit -vvv
    // ==================================================================
    // 1) Three traders with profitable trades get onto the leaderboard,
    //    in the right order based on profit percentages.
    // ==================================================================
    function test_leaderboardThreeTradersProfit() public {
        // Use a fixed tokensSpent for simplicity.
        uint256 tokensSpent = 100e6; // e.g. 100,000,000 units
        // Compute tokensGained such that:
        // profitBps = ((2*tokensGained - tokensSpent) * 1e4) / tokensSpent.
        // Rearranging: tokensGained = tokensSpent * (10000 + desiredBps) / (2 * 10000)
        uint256 tokensGained_T1 = (tokensSpent * (10000 + 300)) / (2 * 10000); // 300 bps for TRADER1
        uint256 tokensGained_T2 = (tokensSpent * (10000 + 500)) / (2 * 10000); // 500 bps for TRADER2
        uint256 tokensGained_T3 = (tokensSpent * (10000 + 250)) / (2 * 10000); // 250 bps for TRADER3

        // Simulate trades for three different traders (assume zeroForOne is true)
        testSimulateTrade(TRADER1, tokensSpent, tokensGained_T1, true);
        testSimulateTrade(TRADER2, tokensSpent, tokensGained_T2, true);
        testSimulateTrade(TRADER3, tokensSpent, tokensGained_T3, true);

        // Retrieve current leaderboard
        DexProfitWars.LeaderboardEntry[3] memory board = hook.getCurrentLeaderboard();

        // Expected ordering:
        // Highest profit (500 bps) -> TRADER2, then 300 bps -> TRADER1, then 250 bps -> TRADER3.
        assertEq(board[0].trader, TRADER2, "TRADER2 should rank first (500 bps)");
        assertEq(board[1].trader, TRADER1, "TRADER1 should rank second (300 bps)");
        assertEq(board[2].trader, TRADER3, "TRADER3 should rank third (250 bps)");
    }

    // forge test --match-path test/DexProfitWars.t.sol --match-test test_existingTraderUpdatesProfit -vvv
    // ==================================================================
    // 2) Three traders are on the leaderboard and one (TRADER2) gets a new
    //    higher profit percentage during the contest window; his entry is updated.
    // ==================================================================
    function test_existingTraderUpdatesProfit() public {
        uint256 tokensSpent = 100e6;
        // Initial trades:
        uint256 tokensGained_T1 = (tokensSpent * (10000 + 300)) / (2 * 10000); // 300 bps
        uint256 tokensGained_T2 = (tokensSpent * (10000 + 400)) / (2 * 10000); // 400 bps
        uint256 tokensGained_T3 = (tokensSpent * (10000 + 200)) / (2 * 10000); // 200 bps

        testSimulateTrade(TRADER1, tokensSpent, tokensGained_T1, true);
        testSimulateTrade(TRADER2, tokensSpent, tokensGained_T2, true);
        testSimulateTrade(TRADER3, tokensSpent, tokensGained_T3, true);

        // Now, simulate a new trade for TRADER2 with a higher profit: 600 bps.
        uint256 tokensGained_T2_new = (tokensSpent * (10000 + 600)) / (2 * 10000);
        testSimulateTrade(TRADER2, tokensSpent, tokensGained_T2_new, true);

        // Retrieve the updated leaderboard.
        DexProfitWars.LeaderboardEntry[3] memory board = hook.getCurrentLeaderboard();

        // Expect TRADER2 to now have the highest profit (600 bps)
        assertEq(board[0].trader, TRADER2, "TRADER2 should be updated to rank first (600 bps)");
        // TRADER1 and TRADER3 remain in the board with their initial profits.
        assertEq(board[1].trader, TRADER1, "TRADER1 should remain second (300 bps)");
        assertEq(board[2].trader, TRADER3, "TRADER3 should remain third (200 bps)");
    }

    // forge test --match-path test/DexProfitWars.t.sol --match-test test_tieBrokenByTimestamp -vvv
    // ==================================================================
    // 3) Two traders get the exact same profit percentage,
    //    and the tie is broken based on who traded earlier.
    // ==================================================================
    function test_tieBrokenByTimestamp() public {
        uint256 tokensSpent = 100e6;
        uint256 tokensGained = (tokensSpent * (10000 + 300)) / (2 * 10000); // 300 bps profit

        // Simulate TRADER1 trading first.
        vm.warp(block.timestamp + 10); // set time to t + 10
        testSimulateTrade(TRADER1, tokensSpent, tokensGained, true);

        // Simulate TRADER2 trading later.
        vm.warp(block.timestamp + 20); // now time increased further
        testSimulateTrade(TRADER2, tokensSpent, tokensGained, true);

        // Retrieve leaderboard; both trades have 300 bps profit.
        // Tie-breaker should put the earlier trade (TRADER1) ahead.
        DexProfitWars.LeaderboardEntry[3] memory board = hook.getCurrentLeaderboard();
        assertEq(board[0].trader, TRADER1, "TRADER1 should rank above TRADER2 (earlier timestamp)");
        assertEq(board[1].trader, TRADER2, "TRADER2 should rank second");
    }

    // forge test --match-path test/DexProfitWars.t.sol --match-test test_tieBrokenByTradeVolume -vvv
    // ==================================================================
    // 4) Two traders get the exact same profit percentage and same timestamp;
    //    the tie is broken based on bigger trade volume.
    // ==================================================================
    function test_tieBrokenByTradeVolume() public {
        // Use different trade volumes but same profit percentage.
        uint256 tokensSpent_T1 = 100e6;
        uint256 tokensSpent_T2 = 150e6; // larger volume for TRADER2
        uint256 tokensGained_T1 = (tokensSpent_T1 * (10000 + 300)) / (2 * 10000);
        uint256 tokensGained_T2 = (tokensSpent_T2 * (10000 + 300)) / (2 * 10000);

        // Ensure both trades occur at the same timestamp.
        uint256 t = block.timestamp + 10;
        vm.warp(t);
        testSimulateTrade(TRADER1, tokensSpent_T1, tokensGained_T1, true);
        testSimulateTrade(TRADER2, tokensSpent_T2, tokensGained_T2, true);

        // Now, with equal profit percentage and timestamp, TRADER2 should win due to bigger volume.
        DexProfitWars.LeaderboardEntry[3] memory board = hook.getCurrentLeaderboard();
        assertEq(board[0].trader, TRADER2, "TRADER2 should rank first (bigger volume)");
        assertEq(board[1].trader, TRADER1, "TRADER1 should rank second");
    }

    // forge test --match-path test/DexProfitWars.t.sol --match-test test_getCurrentLeaderboard -vvv
    // ==================================================================
    // 5) Test that getCurrentLeaderboard shows the correct entries.
    // ==================================================================
    function test_getCurrentLeaderboard() public {
        // Simulate two trades.
        uint256 tokensSpent = 100e6;
        uint256 tokensGained_T1 = (tokensSpent * (10000 + 300)) / (2 * 10000);
        uint256 tokensGained_T2 = (tokensSpent * (10000 + 400)) / (2 * 10000);

        testSimulateTrade(TRADER1, tokensSpent, tokensGained_T1, true);
        testSimulateTrade(TRADER2, tokensSpent, tokensGained_T2, true);

        // Retrieve current leaderboard.
        DexProfitWars.LeaderboardEntry[3] memory board = hook.getCurrentLeaderboard();

        // Expect the top two entries to be filled (TRADER2 with higher profit, then TRADER1)
        // and the third slot to be empty.
        assertEq(board[0].trader, TRADER2, "TRADER2 should be #1");
        assertEq(board[1].trader, TRADER1, "TRADER1 should be #2");
        assertEq(board[2].trader, address(0), "Slot #3 should be empty");
    }
}
