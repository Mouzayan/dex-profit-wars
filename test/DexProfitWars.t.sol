// SPDX-License-Identifier: MIT

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
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {DexProfitWars} from "../src/DexProfitWars.sol";

// TODO: REMOVE CONSOLE.LOGS

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
    using StateLibrary for IPoolManager; // ???? NEEDED??
    using PoolIdLibrary for PoolKey; // ???? NEEDED??
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

    int256 constant SEND_VALUE_LARGE = 100e18;
    int256 constant SEND_VALUE_SMALL = 1e16;
    uint256 constant ONE = 1e18;
    uint256 constant FOUR = 4e18;
    uint256 constant INITIAL_LIQUIDITY = 500e18;
    uint256 constant SCALING_FACTOR = 1e9; // Needed ???
    uint256 constant MINIMUM_PROFIT_BPS = 200; // 2% minimum profit
    bool constant ZERO_FOR_ONE = true; // user trading token0 for token1

    // set GAS_PRICE in wei (15 gwei = 15e9 wei)
    uint256 constant GAS_PRICE = 15e9; // 15 gwei in wei

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

    function test_swapAtLoss() public {
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

    // to run specific test: forge test --match-path test/DexProfitWars.t.sol --match-test test_calculateSwapPnL_Unprofitable -vvv
    // Test Profit Calculation and Gas Costs
    function test_calculateSwapPnL_Loss() public {
        console.log("!!! TEST calculateSwapPnL_Loss");
        vm.prank(USER);
        uint256 userToken0Before = token0.balanceOf(USER);
        uint256 userToken1Before = token1.balanceOf(USER);

        bytes memory hookData = abi.encode(
            USER,
            userToken0Before,
            userToken1Before
        );

        // Do a swap that should be profitable
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: ZERO_FOR_ONE,
                amountSpecified: -SEND_VALUE_SMALL,  // Exact input: spending 0.01 token0
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );
        console.log("!!! TEST token0 balance of TEST AFTER:", token0.balanceOf(USER));
        console.log("!!! TEST token1 balance of TEST AFTER:", token1.balanceOf(USER));
        console.log("TEST block.timestamp", block.timestamp);
        // Get trader stats after swap
        (
            uint256 totalTrades,
            uint256 profitableTrades,
            int256 bestTradePercentage,
            uint256 totalBonusPoints,
            uint256 lastTradeTimestamp
        ) = hook.getTraderStats(USER);
        console.log("TEST totalTrades", totalTrades);
        console.log("TEST Best trade percentage (bps)", bestTradePercentage);
        console.log("TEST Profitable trades", profitableTrades);
        console.log("TEST Stats totalBonusPoints", totalBonusPoints);
        console.log("TEST Stats lastTradeTimestamp", lastTradeTimestamp);

        // Assertions
        assertEq(totalTrades, 2);
        assertEq(profitableTrades, 0);
        assertEq(bestTradePercentage, 0, "No profitable trade");
        assertTrue(
            bestTradePercentage <= int256(MINIMUM_PROFIT_BPS),
            "Profit should not meet minimum threshold"
        );

        // Test that gas costs were properly factored in
        uint256 balanceAfter = token1.balanceOf(USER);
        uint256 amountReceived = balanceAfter - userToken1Before;
        console.log("TEST Amount received", amountReceived);
    }

    // forge test --match-path test/DexProfitWars.t.sol --match-test test_calculateSwapPnL_Profitable -vvv
    // function test_calculateSwapPnL_Profit() public {
    //     console.log("!!! TEST Contract ADDRESS", address(this));
    //     console.log("!!! TEST calculateSwapPnL_PROFIT");

    //     vm.startPrank(USER);
    //     // approve tokens
    //     MockERC20(Currency.unwrap(token0)).approve(address(manager), type(uint256).max);
    //     MockERC20(Currency.unwrap(token1)).approve(address(manager), type(uint256).max);
    //     MockERC20(Currency.unwrap(token0)).approve(address(hook), type(uint256).max);
    //     MockERC20(Currency.unwrap(token1)).approve(address(hook), type(uint256).max);

    //     uint256 userToken0Before = token0.balanceOf(USER);
    //     uint256 userToken1Before = token1.balanceOf(USER);

    //     bytes memory hookData = abi.encode(
    //         USER,
    //         userToken0Before,
    //         userToken1Before
    //     );

    //     hook.makeTrade(key, -50, true, uint256(SEND_VALUE_LARGE));

    //     vm.stopPrank();
    //     // Verify the swap worked
    //     assertLt(token0.balanceOf(USER), userToken0Before, "User should have spent token0");
    //     assertGt(token1.balanceOf(USER), userToken1Before, "User should have received token1");

    //     console.log("TEST block.timestamp", block.timestamp);

    //     console.log("!!! TEST token0 balance of TEST AFTER:", token0.balanceOf(USER));
    //     console.log("!!! TEST token1 balance of TEST AFTER:", token1.balanceOf(USER));
    //     // Get trader stats after swap
    //     DexProfitWars.TraderStats memory stats = hook.getTraderStats(USER);
    //     console.log("TEST USER", USER);
    //     console.log("TEST totalTrades", stats.totalTrades);
    //     console.log("TEST Best trade percentage (bps)", stats.bestTradePercentage);
    //     console.log("TEST Profitable trades", stats.profitableTrades);
    //     console.log("TEST Stats totalBonusPoints", stats.totalBonusPoints);
    //     console.log("TEST Stats lastTradeTimestamp", stats.lastTradeTimestamp);

    //     // Assertions
    //     assertEq(stats.totalTrades, 1);
    //     assertEq(stats.profitableTrades, 0);
    //     assertEq(stats.bestTradePercentage, 0, "No profitable trade");
    //     assertTrue(
    //         stats.bestTradePercentage <= int256(MINIMUM_PROFIT_BPS),
    //         "Profit should not meet minimum threshold"
    //     );

    //     uint256 userToken0After = token0.balanceOf(USER);
    //     assertLt(userToken0After, userToken0Before, "User should have spent token0");

    //     uint256 balanceAfter = token1.balanceOf(USER);
    //     uint256 amountReceived = balanceAfter - userToken1Before;
    //     console.log("TEST token1 balanceAfter", balanceAfter);
    //     console.log("TEST Amount received", amountReceived);
    // }

    function test_abd1() public {} // Verify gas costs are correctly subtracted from profits
    function test_abd2() public {} // Test the 2% minimum profit threshold
    function test_abd3() public {} // Test negative profit / loss scenario

    // Bonus Point System
    function test_calculateBonus() public {}
    function test_calculateBonus1() public {} // Verify bonus points are awarded correctly based on profit percentage
    function test_calculateBonus2() public {} // Test the 2-day window mechanism
    function test_calculateBonus3() public {} // Test best trade percentage tracking

    // Trader Statistics
    function test_updateTraderStats() public {}
    function test_updateTraderStats1() public {} // totalTrades counter
    function test_updateTraderStats2() public {} // profitableTrades counter
    function test_updateTraderStat3() public {} // bestTradePercentage updates
    function test_updateTraderStats4() public {} // totalBonusPoints accumulation
    function test_updateTraderStats5() public {} // lastTradeTimestamp updates

    // Gas Price Caching
    function test_getGasPrice() public {} // caching mechanism
    function test_getGasPrice1() public {} // test cache update intervals

    // Full swap flow
    function test_beforeSwap() public {} // state recording
    function test_afterSwap() public {} // calculations
    function test_swapFlow() public {} // Test complete flow from swap initiation to bonus award

    // Trading Windows
    function test_bestTrades() public {} // Test trades within same 2-day window
    function test_bestTrades1() public {} // Test trades across different windows
    function test_bestTrades2() public {} // Test best trade percentage persistence

    // Edge Cases
    function test_gasExceedsTradeValue() public {} // Test gas costs exceeding trade value
    function test_gasExceedsTradeValue1() public {} // Test trades just above/below minimum profit threshold
    function test_gasExceedsTradeValue2() public {} // Test timestamp edge cases for windows

}
