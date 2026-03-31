# `AlchemistAllocator` Deallocation Walkthroughs

This note documents the practical caller rules for every deallocation entrypoint on `AlchemistAllocator`:

1. `deallocate()`
2. `deallocateWithSwap()`
3. `deallocateWithUnwrapAndSwap()`

## Shared Rules

1. `amount` is always the vault asset amount you want back from the strategy.
   For the ETH strategies in this repo, that means the requested `WETH` out.

2. The allocator only wraps parameters and forwards the request to the vault.
   The real path taken after that depends on the strategy and the `ActionType` encoded into the allocator call.

3. `deallocate()` should only be used when the strategy supports a direct unwind into the vault asset without DEX calldata.
   Example: a strategy that can redeem or withdraw back into `WETH` directly.

4. `deallocateWithSwap()` should only be used when the strategy can sell its oracle token directly into the vault asset.
   Example: `WstethStrategy` can sell `wstETH -> WETH` in one swap.

5. `deallocateWithUnwrapAndSwap()` should be used when the held position token is not the same token that must be sold to the DEX.
   Example: `SFraxETHStrategy` holds `sfrxETH`, unwraps to `frxETH`, then sells `frxETH -> WETH`.

6. For any swap-based deallocation, `txData` must be a 0x allowance-holder quote built for the strategy address as the taker.
   The strategy approves the allowance holder and then executes `allowanceHolder.call(txData)`.

## `deallocate()`

### What the caller provides

- `adapter`
- `amount`

### What the allocator encodes

- `action = IMYTStrategy.ActionType.direct`
- no swap calldata
- no intermediate output requirement

### End-to-end flow

1. `AlchemistAllocator.deallocate(adapter, amount)`
2. `vault.deallocate(adapter, data, amount)`
3. `MYTStrategy.deallocate(...)`
4. Strategy handles the direct path in `_deallocate(uint256 amount)`
5. Strategy approves the vault asset back to the vault
6. The vault pulls the asset

### Practical rule

Use this only when the strategy itself can unwind back into the vault asset with no swap quote.

## `deallocateWithSwap()`

### What the caller provides

- `adapter`
- `amount`
- `txData`

### What the allocator encodes

- `action = IMYTStrategy.ActionType.swap`
- `swapParams.txData = txData`
- `swapParams.minIntermediateOut = 0`

### End-to-end flow

1. `AlchemistAllocator.deallocateWithSwap(adapter, amount, txData)`
2. `vault.deallocate(adapter, data, amount)`
3. `MYTStrategy.deallocate(...)`
4. `OraclePricedSwapStrategy._deallocateViaOracleTokenSwap(...)`
5. Strategy prepares how much oracle token can be sold
6. Strategy executes one swap from oracle token into the vault asset
7. Strategy approves the vault asset back to the vault
8. The vault pulls the asset

### Practical rules

1. `txData` must describe the oracle token swap.
   For `WstethStrategy`, that means `wstETH -> WETH`.

2. This path only works when the token the strategy sells to the DEX is the same token used by the strategy's oracle math.

3. Do not use this path for `SFraxETHStrategy`.
   `SFraxETHStrategy` intentionally rejects the plain swap route so callers do not accidentally skip the unwrap step.

## `deallocateWithUnwrapAndSwap()`

### What the caller provides

- `adapter`
- `amount`
- `txData`
- `minIntermediateOut`

### What the allocator encodes

- `action = IMYTStrategy.ActionType.unwrapAndSwap`
- `swapParams.txData = txData`
- `swapParams.minIntermediateOut = minIntermediateOut`

### End-to-end flow

For `SFraxETHStrategy`, the call path is:

1. `AlchemistAllocator.deallocateWithUnwrapAndSwap(adapter, amount, txData, minIntermediateOut)`
2. `vault.deallocate(adapter, data, amount)`
3. `MYTStrategy.deallocate(...)`
4. `OraclePricedSwapStrategy._deallocateViaUnwrapAndSwap(...)`
5. `SFraxETHStrategy._prepareIntermediateForSwap(maxOracleTokenIn, minIntermediateOut)`
6. `sfrxETH.withdraw(minIntermediateOut, strategy, strategy)`
7. `dexSwap(WETH, frxETH, minIntermediateOut, shortfall, txData)`
8. The strategy approves `WETH` back to the vault and the vault pulls it

### Practical rules

1. `txData` must describe the intermediate token swap, not the held position token swap.
   For `SFraxETHStrategy`, the swap is `frxETH -> WETH`, not `sfrxETH -> WETH`.

2. `minIntermediateOut` should match the quote `sellAmount`.
   For `SFraxETHStrategy`, this is the exact `frxETH` amount the strategy must unwrap before it calls 0x.

3. `minIntermediateOut` must be fundable by the strategy's oracle-token amount after oracle and slippage checks.
   For `SFraxETHStrategy`, the oracle prices `frxETH`, and the strategy converts `sfrxETH` shares into `frxETH` via ERC-4626 math before swapping.

### Example scenario

Assume:

- The vault wants `4 WETH` back
- The strategy already holds `10 sfrxETH`
- The oracle prices `1 frxETH = 1 ETH`
- Strategy slippage is `1%`
- A 0x quote says selling `4 frxETH` returns at least `4 WETH`

The caller should prepare:

- `adapter = address(sfraxEthStrategy)`
- `amount = 4e18`
- `minIntermediateOut = 4e18`
- `txData = 0x allowance-holder quote for frxETH -> WETH with taker = address(sfraxEthStrategy)`

The strategy then:

1. Computes the `WETH` shortfall that must be covered.
2. Converts that shortfall into a maximum permitted `frxETH` input using the oracle and slippage math.
3. Calls `sfrxETH.withdraw(4e18, address(this), address(this))` to unwrap exactly `4 frxETH`.
4. Executes the DEX swap from `4 frxETH` into `WETH`.
5. Approves `4 WETH` to the vault so the vault can pull the assets.

If the quote requires more intermediate output than the oracle-priced position can support, the transaction reverts instead of partially deallocating.
