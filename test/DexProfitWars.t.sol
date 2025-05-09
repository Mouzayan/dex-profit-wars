// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.26;

import {Test, console, Vm} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {DexProfitWars} from "../src/DexProfitWars.sol";

contract DexProfitWarsTest is Test, Deployers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    DexProfitWars public hook;
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
    // trader addresses for testing
    address TRADER1 = makeAddr("TRADER1");
    address TRADER2 = makeAddr("TRADER2");
    address TRADER3 = makeAddr("TRADER3");

    uint256 constant ONE = 1e18;
    uint256 constant INITIAL_LIQUIDITY = 500e18;
    bool constant ZERO_FOR_ONE = true; // user trading token0 for token1
    // set GAS_PRICE in wei (15 gwei = 15e9 wei)
    uint256 constant GAS_PRICE = 15e9;

    /// @notice helper function to simulate an actual swap on UniswapV4 by calling swapRouter.swap
    /// @param trader The address executing the swap
    /// @param swapAmount The absolute value of token amount input (in token0 units) – will be negative
    /// @param tickOffset The number of ticks below the current tick to use as price limit
    function testSwap(
        address trader,
        uint256 swapAmount,
        int24 tickOffset
    ) internal {
        vm.startPrank(trader);
        // approve tokens for swapping
        MockERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(swapRouter), type(uint256).max);

        // get current tick from manager
        (, int24 currentTick, ,) = manager.getSlot0(key.toId());
        int24 tickLimit = currentTick - tickOffset;
        uint160 sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(tickLimit);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: ZERO_FOR_ONE,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        bytes memory hookData = abi.encode(trader);

        swapRouter.swap(key, params, testSettings, hookData);
        vm.stopPrank();
    }

    function setUp() public {
        // deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();

        // deploy two test tokens
        (token0, token1) = deployMintAndApprove2Currencies();
        // mint user some tokens
        MockERC20(Currency.unwrap(token0)).mint(USER, 10000e18);
        MockERC20(Currency.unwrap(token1)).mint(USER, 10000e18);
        // mint traders some tokens
        MockERC20(Currency.unwrap(token0)).mint(TRADER1, 10000e18);
        MockERC20(Currency.unwrap(token1)).mint(TRADER1, 10000e18);
        MockERC20(Currency.unwrap(token0)).mint(TRADER2, 10000e18);
        MockERC20(Currency.unwrap(token1)).mint(TRADER2, 10000e18);
        MockERC20(Currency.unwrap(token0)).mint(TRADER3, 10000e18);
        MockERC20(Currency.unwrap(token1)).mint(TRADER3, 10000e18);

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

    function test_swapPnL_Loss() public {
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

    function test_swapPnL_Profit() public {
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

    // Three traders with profitable trades get onto the leaderboard,
    // in the right order based on profit percentages
    function test_leaderboardThreeTradersProfit() public {
        // warp to nonzero time so the aggregator’s updatedAt is not 0
        vm.warp(1000);

        // update the mock aggregator answers
        ethUsdOracle.updateAnswer(2000e8); // set price to $2000, with updatedAt = block.timestamp
        token0Oracle.updateAnswer(1e8);    // $1
        token1Oracle.updateAnswer(2e8);    // $2
        gasPriceOracle.updateAnswer(15e8); // 15 gwei

        hook.startContest();

        // Each trader performs a swap with different input amounts to generate distinct profits
        // Trader 1: moderate swap
        testSwap(TRADER1, 50e18, 15);
        // Trader 2: larger swap that yields higher profit
        testSwap(TRADER2, 70e18, 10);
        // Trader 3: smaller swap that yields lower profit
        testSwap(TRADER3, 30e18, 20);

        // Retrieve the current leaderboard from the hook.
        DexProfitWars.LeaderboardEntry[3] memory board = hook.getCurrentLeaderboard();

        // Retrieve each trader's best profit percentage from their stats.
        (, , int256 profit1, ,) = hook.getTraderStats(TRADER1);
        (, , int256 profit2, ,) = hook.getTraderStats(TRADER2);
        (, , int256 profit3, ,) = hook.getTraderStats(TRADER3);

        // determine the expected ordering by sorting the three profit percentages
        address highest;
        address middle;
        address lowest;
        if (profit1 >= profit2 && profit1 >= profit3) {
            highest = TRADER1;
            if (profit2 >= profit3) {
                middle = TRADER2;
                lowest = TRADER3;
            } else {
                middle = TRADER3;
                lowest = TRADER2;
            }
        } else if (profit2 >= profit1 && profit2 >= profit3) {
            highest = TRADER2;
            if (profit1 >= profit3) {
                middle = TRADER1;
                lowest = TRADER3;
            } else {
                middle = TRADER3;
                lowest = TRADER1;
            }
        } else {
            highest = TRADER3;
            if (profit1 >= profit2) {
                middle = TRADER1;
                lowest = TRADER2;
            } else {
                middle = TRADER2;
                lowest = TRADER1;
            }
        }

        // ssert that the leaderboard ordering matches the sorted order
        assertEq(board[0].trader, highest);
        assertEq(board[1].trader, middle);
        assertEq(board[2].trader, lowest);
    }

    // Three traders are on the leaderboard and one trades twice, only higher
    // profit percentage is reflected on the leaderboard
    function test_leaderboardUpdatesOnBetterTrade() public {
        vm.warp(1000);

        ethUsdOracle.updateAnswer(2000e8);
        token0Oracle.updateAnswer(1e8);
        token1Oracle.updateAnswer(2e8);
        gasPriceOracle.updateAnswer(15e8);

        hook.startContest();

        // record logs from TRADER2's initial swap
        vm.recordLogs();
        testSwap(TRADER2, 8e18, 10);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // expose the profit percentage
        bytes32 eventSig = keccak256("TraderProfited(address,int128,uint64)");
        int256 profitFromEvent;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == eventSig) {
                address eventTrader = address(uint160(uint256(logs[i].topics[1])));
                // decode the remaining params
                (int128 tradePercentage, uint64 tradeTimestamp)
                    = abi.decode(logs[i].data, (int128, uint64));

                if (eventTrader == TRADER2) {
                    profitFromEvent = tradePercentage;
                    break;
                }
            }
        }

        testSwap(TRADER1, 30e18, 10);

        vm.warp(block.timestamp + 120);
        testSwap(TRADER3, 80e18, 10);

        // record logs from TRADER2's second swap
        vm.recordLogs();
        testSwap(TRADER2, 5e18, 15);
        Vm.Log[] memory logs2 = vm.getRecordedLogs();

        // expose the profit percentage
        bytes32 eventSig2 = keccak256("TraderProfited(address,int128,uint64)");
        int256 profitFromEvent2;
        for (uint256 i = 0; i < logs2.length; i++) {
            if (logs2[i].topics.length > 0 && logs2[i].topics[0] == eventSig2) {
                address eventTrader = address(uint160(uint256(logs2[i].topics[1])));
                // decode the remaining params
                (int128 tradePercentage2, uint64 tradeTimestamp)
                    = abi.decode(logs2[i].data, (int128, uint64));

                if (eventTrader == TRADER2) {
                    profitFromEvent2 = tradePercentage2;
                    break;
                }
            }
        }
        assertGt(profitFromEvent, profitFromEvent2);

        // check the updated leaderboard
        DexProfitWars.LeaderboardEntry[3] memory boardUpdated = hook.getCurrentLeaderboard();
        int256 updatedTrader2Profit;
        for (uint8 i = 0; i < boardUpdated.length; i++) {
            if (boardUpdated[i].trader == TRADER2) {
                updatedTrader2Profit = boardUpdated[i].profitPercentage;
            }
        }
        // the higher profit percent for trader 2 is reflect in the leaderboard
        assertEq(profitFromEvent, updatedTrader2Profit);
    }

    // Two traders get the exact same profit percentage,
    // and the tie is broken based on who traded earlier
    function test_tieBrokenByTimestamp() public {
        vm.warp(1000);

        ethUsdOracle.updateAnswer(2000e8);
        token0Oracle.updateAnswer(1e8);
        token1Oracle.updateAnswer(2e8);
        gasPriceOracle.updateAnswer(15e8);

        hook.startContest();

        // set the swap tick
        int24 tickOffset = 10;

        // base timestamp
        uint256 t0 = block.timestamp;

        // TRADER3 swaps at t0 + 10
        vm.warp(t0 + 10);
        testSwap(TRADER3, 1e14, tickOffset);

        // TRADER1 swaps at t0 + 20
        vm.warp(t0 + 20);
        testSwap(TRADER1, 1e16, tickOffset);

        // retrieve the leaderboard
        DexProfitWars.LeaderboardEntry[3] memory board = hook.getCurrentLeaderboard();

        // both trades have the same profit percentage
        (, , int256 profit1, ,) = hook.getTraderStats(TRADER1);
        (, , int256 profit3, ,) = hook.getTraderStats(TRADER3);
        assertEq(profit3, profit1);

        // the tie-breaker is the earlier timestamp,
        // favors TRADER3
        assertEq(board[0].trader, TRADER3);
        assertEq(board[1].trader, TRADER1);
    }

    // Two traders get the exact same profit percentage and same timestamp;
    // the tie is broken based on bigger trade volume
    function test_tieBrokenByTradeVolume() public {
        vm.warp(1000);

        ethUsdOracle.updateAnswer(2000e8);
        token0Oracle.updateAnswer(1e8);
        token1Oracle.updateAnswer(2e8);
        gasPriceOracle.updateAnswer(15e8);

        hook.startContest();

        uint256 tokensSpent_T1 = 3e13;
        uint256 tokensSpent_T2 = 50e14; // TRADER2 does bigger volume

        // both trades happen at the same timestamp
        vm.warp(block.timestamp + 10);

        testSwap(TRADER1, tokensSpent_T1, 15);
        testSwap(TRADER2, tokensSpent_T2, 0);

        DexProfitWars.LeaderboardEntry[3] memory board = hook.getCurrentLeaderboard();

        (, , int256 profit1, , ) = hook.getTraderStats(TRADER1);
        (, , int256 profit2, , ) = hook.getTraderStats(TRADER2);
        assertEq(profit1, profit2);

        // both trades have the same timestamp and same profit percentage,
        // the tiebreaker is bigger volume so TRADER2 ranks first
        assertEq(board[0].trader, TRADER2);
        assertEq(board[1].trader, TRADER1);
    }
}