# DexProfitWars

DexProfitWars is a Uniswap V4 hook that turns trading into a competitive leaderboard for top profit-makers. It unlocks monetization opportunities by enabling fee-based copy trading, drives trading spikes, and generates airdrop buzz through sponsor-funded rewards for leading traders.

The hook tracks trader performance using USD-based profit calculations. It converts trade values using on-chain oracle price feeds for ETH, token0, token1, and gas prices to ensure fair, cross-token comparisons. It maintains a gas-efficient leaderboard of the top three traderds in 2‑day contests, laying the groundwork for future reward distribution and advanced applications.

## Features

- **Trading Contests:**
  Run periodic 2‑day contests where only trades achieving over a 2% profit threshold (in basis points) qualify for leaderboard ranking.

- **USD-Based Profit Calculation:**
  Converts trade amounts to USD using real-time oracle data for ETH, token0, token1, and gas prices. This standardization allows fair comparisons across different token pairs.

- **Leaderboard Management:**
  Maintains a fixed-size array of 3 winners per contest. The leaderboard is updated by:
  - Checking if a trader already has an entry and updating it only if the new trade is superior.
  - Inserting a new entry if there is an available slot or if the new trade outperforms the worst existing entry.
  - Resolving ties by comparing profit percentages first, then by earlier trade timestamps, and finally by higher trade volume in USD.

- **Oracle Integration and Caching:**
  Fetches current pricing data from Chainlink oracles, with updates at defined intervals to balance data freshness and gas efficiency. The fetched data is cached to minimize repetitive on-chain computations.

- **Future Enhancements:**
  Designed to evolve with features like reward distribution for winners, support for airdrops, memecoin launches, and copy-trading platforms where users can opt in to replicate high-performing trades for a fee.

- **Decimal Assumptions:**
  The contract currently assumes all tokens have 18 decimals for simplicity in conversion. Future iterations will accommodate tokens with varying decimal precisions.

## Project Structure

This repository is a Forge project and includes the following key directories:
- **`src/`**: Contains the Solidity smart contract source code.
- **`test/`**: Contains the test suite for the smart contract.

## Prerequisites

Ensure you have [Foundry](https://github.com/foundry-rs/foundry) installed. Foundry is a fast and modular toolkit for Ethereum development.

To install Foundry, run:
```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

## Building the Project

Compile the contracts using:
```
forge build
```

## Running Tests

Execute the test suite with:
```
forge test
```

## Usage

- **Contest Control:**
  The contract owner can start and stop trading contests. Each contest lasts for 2 days, during which eligible trades update the leaderboard.

- **Leaderboard Updates:**
  When a trade qualifies (exceeding the minimum profit threshold), the leaderboard is updated by checking for existing trader entries, inserting new ones if space is available, or replacing the worst entry if the new trade is superior. Ties are resolved by comparing profit percentage first, then trade timestamp, and finally trade volume.

- **Oracle Price Updates:**
  Oracles fetch real-time prices for ETH, token0, token1, and gas. The data is cached and refreshed at a set interval to maintain efficiency and accuracy in profit calculations.

## Future Enhancements

- **Reward Distribution:**
  Future updates will implement a mechanism where winners can earn token rewards, incentivizing participation.

- **Advanced Applications:**
  The leaderboard system can be extended to applications such as:
  - **Airdrops & Memecoin Launches:** Rewarding top traders or generating buzz around new tokens.
  - **Copy-Trading Platforms:** Allowing users to automatically replicate high-performing trades for a fee.

- **Decimal Flexibility:**
  Future iterations will accommodate tokens with varying decimal places to support a broader range of assets accurately.

## License

This project is licensed under the **UNLICENSED** License.

## Acknowledgements

- Built using the Foundry toolkit for Ethereum development.
- Inspired by the need for gamified trading and equitable performance evaluation across token pairs :heart:
