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

    // token currencies in the pool
    Currency public token0;
    Currency public token1;

    DexProfitWars public hook;

    MockV3Aggregator public ethUsdOracle;
    MockV3Aggregator public token0UsdOracle;
    MockV3Aggregator public token1UsdOracle;

    address USER = makeAddr("USER");

    int256 constant SEND_VALUE_LARGE = 100e18;
    int256 constant SEND_VALUE_SMALL = 1e16;
    uint256 constant ONE = 1e18;
    uint256 constant FOUR = 4e18;
    uint256 constant INITIAL_LIQUIDITY = 500e18;
    uint256 constant SCALING_FACTOR = 1e9; // Needed ???
    uint256 constant MINIMUM_PROFIT_BPS = 200; // 2% minimum profit
    uint256 constant GAS_PRICE = 15; // 15 gewi
    bool constant ZERO_FOR_ONE = true; // user trading token0 for token1

    function setUp() public {
        // deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();

        // deploy two test tokens
        (token0, token1) = deployMintAndApprove2Currencies();

        // approve the tokens for spending
        MockERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouter), type(uint256).max);

        // mint a bunch of tokens to the user
        MockERC20(Currency.unwrap(token0)).mint(USER, 10000e18);
        MockERC20(Currency.unwrap(token1)).mint(USER, 10000e18);

        // deploy mock price feeds (Chainlink typically uses 8 decimals)
        ethUsdOracle = new MockV3Aggregator(8, 2000e8); // ETH = $2000
        token0UsdOracle = new MockV3Aggregator(8, int256(ONE)); // TOKEN0 = $1
        token1UsdOracle = new MockV3Aggregator(8, int256(FOUR)); // TOKEN1 = $4 (4 x token0)

        // deploy hook to an address with the proper flags
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags);

        bytes memory constructorArgs = abi.encode(
            address(manager),
            address(ethUsdOracle),
            address(token0UsdOracle),
            address(token1UsdOracle)
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
            SQRT_PRICE_1_2 // initialize with token1 being worth 4x token0
        );

        // TODO: REMOVE????
        // add initial liquidity to the pool REMOVE????
        //uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(-60);
        //uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(60);
        // uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(
        //     sqrtPriceAtTickLower,
        //     SQRT_PRICE_1_2,
        //     INITIAL_LIQUIDITY
        // );

        // add initial liquidity to the pool
        modifyLiquidityRouter.modifyLiquidity{value: INITIAL_LIQUIDITY}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int256(INITIAL_LIQUIDITY),
                salt: bytes32(0)
            }),
            ""
        );

        vm.txGasPrice(GAS_PRICE);
    }

    function test_makeTrade() public {
        vm.startPrank(USER);

        // approve tokens
        MockERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(token0)).approve(address(manager), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(manager), type(uint256).max);
        MockERC20(Currency.unwrap(token0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(hook), type(uint256).max);

        // user's token0 balance before the trade
        uint256 userToken0BalanceBefore = token0.balanceOf(USER);

        // since ZERO_FOR_ONE is true, it will pull token0 from the user
        hook.makeTrade(key, -50, true, uint256(SEND_VALUE_LARGE));

        // verify that the user's token0 balance decreased by SEND_VALUE_LARGE
        uint256 userToken0BalanceAfter = token0.balanceOf(USER);
        assertEq(int256(userToken0BalanceBefore) - int256(userToken0BalanceAfter), SEND_VALUE_LARGE);

        // verify that the hook contract now holds the input tokens
        uint256 hookToken0Balance = MockERC20(Currency.unwrap(key.currency0)).balanceOf(address(hook));
        assertEq(int256(hookToken0Balance), SEND_VALUE_LARGE);
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
        DexProfitWars.TraderStats memory stats = hook.getTraderStats(USER);
        console.log("TEST totalTrades", stats.totalTrades);
        console.log("TEST Best trade percentage (bps)", stats.bestTradePercentage);
        console.log("TEST Profitable trades", stats.profitableTrades);
        console.log("TEST Stats totalBonusPoints", stats.totalBonusPoints);
        console.log("TEST Stats lastTradeTimestamp", stats.lastTradeTimestamp);

        // Assertions
        assertEq(stats.totalTrades, 2);
        assertEq(stats.profitableTrades, 0);
        assertEq(stats.bestTradePercentage, 0, "No profitable trade");
        assertTrue(
            stats.bestTradePercentage <= int256(MINIMUM_PROFIT_BPS),
            "Profit should not meet minimum threshold"
        );

        // Test that gas costs were properly factored in
        uint256 balanceAfter = token1.balanceOf(USER);
        uint256 amountReceived = balanceAfter - userToken1Before;
        console.log("TEST Amount received", amountReceived);
    }

    // forge test --match-path test/DexProfitWars.t.sol --match-test test_calculateSwapPnL_Profitable -vvv
    function test_calculateSwapPnL_Profit() public {
        console.log("!!! TEST Contract ADDRESS", address(this));
        console.log("!!! TEST calculateSwapPnL_PROFIT");

        vm.startPrank(USER);
        // approve tokens
        MockERC20(Currency.unwrap(token0)).approve(address(manager), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(manager), type(uint256).max);
        MockERC20(Currency.unwrap(token0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(hook), type(uint256).max);

        uint256 userToken0Before = token0.balanceOf(USER);
        uint256 userToken1Before = token1.balanceOf(USER);

        bytes memory hookData = abi.encode(
            USER,
            userToken0Before,
            userToken1Before
        );

        hook.makeTrade(key, -50, true, uint256(SEND_VALUE_LARGE));

        vm.stopPrank();
        // Verify the swap worked
        assertLt(token0.balanceOf(USER), userToken0Before, "User should have spent token0");
        assertGt(token1.balanceOf(USER), userToken1Before, "User should have received token1");

        console.log("TEST block.timestamp", block.timestamp);

        console.log("!!! TEST token0 balance of TEST AFTER:", token0.balanceOf(USER));
        console.log("!!! TEST token1 balance of TEST AFTER:", token1.balanceOf(USER));
        // Get trader stats after swap
        DexProfitWars.TraderStats memory stats = hook.getTraderStats(USER);
        console.log("TEST USER", USER);
        console.log("TEST totalTrades", stats.totalTrades);
        console.log("TEST Best trade percentage (bps)", stats.bestTradePercentage);
        console.log("TEST Profitable trades", stats.profitableTrades);
        console.log("TEST Stats totalBonusPoints", stats.totalBonusPoints);
        console.log("TEST Stats lastTradeTimestamp", stats.lastTradeTimestamp);

        // Assertions
        assertEq(stats.totalTrades, 1);
        assertEq(stats.profitableTrades, 0);
        assertEq(stats.bestTradePercentage, 0, "No profitable trade");
        assertTrue(
            stats.bestTradePercentage <= int256(MINIMUM_PROFIT_BPS),
            "Profit should not meet minimum threshold"
        );

        uint256 userToken0After = token0.balanceOf(USER);
        assertLt(userToken0After, userToken0Before, "User should have spent token0");

        uint256 balanceAfter = token1.balanceOf(USER);
        uint256 amountReceived = balanceAfter - userToken1Before;
        console.log("TEST token1 balanceAfter", balanceAfter);
        console.log("TEST Amount received", amountReceived);
    }

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
