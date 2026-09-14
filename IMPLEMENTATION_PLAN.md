## Stage 1: Contract invariants
**Goal**: Make each offer single-use and validate both trades against their own clearing prices.
**Success Criteria**: The two committed counterexamples revert for the intended contract errors; normal, driver-format, Shed, fork, and offline contract paths remain valid.
**Tests**: Replenished-funds replay, changed-appData replay, duplicate token indices, pre-funded settlement balance, normal settlement and resubmission.
**Status**: Complete

## Stage 2: Signed plan and lifecycle
**Goal**: Give every offer immutable per-offer artifacts and an explicit lifecycle with retry, cancellation, expiry, failure, and recovery.
**Success Criteria**: Interleaved offers cannot cross; retries converge; status requires order and transaction evidence; cancellation runs through the owning Shed.
**Tests**: Interleaved offers, service restart, consumed permit, post-order failure, duplicate acceptance, cancellation race, expiry, failed funded offer withdrawal.
**Status**: Complete

Proved by `docs/review/service-lifecycle.mjs` (9 checks over the real HTTP surface with a fake chain and orderbook) and the existing Solidity suites. Two defects were found and fixed while building it: every typed-data check shared `out-json/verify.json`, so two service instances over one store could verify each other's messages, and a second acceptance arriving during the first one's order round trip relayed and posted again. The acceptance lock is per process; a store-level lock is still open for multi-instance deployment.

## Stage 3: Wallet and browser safety
**Goal**: Support honest ERC20 signing and funding flows without unsafe rendering or false allowance claims.
**Success Criteria**: Permit and approve modes both work; untrusted metadata renders as text; chain/account checks gate signing; allowance scope is displayed accurately.
**Tests**: EIP-2612, DAI permit, no-permit approval, malicious symbol, chain mismatch, account change, supported extension-wallet flow.
**Status**: Not Started

## Stage 4: Submission and product contract
**Goal**: Separate the direct private path from the public JIT experiment and define the real operator, fee, privacy, attribution, and staging contract.
**Success Criteria**: Product copy matches the chosen path; JIT remains a named integration experiment; no BYOS claim exceeds the implemented service; staged submission proof is reproducible when external access exists.
**Tests**: Direct prepared submission, JIT driver compatibility, fee accounting, signed proposal attribution, privacy disclosure checks.
**Status**: Not Started

## Stage 5: Full verification and handoff
**Goal**: Prove the restricted ERC20 desktop beta against real artifacts and record all remaining external gates.
**Success Criteria**: Local, fork, service, browser, recovery, cancellation, and exact balance checks pass; docs and CI run the relevant gates; audit and DAO approval remain explicitly external.
**Tests**: Full suite, mainnet fork, offline app e2e, exact four-way balances, no unexpected residue, restart/recovery suite.
**Status**: Not Started

throughput checkpoint: finish one green, committed stage before starting the next; do not batch contract, service, and UI risk into one unverifiable change.
