# Roadmap to a mainnet private trade

State at this writing: 82 tests pass, the 15-check review harness passes, contracts and the
link service work end to end against the offline stack. Nothing here is deployed, audited, or
allowlisted. The binding constraint is not code — it is the wrapper allowlist, which is a CoW DAO /
manager action, and the audit the Atomic Bundles docs make mandatory before one.

Canonical addresses are identical on mainnet and Sepolia, so **Sepolia is a faithful rehearsal**:

| Contract | Mainnet | Sepolia |
| --- | --- | --- |
| `GPv2Settlement` | `0x9008D19f58AAbD9eD0D60971565AA8510560ab41` | same |
| `GPv2VaultRelayer` | `0xC92E8bdf79f0507f65a392b0ab4667716BFE0110` | same |
| `ComposableCoW` | `0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74` | same |
| `COWShedFactoryForComposableCoW` | `0x5E284e80F3bd6A7D80A8500D9c49878028110848` | same |
| `COWShedForComposableCoW` (implementation) | `0xF0D400089d5b9fACA64E3422AD6614546587cfFB` | same |

## Step 0 — run the two gates that have never run (1 hour)

1. `FORK_RPC=https://ethereum-rpc.publicnode.com forge test --match-path 'test/fork/*' -vv` — the
   fork suite is skipped without `FORK_RPC`. It exercises the real settlement, the real ComposableCoW
   and the real Shed factory. This is the cheapest proof the contracts work against deployed
   bytecode.
2. `./scripts/offline-e2e.sh`, `./scripts/link-service-e2e.sh`, `./scripts/app-e2e.sh`,
   `./scripts/wallet-e2e.sh` with the offline stack up.
3. One pass of the app flow with a real wallet extension instead of the development wallet
   (`docs/ASSESSMENT.md`, gate 4 — the last unproven step, and the step this project has already
   lost time on twice).

## Phase 1 — freeze the deployment (1 day)

4. Deploy deterministically. `script/DeployPrivateTrade.s.sol` uses `new`, so the address depends on
   the deployer's nonce. An audit and an allowlist entry cover one bytecode at one address: use
   CREATE2 with a fixed salt (`cow-shed`'s own `script/Deploy.s.sol` is the pattern) so Sepolia and
   mainnet land on the same address and the audited artefact is the deployed artefact.
5. Freeze the service config: `RPC`, `ORDERBOOK_URL`, `PUBLIC_URL`, `PRIVATE_TRADE_WRAPPER`,
   `PRIVATE_TRADE_HANDLER`, `PRIVATE_TRADE_AUTHORISER`, `COWSHED_COMPOSABLE_COW_FACTORY_ADDRESS`,
   `COMPOSABLE_COW_ADDRESS`, `VAULT_RELAYER_ADDRESS`, `RELAYER_PRIVATE_KEY`.
6. Write a per-chain deployment manifest and verify the source on Etherscan. The audit needs
   readable source, and an unverified wrapper is an unapprovable one.

## Phase 2 — Sepolia, real infrastructure (about a week, mostly waiting on integration)

7. Deploy the wrapper, handler, submitter and authoriser to Sepolia at the CREATE2 address; verify.
8. Get the **wrapper** allowlisted in Sepolia's `GPv2AllowListAuthentication`. This is a manager
   action: the wrapper cannot settle until it is, and there is no bypass.
9. Register the appData document on the real orderbook (`PUT /api/v1/app_data/{hash}`). Without it
   the driver never sees `metadata.wrappers` and settles without the bundle.
10. Get a BYOS key with escrow on the real or staging instance, and agree the
    `PrivateTradeProposal` schema with the CoW team (`docs/DESIGN.md` open questions,
    `docs/ASSESSMENT.md` gate 3).
11. Settle one trade with two real wallets: an EOA-owned Shed and, if it can be arranged, a
    Safe-owned Shed. Fund, sign, relay, post, let the driver build the bundle, settle, read the
    receipt.
12. Confirm the two driver behaviours `docs/DESIGN.md` flags as the risk in this integration: the
    driver echoes the order's `wrappers` into the solution, and it sets `to = wrappers[0].address`
    encoding `wrappedSettle(settleData, chainedWrapperData)`.

## Phase 3 — the external gates (weeks, not under your control)

13. Audit. Mandatory before allowlist approval, per the Atomic Bundles integration requirements.
    Budget remediation time as well as the audit itself.
14. DAO allowlist approval on mainnet.
15. BYOS production agreement: operator identity, fee payer, signature admission, scoring,
    attribution, liability.

## Phase 4 — mainnet at small size (1 day once the gates clear)

16. Deploy at the audited CREATE2 address on mainnet and verify.
17. Point the service at mainnet: RPC, orderbook, BYOS, addresses, a fresh relayer key with gas.
18. First trade:
    - pick tokens where allowances are already in place (DAI carries a permit; USDC needs an approve
      transaction), and keep the size small enough that losing it is survivable;
    - have the cancellation path ready (`ShedBundle.cancellationCalls`: remove the order and mark
      the offer cancelled in one Shed transaction);
    - watch the settlement, not the balances — `docs/ASSESSMENT.md` blocker 4 was exactly a balance
      decrease reported as a settlement.
19. Reconcile afterwards: proceeds at each party's own wallet (not at the Shed), `offerState` is
    `Consumed`, `ComposableCoW.singleOrders[shed][hash]` still true, and the cancelled-or-settled
    history is visible on chain.

## Phase 5 — operations (2 days before volume)

20. Alerts on the lifecycle (`PrivateTradeOfferConsumed`, `PrivateTradeOfferCancelled`, relay
    failures, settlement receipts) and a documented kill switch.
21. Decide the fee model. `docs/ASSESSMENT.md` is explicit that there is none today: no surplus, no
    fee leg, nothing that pays a solver or the service.

## The critical path, plainly

Audit → DAO allowlist. Everything else on this list is days of work. If a trade on mainnet is
wanted before an audit, the only route is a CoW-hosted staging environment, because the wrapper
cannot call `settle` without an allowlist entry.
