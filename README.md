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
39 tests passed, 0 failed, 2 skipped
# plus, against real deployments:
FORK_RPC=https://ethereum-rpc.publicnode.com forge test --match-path 'test/fork/*'      # 3 passed
./scripts/offline-e2e.sh                                                                 # 3 passed
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

## The submitter

`PrivateTradeSubmitter` is a deployed, stateless contract that relays both Shed hook bundles and
then calls `wrappedSettle`. Deploy it once, allowlist it once, and after that **anyone** can execute
a private trade that both parties already signed: the link service, either counterparty, or a bot.

It holds no funds, keeps no state, and owns no keys, so there is no account to compromise. It is
also deliberately narrow — the only calls it can make are `COWShedFactory.executeHooks` (owner-signed
bundles) and `PrivateTradeWrapper.wrappedSettle` (on-chain validated pair). It cannot call
`GPv2Settlement.settle` directly, so allowlisting it grants less power than allowlisting a solver.

Retrying is safe: a bundle whose nonce is already consumed is skipped, so a resubmission only
re-fails if the pair itself already settled.

`PrivateTradeBuilder` is the pure library behind it, and the single place the payload is
constructed: both orders, both EIP-1271 signatures, the clearing prices, the settlement calldata and
the bundle chain. It needs no private key, because order authorisation comes from the Shed-owned
conditional orders rather than from an ECDSA signature.

## Paths covered

| Path | Where | What it proves |
| --- | --- | --- |
| Contract wallets | `test/PrivateTradeSettlement.t.sol` | The protocol invariant, against a real settlement |
| appData-declared bundles | `test/PrivateTradeAppData.t.sol` | An order declares its bundle in appData; the official `CowWrapperHelpers` encodes the chain |
| Driver wire format | `test/PrivateTradeDriverFormat.t.sol` | The bytes the driver actually produces, including the appended auction id |
| EOA -> CoW Shed | `test/PrivateTradeShed.t.sol` | Real `COWShedFactory` + `COWShedForComposableCoW`, owner-signed bundles, relayed by anyone |
| Offline chain | `test/offline/PrivateTradeOffline.t.sol` | The real settlement, shed factory, ComposableCoW and tokens on `bleu/cow-offline-mode` |
| Submitter | `src/PrivateTradeSubmitter.sol`, driven by both e2e suites | A deployed, allowlisted, keyless relay executed by a caller that is not a solver |
| Payload builder | `test/PrivateTradeBuilder.t.sol` | The production builder agrees with the fixtures the suites are written against |

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

1. **The link service.** Holding the offer, generating the link, collecting the acceptance, then
   handing both halves to the submitter. The on-chain half is done; this is the product half.
2. **Atomic funding inside the settlement.** Approvals and order authorisation are atomic with the
   trade only if the signed bundles travel in the bundle chain. Funding is currently a separate
   transfer into the Shed. The Shed is owner-controlled, so nothing is stranded, but it is two
   transactions instead of one.
3. **Allowlisting and audit.** Production bundles must pass a security audit and be approved by CoW
   DAO, and the submitter must be allowlisted. Neither governance step is in scope here.
4. **Non-ERC20 assets.** NFTs, game items, partial fills.

Pinned to `cowprotocol/contracts@main`, `cowprotocol/composable-cow@main`, `cowdao-grants/cow-shed@main`,
and the upstream `CowWrapper.sol`.
