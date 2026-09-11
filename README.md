# Private Trades

Two parties who already agreed on a trade settle it atomically through CoW Protocol, without an
order book, without solver competition, and without either side being able to execute the other's
half.

This is the PoC from the "second Private Trades protocol" design: neither party's order is valid
unless **both** halves of that exact pair are present in the same settlement.

```bash
forge test
```

```
Ran 1 test suite: 15 tests passed, 0 failed, 0 skipped
```

## The guarantee

Alice signs an offer, Bob accepts it. Both orders are contract orders (EIP-1271) whose validity
depends on `PrivateTradeWrapper`:

```
Alice orders --+                                  +-- Bob order
               |                                  |
               v                                  v
        PrivateTradeWrapper.wrappedSettle(tokens, prices, trades, [], terms)
               |
               |  validates: exactly 2 tokens, 2 trades, 0 interactions
               |             both orders are exact mirrors at the declared prices
               |             owners in the EIP-1271 signatures are the two expected parties
               |             taker is not the maker, and respects allowedTaker
               |
               |  publishes: activeOfferId, activeTaker
               v
        GPv2Settlement.settle(...)
               |
               |  EIP-1271(Alice) -> ComposableCoW -> PrivateTradeOrder.verify
               |  EIP-1271(Bob)   -> ComposableCoW -> PrivateTradeOrder.verify
               |      both read the published terms; both must match
               v
        both legs transfer, or nothing does
```

A leaked order is worthless: outside the wrapper's window `activeOfferId` is zero, so
`verify` reverts inside GPv2's own signature validation. A leaked maker order also cannot be
re-paired with a different counterparty, because `allowedTaker` is inside the `offerId`
commitment the maker actually authorised.

## What is real in these tests

| Real | Stubbed |
| --- | --- |
| `GPv2Settlement`, `GPv2VaultRelayer`, `GPv2AllowListAuthentication` (unmodified, from `feat/wrapper`) | The vault is an address: with `BALANCE_ERC20` on both sides the settlement never calls it |
| `ComposableCoW` + the ERC-1271 forwarding path | `TestPrivateWallet` stands in for a CoW Shed |
| Token balances really move; the settlement keeps nothing | No UI, no driver, no BYOS sub-solver yet |

## Test matrix

| Test | Property |
| --- | --- |
| `test_settlesExactPairAtomically` | Both legs settle; balances move; settlement keeps nothing; context cleared |
| `test_openOfferIsAcceptedByAnyWallet` | `allowedTaker == 0` means anyone holding the link can accept |
| `test_directSettleMakerAloneReverts` | Maker order alone is unusable, even by an allowlisted solver |
| `test_directSettleTakerAloneReverts` | Taker order alone is unusable |
| `test_directSettleCompletePairReverts` | The full pair is unusable without the wrapper |
| `test_offerCommitmentBlocksRepairingWithAnotherCounterparty` | A leaked maker order cannot be re-paired with someone else |
| `test_restrictedOfferRejectsDifferentTaker` | On-chain counterparty restriction |
| `test_replayReverts` | A settled pair cannot be replayed |
| `test_rejectsNonReciprocalClearingPrices` | No price slippage between the two legs |
| `test_rejectsDuplicateMakerOrder` | Order index matters; shapes are exact |
| `test_rejectsSingleTrade` | Exactly two trades |
| `test_rejectsAnyInteraction` | No pre/intra/post interactions |
| `test_rejectsNonSolverCaller` | Only allowlisted solvers reach the wrapper |
| `test_verifyRejectsNonSettlementCaller` | The handler only trusts the settlement |
| `test_tradeFlagsDecodeAsExactSellOrder` | Local flags encoder agrees with the settlement's decoder |

The suite is mutation-checked: removing the `activeOfferId` check or the `allowedTaker` check makes
5 of these tests fail.

## Layout

```
src/PrivateTradeWrapper.sol         authorised settlement entry point; validates the pair
src/PrivateTradeOrder.sol           ComposableCoW handler; validity depends on the wrapper
src/libraries/PrivateTradeLib.sol   derives the two orders, checks exact reciprocity
src/interfaces/IPrivateTrade.sol    offer/terms types, errors, interfaces
test/PrivateTradeSettlement.t.sol   end-to-end behaviour against a real settlement
test/utils/                         harness: contract wallet, ERC20, flags encoder, base fixture
```

## Not built yet

1. **CoW Shed wiring.** Today both wallets are pre-funded and orders are authorised directly. The
   real flow puts funding, `approve`, and `ComposableCoW.create` into owner-signed Shed hook
   bundles that the wrapper executes in the same transaction, so nothing is stranded if the
   counterparty never shows up.
2. **BYOS sub-solver.** A sub-solver that pairs a private offer with an acceptance and submits
   `fulfillment(taker) + JIT(maker)` through the bonded solver.
3. **Driver integration.** Whether the driver accepts a pair of contract orders with no auction.

Dependencies are pinned to `cowprotocol/contracts@feat/wrapper` (the branch that adds
`GPv2Wrapper`), `cowprotocol/composable-cow@main`, and `cowdao-grants/cow-shed@main`.
