# Private Trades

Two parties who already agreed on a trade settle it atomically through CoW Protocol, without an
order book, without solver competition, and without either side being able to execute the other's
half.

This is a PoC of the Private Trades design on top of CoW **Atomic Bundles** (the framework formerly
called Generalized Wrappers). Neither party's order is valid unless **both** halves of that exact
pair are present in the same settlement.

```bash
forge test
```

```
Ran 1 test suite: 21 tests passed, 0 failed, 0 skipped
```

## The guarantee

Alice creates an offer, Bob accepts it. Both orders are contract orders (EIP-1271) whose validity
depends on `PrivateTradeWrapper`:

```
solver
  |
  |  wrappedSettle(settleData, chainedWrapperData)      <- Atomic Bundle entry point
  v
PrivateTradeWrapper
  |
  |  requires: this is the LAST bundle in the chain
  |  validates settleData: exactly 2 tokens, 2 trades, 0 interactions
  |                         both orders are exact mirrors at the declared prices
  |                         owners in the EIP-1271 signatures are the two expected parties
  |                         taker is not the maker and respects allowedTaker
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

A leaked order is worthless: outside the wrapper's window `activeOfferId` is zero, so `verify`
reverts inside GPv2's own signature validation. A leaked maker order also cannot be re-paired with a
different counterparty, because `allowedTaker` is inside the `offerId` commitment the maker actually
authorised.

## Where this sits in the Atomic Bundle framework

| Bundle requirement | How this repo meets it |
| --- | --- |
| Inherit `CowWrapper` | `PrivateTradeWrapper is CowWrapper`; the base is vendored verbatim in `src/vendor/CowWrapper.sol` |
| Implement `_wrap` | Validates the forwarded settlement, publishes terms, calls `_next` |
| Implement `validateWrapperData` | Pure structural checks; deterministic, no `block.timestamp` |
| `name()` | `PrivateTradeWrapper` |
| Eventually call `settle` | `_next(settleData, "")` when the chain is exhausted |
| Allowlisted in the authenticator | The wrapper must be an authenticated caller of `GPv2Settlement.settle` |
| Order carries the bundle in appData | `wrappers[].data = abi.encode(offerId, terms)` |

Two consequences of the framework that this design takes seriously:

1. **`settleData` does not survive the chain.** CoW's own documentation warns that an intermediate
   bundle can rewrite the settlement calldata, so validating it is only meaningful if nothing runs
   between that validation and `settle`. The wrapper therefore reverts unless it is the last bundle
   (`remainingWrapperData.length == 0`). This is the difference between a check and a guarantee.
2. **`wrapperData` is untrusted.** It arrives through the order's appData, which the driver
   aggregates. Nothing in it is trusted: the terms are re-checked against the orders, and the orders
   re-check the published terms against the offer each party actually authorised in
   `ComposableCoW`.

## What is real in these tests

| Real | Stubbed |
| --- | --- |
| `GPv2Settlement`, `GPv2VaultRelayer`, `GPv2AllowListAuthentication` (unmodified, `cowprotocol/contracts@main`) | The vault is an address: with `BALANCE_ERC20` on both sides the settlement never calls it |
| `CowWrapper` from the upstream all-in-one file, the real `wrappedSettle` entry point and chained encoding | `TestPrivateWallet` stands in for a CoW Shed |
| `ComposableCoW` + the ERC-1271 forwarding path | No UI, no driver, no BYOS sub-solver yet |
| Token balances really move; the settlement keeps nothing | Bundle allowlisting is a local allowlist call, not DAO governance |

## Test matrix

| Test | Property |
| --- | --- |
| `test_settlesExactPairAtomically` | Both legs settle; balances move; settlement keeps nothing; context cleared; selector returned |
| `test_openOfferIsAcceptedByAnyWallet` | `allowedTaker == 0` means anyone holding the link can accept |
| `test_directSettleMakerAloneReverts` | Maker order alone is unusable, even by an allowlisted solver |
| `test_directSettleTakerAloneReverts` | Taker order alone is unusable |
| `test_directSettleCompletePairReverts` | The full pair is unusable without the wrapper |
| `test_offerCommitmentBlocksRepairingWithAnotherCounterparty` | A leaked maker order cannot be re-paired with someone else |
| `test_restrictedOfferRejectsDifferentTaker` | On-chain counterparty restriction |
| `test_replayReverts` | A settled pair cannot be replayed |
| `test_rejectsBeingAnIntermediateBundle` | Refuses to run if another bundle sits between it and the settlement |
| `test_rejectsNonReciprocalClearingPrices` | No price slippage between the two legs |
| `test_rejectsDuplicateMakerOrder` | Order index matters; shapes are exact |
| `test_rejectsSingleTrade` | Exactly two trades |
| `test_rejectsAnyInteraction` | No pre/intra/post interactions |
| `test_rejectsNonSettleCalldata` | `settleData` must be a `settle` call |
| `test_rejectsNonSolverCaller` | Only authenticated solvers reach a bundle |
| `test_validateWrapperData*` | The pre-flight check hooks (`CowWrapperHelpers`) rely on |
| `test_verifyRejectsNonSettlementCaller` | The handler only trusts the settlement |
| `test_tradeFlagsDecodeAsExactSellOrder` | Local flags decoding agrees with the settlement |
| `test_nameIsSet` | Bundle metadata |

The suite is mutation-checked: removing the `activeOfferId` check, the last-bundle check, or the
`allowedTaker` check makes specific tests fail.

## Layout

```
src/PrivateTradeWrapper.sol         the Atomic Bundle: validates the pair, publishes the terms
src/PrivateTradeOrder.sol           ComposableCoW handler: validity depends on the wrapper
src/libraries/PrivateTradeLib.sol   derives the two orders, checks exact reciprocity
src/interfaces/IPrivateTrade.sol    offer/terms types, errors, interfaces
src/vendor/CowWrapper.sol           upstream CoW Atomic Bundle base, vendored verbatim
test/PrivateTradeSettlement.t.sol   end-to-end behaviour against a real settlement
test/utils/                         harness: contract wallet, ERC20, flags encoder, base fixture
```

## Not built yet

1. **The appData frontend path.** `wrappers[]` is built here in tests. A real integration encodes it
   into the order's appData and validates it with `CowWrapperHelpers.verifyAndBuildWrapperData`.
2. **CoW Shed wiring.** Today both wallets are pre-funded and orders are authorised directly. The
   real flow puts funding, `approve`, and `ComposableCoW.create` into owner-signed Shed hook bundles
   the wrapper executes in the same transaction, so nothing is stranded if the counterparty never
   shows up.
3. **BYOS sub-solver.** A sub-solver that pairs a private offer with an acceptance and submits
   `fulfillment(taker) + JIT(maker)` through the bonded solver.
4. **Allowlisting and audit.** Production bundles must pass a security audit and be approved by CoW
   DAO. Neither the audit nor the governance step is in scope here.

Pinned to `cowprotocol/contracts@main`, `cowprotocol/composable-cow@main`, `cowdao-grants/cow-shed@main`,
and the upstream `CowWrapper.sol`.
