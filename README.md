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
35 tests passed, 0 failed, 1 skipped   (the offline test runs only with OFFLINE_RPC set)
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

## Paths covered

| Path | Where | What it proves |
| --- | --- | --- |
| Contract wallets | `test/PrivateTradeSettlement.t.sol` | The protocol invariant, against a real settlement |
| appData-declared bundles | `test/PrivateTradeAppData.t.sol` | An order declares its bundle in appData; the official `CowWrapperHelpers` encodes the chain |
| Driver wire format | `test/PrivateTradeDriverFormat.t.sol` | The bytes the driver actually produces, including the appended auction id |
| EOA -> CoW Shed | `test/PrivateTradeShed.t.sol` | Real `COWShedFactory` + `COWShedForComposableCoW`, owner-signed bundles, relayed by anyone |
| Offline chain | `test/offline/PrivateTradeOffline.t.sol` | The real settlement, shed factory, ComposableCoW and tokens on `bleu/cow-offline-mode` |

`./scripts/offline-e2e.sh` runs the last one; see [docs/OFFLINE.md](docs/OFFLINE.md).

## What is real in these tests

| Real | Stubbed |
| --- | --- |
| `GPv2Settlement`, `GPv2VaultRelayer`, `GPv2AllowListAuthentication` (unmodified, `cowprotocol/contracts@main`) | In unit tests the vault is an address: with `BALANCE_ERC20` on both sides the settlement never calls it |
| `CowWrapper` and `CowWrapperHelpers`, vendored verbatim from upstream | Bundle allowlisting is a local `addSolver` call, not DAO governance |
| `ComposableCoW` + the ERC-1271 forwarding path | |
| `COWShedFactory`, `COWShedProxy`, `COWShedForComposableCoW` v2.1.0 | |
| Token balances really move; the settlement keeps nothing | |
| The offline path uses the real chain, real addresses and real tokens | No DAO allowlisting, no audit |

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
| `test_settlesThroughAppDataDeclaredBundle` | Order declares its bundle in appData; driver-style parse, then settle |
| `test_tamperedBundleDataInDocumentReverts` | Swapping the bundle data is caught by the offer commitment |
| `test_mismatchedAppDataReverts` | Both orders must commit to the same appData document |
| `test_helpersRejectMalformedBundleData` | Pre-flight validation via upstream `CowWrapperHelpers` |
| `test_helpersRejectUnauthenticatedBundle` | Only allowlisted bundles can be declared |
| `test_settlesWithAppendedAuctionId` | The driver appends the auction id; the wrapper tolerates it |
| `test_settlesWithShedOwnedOrders` | Two EOAs, two Sheds, one settlement |
| `test_orderMustBeAuthorisedByTheShed` | The Shed must authorise the order; approval alone is not enough |
| `test_bundleSignatureIsBoundToTheShed` | A bundle cannot be replayed onto another owner's Shed |
| `test_bundleNonceCannotBeReplayed` | Nonce replay is rejected |

The suite is mutation-checked: removing the `activeOfferId` check, the last-bundle check, or the
`allowedTaker` check makes specific tests fail.

## Layout

```
src/PrivateTradeWrapper.sol         the Atomic Bundle: validates the pair, publishes the terms
src/PrivateTradeOrder.sol           ComposableCoW handler: validity depends on the wrapper
src/libraries/PrivateTradeLib.sol   derives the two orders, checks exact reciprocity
src/interfaces/IPrivateTrade.sol    offer/terms types, errors, interfaces
src/libraries/PrivateTradeAppData.sol  builds the appData document that declares the bundle
src/vendor/CowWrapper.sol           upstream CoW Atomic Bundle base, vendored verbatim
src/vendor/CowWrapperHelpers.sol    upstream chain validation/encoding helper, vendored verbatim
test/PrivateTradeSettlement.t.sol   end-to-end behaviour against a real settlement
test/utils/                         harness: contract wallet, ERC20, flags encoder, base fixture
```

## Not built yet

1. **A sub-solver.** A private trade needs a solver that submits the two orders as fulfillments with
   no interactions. The built-in baseline solver routes through AMM liquidity and adds interactions,
   which this wrapper rejects by design. A minimal solver is the next artifact.
2. **Order submission.** Nothing here posts an order to the orderbook. The appData document is built
   and validated, but the `PUT /api/v1/app_data/{hash}` + `POST /api/v1/orders` sequence lives in the
   offline repo's scripts, not here.
3. **Atomic funding inside the settlement.** Approvals and order authorisation are atomic with the
   trade only if the signed bundles are carried in the bundle chain. Funding is currently a separate
   transfer into the Shed. The Shed is owner-controlled, so nothing is stranded, but it is two
   transactions instead of one.
4. **Allowlisting and audit.** Production bundles must pass a security audit and be approved by CoW
   DAO. Neither the audit nor the governance step is in scope here.
5. **Non-ERC20 assets.** NFTs, game items, partial fills.

Pinned to `cowprotocol/contracts@main`, `cowprotocol/composable-cow@main`, `cowdao-grants/cow-shed@main`,
and the upstream `CowWrapper.sol`.
