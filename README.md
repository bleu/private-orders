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

## Who submits

An Atomic Bundle needs an authenticated caller, and the wrapper itself must be allowlisted because it
calls `settle`. The natural answer is **BYOS** rather than a bespoke allowlisted contract: BYOS is
already a bonded, allowlisted solver, and BYOS's own integration guide states the point of it —
*"You do not need a CoW solver seat, an allowlist entry, or a relationship with CoW DAO. You need an
address, collateral in the Escrow, and the ability to sign EIP-712 messages."*

So a private-trade sub-solver is an ordinary key with escrow. The tests assert it holds **no**
allowlist entry.

| | Dedicated submitter contract | BYOS |
| --- | --- | --- |
| Allowlist entries | wrapper + submitter | wrapper only |
| Revert accountability | none | escrow debit, existing penalty framework |
| Fee path | none | BYOS's fee mechanism |
| Permissionless relay | yes, anyone | BYOS only (liveness, not safety) |
| New audited code | ~60 lines | none |

`PrivateTradeSubmitter` remains in the tree as an optional permissionless fallback for deployments
that do not want BYOS in the path. It costs one extra allowlist entry.

### The proposal

BYOS routes auction orderflow through a Trampoline sandbox under an invariant of *one order, one
trampoline call, one sub-solver*. A private trade breaks that shape — two orders, no external
liquidity, nothing for a Trampoline to do — so it needs its own proposal type, which BYOS's design
notes call a signed-schema change.

```
PrivateTradeProposal(address wrapper, bytes32 termsHash, uint256 validUntil)
domain: name "BYOS", version "0.2", chainId, verifyingContract = the wrapper
```

Three things worth stating:

- **The wrapper verifies the signature on-chain**, not just BYOS off-chain. That is the same job
  `interactionsHash` does for routing proposals: it stops the operator from running something other
  than what the sub-solver signed and then debiting escrow for the revert.
- **The commitment is to the pair** — `keccak256(abi.encode(offerId, taker, wrapper))` — and not to
  the settlement calldata. The proposal travels *inside* the orders' appData, and the calldata
  contains those orders, so hashing the calldata would be circular. The pair is sufficient: the
  wrapper derives exact amounts, both owners, both tokens and reciprocity from it, so no other valid
  execution of the same pair exists.
- **No nonce is enforced on-chain.** BYOS needs one because a routing proposal can be replayed inside
  a tradeless settlement. A private trade cannot be: both orders are fill-or-kill and the settlement
  marks them filled, so a replay already reverts with `GPv2: order filled`.

## The app

Two pages, and the whole flow between them:

```bash
./scripts/app-e2e.sh     # drives both pages in a real browser and checks the result
```

One page to offer a trade — describe it, get a link, sign, share. One page to accept it — open the
link, sign, settle, read the receipt. Neither party sends a transaction, and the proceeds arrive in
their own wallets.

## The link service

Turns an agreed trade into a shareable link and drives it to settlement:

```
./scripts/link-service-e2e.sh
```

Maker creates an offer and gets a link; the taker opens it, signs, accepts; the service relays both
hook bundles, hands the private half to the sub-solver, and posts the taker's order. Verified on the
offline stack, ending in a settled offer.

Funding is inside the signed bundle, and the allowance comes from an EIP-2612 (or DAI-style) permit
the relayer submits: **neither party sends a transaction.** Two signatures — the bundle and the permit
— fund the Shed, authorise the order, and let settlement take the sell tokens. Tokens without permit
fall back to one `approve`, which the service reports per side.

The service holds **no key that can move value** — it relays owner-signed bundles and posts an
ERC-1271 payload — and it **never re-derives the trade**: `script/LinkCompute.s.sol` *is*
`PrivateTradeBuilder`, so the service cannot drift from the on-chain rules. See
[docs/LINK-SERVICE.md](docs/LINK-SERVICE.md).

## Executing through the driver (JIT + fulfillment)

The maker's half never reaches the orderbook. The taker posts an order, and a sub-solver pairs the two
by injecting the maker's order as a JIT trade:

```
trades: [jit(maker), fulfillment(taker)]   wrappers: [the private trade wrapper]   interactions: []
```

The driver then encodes `wrappedSettle` itself, with the wrapper as the transaction target. Verified
on the offline stack — transaction
`0x3e179a9d2ff11a56ad5d0456f683f46501b3cdaf942183558c72e6eb24af1d10` succeeded, `to` the wrapper,
method `wrappedSettle(bytes,bytes)`, moving 100 DAI and 100 USDC between the two Sheds.

```bash
./scripts/private-trade-e2e.sh
```

`subsolver/private-trade-solver.mjs` is the sub-solver; [docs/JIT-PATH.md](docs/JIT-PATH.md) lists the
five things the driver requires that cost time to discover.

## Paths covered

| Path | Where | What it proves |
| --- | --- | --- |
| Contract wallets | `test/PrivateTradeSettlement.t.sol` | The protocol invariant, against a real settlement |
| appData-declared bundles | `test/PrivateTradeAppData.t.sol` | An order declares its bundle in appData; the official `CowWrapperHelpers` encodes the chain |
| Driver wire format | `test/PrivateTradeDriverFormat.t.sol` | The bytes the driver actually produces, including the appended auction id |
| EOA -> CoW Shed | `test/PrivateTradeShed.t.sol` | Real `COWShedFactory` + `COWShedForComposableCoW`, owner-signed bundles, relayed by anyone |
| Offline chain | `test/offline/PrivateTradeOffline.t.sol` | The real settlement, shed factory, ComposableCoW and tokens on `bleu/cow-offline-mode` |
| BYOS proposal | `src/libraries/PrivateTradeProposal.sol`, driven by both e2e suites | A sub-solver with no allowlist entry signs; the allowlisted submitter executes; the wrapper verifies on-chain |
| Submitter (fallback) | `src/PrivateTradeSubmitter.sol`, driven by both e2e suites | A deployed, allowlisted, keyless relay executed by a caller that is not a solver |
| Payload builder | `test/PrivateTradeBuilder.t.sol` | The production builder agrees with the fixtures the suites are written against |
| Driver, JIT + fulfillment | `scripts/private-trade-e2e.sh` | The driver encodes and submits `wrappedSettle`; the pair settles on the real stack |
| Link service | `scripts/link-service-e2e.sh` | Create → share → sign → accept → settle, driven through the service's HTTP API, with neither party sending a transaction |

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
| `test_byosProposalSubmissionOn*` | Sub-solver with no allowlist entry signs; wrapper verifies the proposal on-chain; trade settles |
| `test_byosProposalTamperingRejectedOn*` | A signature over a different pair does not execute this one |
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
2. **BYOS-side proposal support.** The proposal type and its on-chain verification exist here; BYOS
   needs a matching proposal kind and a submission path that is not driven by an auction.
3. **Atomic funding inside the settlement.** Approvals and order authorisation are atomic with the
   trade only if the signed bundles travel in the bundle chain. Funding is currently a separate
   transfer into the Shed. The Shed is owner-controlled, so nothing is stranded, but it is two
   transactions instead of one.
4. **Allowlisting and audit.** Production bundles must pass a security audit and be approved by CoW
   DAO, and the submitter must be allowlisted. Neither governance step is in scope here.
5. **Non-ERC20 assets.** NFTs, game items, partial fills.

Pinned to `cowprotocol/contracts@main`, `cowprotocol/composable-cow@main`, `cowdao-grants/cow-shed@main`,
and the upstream `CowWrapper.sol`.
