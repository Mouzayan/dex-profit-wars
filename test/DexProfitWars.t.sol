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
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {DexProfitWars} from "../src/DexProfitWars.sol";

// TODO: REMOVE CONSOLE.LOGS !!!!

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
    // forge test --match-path test/DexProfitWars.t.sol --match-test test_twoProfitableSwaps -vvv
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
}
