# Bundler3

[`Bundler3`](./src/Bundler3.sol) allows accounts to batch-execute a sequence of arbitrary calls atomically.
It carries specific features to be able to perform actions that require authorizations, and handle callbacks.

## Structure

### Bundler3

<img width="724" alt="image" src="https://github.com/user-attachments/assets/cc7c304a-9778-441d-b863-c158e5de21ee" />

Bundler3's entrypoint is `multicall(Call[] calldata bundle)`.
A bundle is a sequence of calls where each call is specified by:
<a name="bundle-call-fields"></a>

- `to`, an address to call;
- `data`, some calldata to pass to the call;
- `value`, an amount of native currency to send with the call;
- `skipRevert`, a boolean indicating whether the multicall should revert if the call failed.
- `callbackHash`, hash of the argument to the expected `reenter` (0 if no reentrance).

Bundler3 also implements two specific features, their usage is described in the [Adapters subsection](#adapters):

- the initial caller is transiently stored as `initiator` during the multicall;
- the last non-returned called address can re-enter Bundler3 using `reenter(Call[] calldata bundle)`, but the argument to the `reenter` call is specified in the bundle.

### Adapters

Bundler3 can call either directly protocols, or wrappers of protocols (called "adapters").
Wrappers can be useful to perform “atomic checks" (e.g. slippage checks), manage slippage (e.g. in migrations) or perform actions that require authorizations.

In order to be safely authorized by users, adapters can restrict some functions calls depending on the value of the bundle's initiator, stored in Bundler3.
For instance, an adapter that needs to hold some token approvals should call `token.transferFrom` only with `from` being the initiator.

Since these functions can typically move user funds, only Bundler3 should be allowed to call them.
If an adapter gets called back (e.g. during a flashloan) and needs to perform more actions, it can use other adapters by calling Bundler3's `reenter(Call[] calldata bundle)` function.

## Adapters List

All adapters inherit from [`CoreAdapter`](./src/adapters/CoreAdapter.sol), which provides essential features such as accessing the current initiator address.

### [`GeneralAdapter1`](./src/adapters/GeneralAdapter1.sol)

Contains the following actions:

- ERC20 transfers.
- Native token (e.g. WETH) transfers, wrap & unwrap.
- ERC4626 mint, deposit, withdraw & redeem.
- Morpho interactions.
- TransferFrom using Permit2.

### [`ERC20WrapperAdapter`](./src/adapters/ERC20WrapperAdapter.sol)

Contains the following actions:

- ERC20 wrap & unwrap.

### [`EthereumGeneralAdapter1`](./src/adapters/EthereumGeneralAdapter1.sol)

Contains the following actions:

- Actions of `GeneralAdapter1`.
- Morpho token wrapper deposit and withdrawal.
- stETH staking.
- wstETH wrap & unwrap.

### [`ParaswapAdapter`](./src/adapters/ParaswapAdapter.sol)

Contains the following actions, all using the paraswap aggregator:

- Sell a given amount or the balance.
- Buy a given amount.
- Buy a what's needed to fully repay on a given Morpho Market.

### Migration adapters

For [Aave V2](./src/adapters/migration/AaveV2MigrationAdapter.sol), [Aave V3](./src/adapters/migration/AaveV3MigrationAdapter.sol), [Compound V2](./src/adapters/migration/CompoundV2MigrationAdapter.sol), [Compound V3](./src/adapters/migration/CompoundV3MigrationAdapter.sol), and [Morpho Aave V3 Optimizer](./src/adapters/migration/AaveV3OptimizerMigrationAdapter.sol).

## Differences with [Bundler v2](https://github.com/morpho-org/morpho-blue-bundlers)

- Make use of transient storage.
- Bundler3 is now a call dispatcher that does not require any approval.
  Because call-dispatch and approvals are now separated, it is possible to add adapters over time without additional risk to users of existing adapters.
- All generic features are now in `GeneralAdapter1`, instead of being in separate files that are then all inherited by a single contract.
- All Ethereum related features are in the `EthereumAdapter1` which inherits from `GeneralAdapter1`.
- The `1` after `Adapter` is not a version number: when new features are development we will deploy additional adapters, for instance `GeneralAdapter2`.
  Existing adapters will still be used.
- Many adjustments such as:
  - A value `amount` is only taken to be the current balance (when it makes sense) if equal to `uint.max`
  - Slippage checks are done with a price argument instead of a limit amount.
  - When `shares` represents a supply or borrow position, `shares == uint.max` sets `shares` to the position's total value.
  - There are receiver arguments in all functions that give tokens to the adapter so the adapter can pass along those tokens.
  - ERC20 unwrap always transfers to and from the initiator before unwrapping.
    This prevents unwrapping by non-whitelisted initiators.
- The [call fields](#bundle-call-fields) `skipRevert` (to skip failed actions) and `callbackHash` (to commit to callback contents) are new.

## Development

Run tests with `forge test --chain <chainid>` (chainid can be 1 or 8453, 1 by default).

## Audits

All audits are stored in the [audits](./audits/) folder.

## License

Source files are licensed under `GPL-2.0-or-later`, see [`LICENSE`](./LICENSE).

## Links

- [Deployments](https://docs.morpho.org/addresses/#bundlers)
- SDK: TBA.

# Mystic Leverage System

## Overview

The system enables leveraged trading on Mystic Protocol using flash loans and Maverick DEX for swaps. It allows users to open, close, and adjust leveraged positions in a single transaction.

## Core Components

### 1. MysticLeverageBundler.sol

- Main contract that orchestrates leveraged trading operations
- Key features:
  - Open leveraged positions using flash loans or iterative borrowing
  - Close leveraged positions
  - Update existing positions' leverage
  - Tracks user positions and total system exposure
  - Enforces safety limits (max leverage, price deviation checks)

### 2. MysticAdapter.sol

- Interface to Mystic Protocol (Aave V3 fork)
- Handles core lending operations:
  - Supply/withdraw collateral
  - Borrow/repay assets
  - Flash loan execution
  - Position management (collateral settings)
  - Price and liquidity queries
  - Account health monitoring

### 3. MaverickAdapter.sol

- Interface to Maverick DEX for token swaps
- Features:
  - Token swaps with slippage protection
  - Price quotes for swaps
  - Best pool selection based on liquidity
  - Gas-optimized swap execution

## Key Concepts

### Leverage Operations

1. **Opening Positions**:

   - User provides initial collateral
   - System borrows additional assets via flash loan
   - Swaps borrowed assets for more collateral
   - Repeats process to achieve target leverage

2. **Closing Positions**:

   - Repays borrowed assets
   - Withdraws collateral
   - Swaps remaining assets back to original token

3. **Updating Leverage**:
   - Adjusts position size to match new target leverage
   - Can increase or decrease exposure

### Safety Features

- Price deviation checks (5% max)
- Maximum leverage limits
- Health factor monitoring
- Slippage protection on swaps
- Position tracking and validation

## Scope

- src/calls/MysticLeverageBundler.sol
- src/adapters/MysticAdapter.sol
- src/adapters/MaverickAdapter.sol
