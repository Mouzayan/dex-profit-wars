## DexProfitWars

**DexProfitWars** is a gamified trading enhancement hook that rewards traders with bonus tokens funded by sponsors. Sponsors (protocols, DAOs, or projects) deposit tokens into bonus pools in the hook and define custom reward parameters for the trading pair.
When traders execute profitable swaps that meet the sponsor's criteria, they automatically receive a bonus of up to 10% on their traded amounts, drawn from the sponsor's bonus pool. Sponsors customize their reward mechanics by setting minimum trade sizes, specific trading windows, and variable bonus rates based on profit margins.

For example, a sponsor might offer a 5% bonus for trades with 1-3% profit margins, scaling up to 10% for trades exceeding 5% profit.
This creates a fun, tournament-like atmosphere around everyday trading while providing sponsors with a way to incentivize liquidity and engagement with their token pairs.
The mechanism could play into memecoin launches / airdrops etc..

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
