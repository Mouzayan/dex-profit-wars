// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;
// TODO: CHECK IF SOME IMPORTS ARE NOT NEEDED !!!

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

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
    Currency token0;
    Currency token1;

    DexProfitWars hook;

    MockV3Aggregator ethUsdOracle;
    MockV3Aggregator token0UsdOracle;
    MockV3Aggregator token1UsdOracle;

    function setUp() public {
        // deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();

        // deploy two test tokens
        (token0, token1) = deployMintAndApprove2Currencies();

        // deploy mock price feeds (Chainlink typically uses 8 decimals)
        ethUsdOracle = new MockV3Aggregator(8, 2000e8); // ETH = $2000
        token0UsdOracle = new MockV3Aggregator(8, 1e8); // TOKEN0 = $1
        token1UsdOracle = new MockV3Aggregator(8, 1e8); // TOKEN1 = $1

        // Deploy hook to an address that has the proper flags set
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags);
        //address hookAddress = address(uint160(flags | (uint160(uint256(keccak256(bytes("DexProfitWars")))) << 40)));

        deployCodeTo(
            "DexProfitWars.sol",
            abi.encode(
                address(manager),
                address(ethUsdOracle),
                address(token0UsdOracle),
                address(token1UsdOracle)
            ),
            0,
            hookAddress
        );
        hook = DexProfitWars(hookAddress);

        // approve our hook address to spend these tokens
        MockERC20(Currency.unwrap(token0)).approve(
            address(hook),
            type(uint256).max
        );
        MockERC20(Currency.unwrap(token1)).approve(
            address(hook),
            type(uint256).max
        );

        // initialize the pool
        (key,) = initPool(
            token0,
            token1,
            hook, // Hook Contract
            3000, // Swap Fees
            SQRT_PRICE_1_1 // Initial Sqrt(P) value = 1
        );
    }

    // to run a specific test: forge test --match-path test/DexProfitWars.t.sol --match-test test_addLiquidityAndSwap -vvv

    function test_addLiquidityAndSwap() public {
        uint256 balanceBefore = hook.balanceOf(address(this));

        // set user address in hook data
        bytes memory hookData = abi.encode(address(this));

        uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(-60);
        uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(60);

        console.log("In the Test!!!");

        // uint256 ethToAdd = 0.1 ether;
        // uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceAtTickLower, SQRT_PRICE_1_1, ethToAdd);

        // uint256 tokenToAdd =
        //     LiquidityAmounts.getAmount1ForLiquidity(sqrtPriceAtTickLower, SQRT_PRICE_1_1, liquidityDelta);

        // modifyLiquidityRouter.modifyLiquidity{value: ethToAdd}(
        //     key,
        //     IPoolManager.ModifyLiquidityParams({
        //         tickLower: -60,
        //         tickUpper: 60,
        //         liquidityDelta: int256(uint256(liquidityDelta)),
        //         salt: bytes32(0)
        //     }),
        //     hookData
        // );

        // uint256 balanceAfterAddLiquidity = hook.balanceOf(address(this));

        // assertApproxEqAbs(
        //     balanceAfterAddLiquidity - balanceBefore,
        //     0.1 ether,
        //     0.001 ether // error margin for precision loss
        // );

        // // Now we swap
        // // We will swap 0.001 ether for tokens
        // // We should get 20% of 0.001 * 10**18 points
        // // = 2 * 10**14
        // swapRouter.swap{value: 0.001 ether}(
        //     key,
        //     IPoolManager.SwapParams({
        //         zeroForOne: true,
        //         amountSpecified: -0.001 ether, // Exact input for output swap
        //         sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        //     }),
        //     PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
        //     hookData
        // );

        // uint256 balanceAfterSwap = hook.balanceOf(address(this));

        // assertEq(balanceAfterSwap - balanceAfterAddLiquidity, 2 * 10 ** 14);
    }

    // Test Profit Calculation and Gas Costs
    function test_calculateSwapPnL() public {}
    function test_abd1() public {} // Verify gas costs are correctly subtracted from profits
    function test_abd2() public {} // Test the 2% minimum profit threshold
    function test_abd3() public {} // Test negative profit scenarios

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
