# Private Trades

Two parties who already agreed on a trade settle it atomically through CoW Protocol. No order book,
no solver competition, and **neither party sends a transaction** — two EIP-712 signatures, and a
settlement on-chain moves exactly what was agreed and nothing else.

A leaked order is worthless. Outside the pair, every signature reverts.

**Try it:** [live demo](https://ai-demo.neon-garibaldi.ts.net/) (tailnet-only, a local fork, demo
tokens at `/faucet`, no audit) — or [run it yourself](#try-it).

## How it works

Alice creates an offer, Bob accepts. Each half is a contract order (EIP-1271) whose validity depends
on a wrapper that sees **both** halves at once:

```
solver
  |
  |  wrappedSettle(settleData, chainedWrapperData)      <- Atomic Bundle entry point
  v
PrivateTradeWrapper
  |  requires: it is the LAST bundle in the chain
  |  validates: exactly 2 tokens, 2 trades, 0 interactions;
  |             the orders are exact mirrors at the declared prices;
  |             owners are the two expected parties; taker != maker
  |  publishes: the terms both signatures will be checked against
  v
GPv2Settlement.settle(...)
  |  EIP-1271(Alice) -> ComposableCoW -> the terms match what she authorised
  |  EIP-1271(Bob)   -> ComposableCoW -> the terms match what he authorised
  v
both legs transfer, or nothing does
```

The guarantees, in three lines:

- **A leaked order cannot settle alone** — with no active pair, `verify` reverts inside GPv2's own
  signature validation.
- **A leaked maker order cannot be re-paired with a different counterparty** — `allowedTaker` is in
  the commitment the maker authorised.
- **Nothing can run between the check and the settlement** — the wrapper refuses to be an
  intermediate bundle, which matters because CoW's own docs say an intermediate bundle can rewrite
  the settlement calldata.

The framework rules this design takes seriously are in
[docs/DESIGN.md](docs/DESIGN.md); what the PoC is and is not is in
[docs/ASSESSMENT.md](docs/ASSESSMENT.md).

## Try it

```bash
# the fast gate — no chain needed, all four:
forge test --no-match-path 'test/fork/*'      # 116 tests
bash docs/review/run-counterexamples.sh       # 24 lifecycle + 3 concurrency + 2 guards + 3 cancellation race + 11 page
forge fmt --check
node scripts/check-page.mjs
```

```bash
# the full proof — needs the CoW offline stack (docs/OFFLINE.md):
./scripts/link-service-e2e.sh   # settles 100 USDC <-> 100 DAI; asserts neither party sent a transaction
./scripts/app-e2e.sh            # the same flow through two real browser pages
./scripts/private-trade-e2e.sh  # the driver's own path: JIT trade + fulfillment, wrappedSettle submitted by the driver
```

## The pieces

| Piece | What it is |
| --- | --- |
| `src/` | The contracts: wrapper, EIP-1271 order handler, proposal library, optional permissionless submitter. Vendored upstream in `src/vendor/` and `lib/`, never edited. |
| `link-service/` | The service and page. Turns an agreed trade into a shareable link, relays both owner-signed bundles, posts the taker's order. Holds **no key that can move value** and **never re-derives the trade** — the compute script *is* `PrivateTradeBuilder`. [docs/LINK-SERVICE.md](docs/LINK-SERVICE.md) |
| `subsolver/private-trade-solver.mjs` | The sub-solver: an ordinary key with BYOS escrow, no allowlist entry. Pairs the two halves as a JIT trade; the driver encodes and submits `wrappedSettle`. [docs/JIT-PATH.md](docs/JIT-PATH.md) |
| `scripts/demo/` | The local demo runbook: `stack-up.sh`, `faucet-up.sh`, `service-up.sh`. |
| `scripts/demo-faucet.mjs` | Funds demo wallets from the chain's faucet key. Loopback-only, one top-up per address. |

### Who submits the settlement

The wrapper must be allowlisted to call `settle`, and an Atomic Bundle needs an authenticated caller.
The submission path is **BYOS** — a bonded, allowlisted solver that lets an ordinary key submit
against its escrow — rather than a bespoke allowlisted contract. The wrapper verifies the sub-solver's
proposal signature **on-chain**, and the proposal commits to the *pair* (`offerId`, `taker`,
`wrapper`), not the settlement calldata: the calldata contains the orders, so hashing it would be
circular, and the pair determines the rest. `PrivateTradeSubmitter` remains in the tree as an
optional permissionless fallback; it costs one extra allowlist entry.

## What is real in these tests

| Real | Stubbed |
| --- | --- |
| `GPv2Settlement`, `GPv2VaultRelayer`, `GPv2AllowListAuthentication` (unmodified, `cowprotocol/contracts`) | In unit tests the vault is an address: with `BALANCE_ERC20` on both sides the settlement never calls it |
| `ComposableCoW` + the ERC-1271 forwarding path; `COWShedFactory` + Shed v2.1.0 | Bundle allowlisting is a local `addSolver` call, not DAO governance |
| `CowWrapper` and `CowWrapperHelpers`, vendored verbatim from upstream | No DAO allowlisting, no audit |
| Token balances really move; the settlement keeps nothing | |
| The e2e suites settle on a real chain with real settlement, real driver, exact balances | |

Every fix in this repo carries a test that fails when the fix is reverted (mutation-checked), and the
service layer was red-team reviewed with a second, independent verification pass — the confirmed
findings (rate limiting, XSS, command-error leakage, unbounded bodies, bind addresses, dev-endpoint
gating) are closed and pinned in `docs/review/service-hygiene.mjs`.

## Paths covered

| Path | Where |
| --- | --- |
| Contract wallets, against a real settlement | `test/PrivateTradeSettlement.t.sol` |
| appData-declared bundles, upstream `CowWrapperHelpers` | `test/PrivateTradeAppData.t.sol` |
| The driver's wire format, including the appended auction id | `test/PrivateTradeDriverFormat.t.sol` |
| EOA -> CoW Shed, owner-signed bundles, permissionless relay | `test/PrivateTradeShed.t.sol` |
| Real settlement + tokens on the offline chain | `test/offline/` |
| BYOS proposal, signed off-chain, verified on-chain | `src/libraries/PrivateTradeProposal.sol` + both e2e suites |
| Link service: create -> share -> sign -> accept -> settle | `scripts/link-service-e2e.sh` |
| The app: the whole flow through two browser pages | `scripts/app-e2e.sh` |

## Layout

```
src/PrivateTradeWrapper.sol           the Atomic Bundle: validates the pair, publishes the terms
src/PrivateTradeOrder.sol             the EIP-1271 handler: validity depends on the wrapper
src/PrivateTradeAuthoriser.sol        authorises orders only when the terms pay the party's own wallet
src/PrivateTradeSubmitter.sol         optional permissionless fallback relay
src/libraries/                         order derivation, reciprocity, appData, proposal, submission
src/interfaces/                        offer/terms types, errors, interfaces
src/vendor/                            upstream CoW Atomic Bundle base + helpers, verbatim
lib/                                   upstream: cow-contracts, composable-cow, cow-shed, forge-std
link-service/                          server.mjs + page.mjs
subsolver/                             the BYOS sub-solver
test/                                  116 tests: settlement, hardening, shed, tokens, driver format, offline
docs/                                  ASSESSMENT, DESIGN, LINK-SERVICE, JIT-PATH, OFFLINE, DEPLOY, MAINNET-ROADMAP
scripts/                               e2e suites, demo runbook, faucet, page check
```

## Status

Built and verified: the protocol core, the link service, the sub-solver, two e2e suites on a real
chain, the two-page app, the demo.

Not built yet:

1. **Audit and DAO allowlisting** — mandatory for a production bundle; Sepolia is the faithful
   rehearsal (canonical addresses are identical on mainnet and Sepolia). [docs/MAINNET-ROADMAP.md](docs/MAINNET-ROADMAP.md)
2. **BYOS-side proposal support** — the proposal type and its on-chain verification exist here; BYOS
   needs a matching proposal kind.
3. **Non-ERC20 assets** — NFTs, game items, partial fills.

Pinned to `cowprotocol/contracts`, `cowprotocol/composable-cow`, `cowdao-grants/cow-shed` and the
upstream `CowWrapper.sol`; see `foundry.toml`.
