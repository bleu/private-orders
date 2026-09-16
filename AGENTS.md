# Working in this repository

A proof of concept that settles a **pre-agreed bilateral trade** through CoW Protocol: two parties agree
terms, both keep their balances in a CoW Shed, and neither sends a transaction. A relayer submits the
signatures and a solver settles the pair atomically.

Read `docs/ASSESSMENT.md` for what it is and is not, `docs/DESIGN.md` for why it is shaped this way, and
`docs/LINK-SERVICE.md` for how the service and page behave.

## Verify before you claim anything

The fast gate, no chain needed. Run all four after any change:

```sh
forge test --no-match-path 'test/fork/*'      # 116 tests
bash docs/review/run-counterexamples.sh       # 24 lifecycle + 3 concurrency + 2 guards + 3 cancellation race + 11 page
forge fmt --check
node scripts/check-page.mjs
```

**Every fix needs a test that fails when the fix is reverted.** Run the mutation: revert your change, watch
the test fail, restore. `docs/review/service-harness.mjs` exists to drive the real request handler with
controlled interleavings, which `fetch` cannot produce; `docs/review/service-counterexamples.mjs` is how
extracted handlers get a working context. Several fixes in this repo were wrong until a mutation proved the
test was not exercising them.

The full check needs the CoW stack running (`docs/OFFLINE.md`) and proves the thing that matters — a real
chain, real settlement, exact balances:

```sh
./scripts/link-service-e2e.sh   # settles 100 USDC <-> 100 DAI, asserts neither party sent a transaction
./scripts/app-e2e.sh            # the same flow through two real browser pages
```

## Do not "fix" these; they are the environment

An agent that reads the source will not find these, and will misdiagnose them as bugs in our code:

| Symptom | Cause |
| --- | --- |
| Stack healthy, nothing ever settles | `host.docker.internal` does not resolve on a plain Linux Docker engine. The driver needs `extra_hosts: ["host.docker.internal:host-gateway"]`. |
| Sub-solver exits immediately | 9100 is node_exporter's port. Set `SUBSOLVER_PORT` and match `endpoint` in `config/offline/driver.toml`. |
| Sub-solver logs "acceptance not in this auction" | The orderbook keeps orders across runs and the auction served a stale one. Clear the `orders` table (`scripts/demo/reset-and-run.sh`). |

Also: `render()` in `link-service/page.mjs` is *text inside a template literal*. A raw backtick anywhere
in it ends the template and the syntax error appears somewhere else entirely.

## Conventions this repository actually enforces

- **Vendored code is not edited.** `lib/` is upstream; adapt with a wrapper or an interface declared
  locally, the way `IGPv2FilledAmount` is.
- **Four CREATE2 addresses are pinned** in `test/PrivateTradeDeploy.t.sol` and `docs/DEPLOY.md`. They move
  whenever compiled bytecode changes — including for a comment-only edit, because Solidity's metadata hash
  covers the source text. Re-pin both files in the same commit; the failing test says which one moved.
- **Decisions are logged** in `docs/decisions.tsv` (tab-separated: time, phase, decision, why, evidence,
  result). Add a row when you make a call someone would otherwise re-litigate.
- **Comments state what the code establishes, not what it is named after.** Claims outrunning checks was
  the most common defect class here: `filledAmount` is settlement bookkeeping, not evidence tokens moved.

## Try the demo

`scripts/demo/README.md` is the runbook. Locally: `stack-up.sh`, `reset-and-run.sh`, `service-up.sh`,
`faucet-up.sh`. A hosted instance is at `https://ai-demo.neon-garibaldi.ts.net/` with demo tokens at
`/faucet` — tailnet-only, a local fork, worthless tokens, no audit.
