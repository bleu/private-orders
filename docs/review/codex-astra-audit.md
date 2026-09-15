# Audit of the previous review

Audited HEAD `d5b1d6c` on 2026-09-15. Correctness and process review only. The checkout was clean. This report is the only repository file created or changed; no commit, deployment, or stack reconfiguration was performed.

`FIXED`, `PARTIAL`, `STILL THERE`, and `DECLINED` are disposition labels. `VERIFIED` means executed in this audit. `READ` means source traced. For checklist entries that were already correct, `FIXED` means the required property remains established, not that a new repair was necessary. A documentation-only qualification is `PARTIAL`. Test success is bounded evidence, not exhaustive equivalence.

## Correctness findings 1-10

| Finding | Disposition and evidence |
| --- | --- |
| 1. Funded retry requires the owner's balance again | **FIXED · VERIFIED.** `link-service/server.mjs:869-884` reads the side's hook nonce and skips the owner-balance requirement when it is used, matching `script/LinkRelay.s.sol:53-56`. The actual HTTP test `a funded side can retry even though its wallet is now empty` passes with zero remaining wallet balance. Restoring the balance-only branch makes that test fail, reporting `must hold 100000000000000000000`. This fixes the reported retry, not every funding prerequisite. A consumed nonce alone does not prove current Shed funds, and the remaining permit acceptance problem is finding 7. |
| 2. Posted expired order remains settling | **PARTIAL · VERIFIED.** `server.mjs:712-717` now reports expired after the deadline unless fulfilled or consumed evidence exists. HTTP test `an order that can no longer fill is reported expired, not settling` passes, including the consumed exception. Terminal settlement remembering passes separately. But cancellation GET still returns the original, expiring bundle (`:1146-1157`), withdrawal does not change lifecycle (`:1254-1255`), and UID-bearing acceptance is still refused (`:1273`). A running browser poll changes only the status label and reloads only for settled (`page.mjs:723-740`), so newly expired status does not itself render recovery controls. No expiry-branch mutation was run. |
| 3. Page invents the Safe domain | **PARTIAL · VERIFIED.** The incorrect typed-data construction is removed. `script/OwnerMessageHash.s.sol:45-48` reads the actual separator, and `page.mjs:711-719` submits `0x`. `test_hashFromTheAccountsOwnSeparatorIsAccepted`, `test_domainBuiltFromNameAndVersionIsNotTheAccounts`, and `test_structHashMatchesTheHandlers` pass. The focused real-Chrome hash-flow test passes. This is now a Safe approved-message workflow, not arbitrary ERC-1271 wallet support. The page uses the trade hash even when asked to sign a withdrawal and cannot collect a nonempty custom contract signature. No hash-computation mutation was run; I could not falsify the hash calculation itself. |
| 4. Two successful signature POSTs lose a signature | **FIXED · VERIFIED for those two POSTs.** `server.mjs:1265-1268` loads within the queue, and `:175-180` reloads immediately before saving. The controlled-interleaving test passes. Removing both reloads while retaining serialization makes it fail with only maker stored. Removing serialization alone leaves the test passing. The fix's broader claim about all writers is false: cancellation and acceptance can still replace newer data. See the new-defect section. |
| 5. Contract signatures constrained to EOA lengths | **PARTIAL · VERIFIED.** `verifies` permits empty and arbitrary even-length hex before ERC-1271 (`server.mjs:425-442`); withdrawal uses the shared shape check (`:1224-1226`). HTTP short-contract-signature tests and the Chrome empty-signature flow pass. However, `signatureProblem` still caps the hex string at 65,536 characters (`:469`), so its maximum is 32,767 bytes. A 32,768-byte blob is refused regardless of account validation. Custom checks reproduced empty-signature acceptance and this cap. Healthy EOA checks require 65 bytes, but a failed first code read can defeat the service's shape/verification agreement within one request. Real Shed authentication remains a separate final check. |
| 6. Builder emits overflowing prices | **PARTIAL · VERIFIED.** GCD reduction at `PrivateTradeBuilder.sol:72-86` fixes equal `2**128` amounts and preserves every positive pair's ratio. The repository's large-denomination test passes and fails when reduction is removed. The failure occurs at its `[1,1]` assertion, before GPv2. A new full wrapper check shows coprime amounts `(2**128, 2**128+1)` remain unreduced, pass structural validation, and fail with `PrivateTrade_NotReciprocal`. Minimal prices cannot make their products fit. Reduction removes avoidable overflow, not all overflow. There is still no early builder/readiness rejection for intrinsically unrepresentable pairs. |
| 7. Pre-signing and relay readiness disagree | **PARTIAL · VERIFIED.** Signature recording now allows a missing permit when allowance covers the amount (`server.mjs:158-170`), funded nonces bypass wallet balance, and unreadable checks are marked `checked:false` (`:809-811,883-884`). The corresponding HTTP tests pass. But `/accept` still requires each permit solely from funding mode (`:1308-1315`). Custom execution yields signature POST `200`, then acceptance `400`, `the maker's side is funded by a permit, so its permitSignature is required`, with sufficient allowance. Zero approval can still coexist with `ready.ok=true`; only taker readiness is rechecked at acceptance (`:1297`). Structural preflight is not settlement simulation. The new page also throws on every permit-funded render. |
| 8. Failed code read cached permanently | **FIXED · VERIFIED for persistence of a failed read.** `hasCode` caches only successful reads (`server.mjs:217-230`). The HTTP retry test passes; restoring cache insertion on failure makes it fail. A new limit remains: repeated calls within one request can disagree. A custom EOA request with only its first code read failing saves a one-byte signature with HTTP `200`. See the ordered fix audit below. Successful code reads remain cached for the process lifetime. |
| 9. Helper predicts Shed authentication too broadly | **PARTIAL · VERIFIED.** `ShedBundle.recover` now passes `v` unchanged (`:286-299`). The existing off-by-27 test verifies both the precheck and real Shed refusal; restoring normalization makes it fail. Deadline and nonce checks remain outside `validSignature`, and both domain functions still read the factory implementation's version (`:158-171`), not an independently upgraded proxy's version. No upgraded-proxy execution was performed. |
| 10. Proposal recovery/commitment overclaims | **PARTIAL · VERIFIED.** Malformed 65-byte signatures now return zero through `ECDSA.tryRecover` (`PrivateTradeProposal.sol:89-96`). Restoring `ECDSA.recover` makes `test_malformedProposalSignatureIsReportedNotReverted` fail with `ECDSA: invalid signature`. Pair-only commitment is now documented at `:27-34` and `PrivateTradeWrapper.sol:236-244`; its fields are unchanged. Empty signatures still intentionally bypass proposal attribution (`PrivateTradeWrapper.sol:250`). No exact-calldata attribution was added. |

### Execution and falsification record

All mutation edits were confined to `/tmp/private-orders-audit.EYkbPv`. Each source was restored after its experiment. Baseline repository tests passed before mutations. Logs have prefix `/tmp/private-orders-audit-`.

| Executed check | Result |
| --- | --- |
| `forge test` in the repository | **VERIFIED.** 109 passed, 0 failed, 2 skipped. Log `forge-root.log`. Foundry 1.7.1, compiler/configuration as in `foundry.toml`. |
| `bash docs/review/run-counterexamples.sh` | **VERIFIED.** Exit 1 at compilation. Missing `script/OwnerMessageHash.s.sol` in its temporary copy. Log `gate.log`. This gate is not green. |
| `node docs/review/service-counterexamples.mjs` | **VERIFIED.** Exit 1, `ReferenceError: serialize is not defined`. Its isolated status-function context was not updated. Log `service.log`. |
| `node docs/review/service-lifecycle.mjs` | **VERIFIED.** 24/24 passed over real HTTP, fake Forge/RPC and fixture orderbook. Same log. |
| `node docs/review/service-concurrency.mjs` | **VERIFIED.** 1/1 passed using the real handler with controlled request-body delivery. Same log. |
| Focused Chrome tests from a `/tmp` copy of `page-safety.mjs` | **VERIFIED.** Approve-funded EOA and contract hash flow both passed. Permit-funded chain-check test failed during render with `ReferenceError: covered is not defined`. Logs `page-focused.log`, `page-error.log`. Only the named tests ran; the runner's unchanged `10/10` or `9/10` denominator in filtered copies is not a coverage count. |
| `forge test --root /tmp/private-orders-audit.EYkbPv --match-contract AuditArithmeticTest --fuzz-runs 1000 -vv` | **VERIFIED.** Five checks passed: 1,000 full-width ratio cases, 1,000 bounded GPv2 arithmetic comparisons, coprime-large rejection, uint256-max settlement, cancelled/malformed error precedence. Log `arithmetic.log`. Test source retained there as `AuditArithmetic.sol.txt` after execution to isolate later mutations. |
| `node /tmp/private-orders-audit.EYkbPv/docs/review/audit-service.mjs` | **VERIFIED.** Custom checks reproduce the two lost-update routes, allowance disagreement, EOA classification change and contract length cap; also verify queue cleanup and fresh terminal snapshot merging. Log `extra-service.log`. RPC/relay/orderbook are controlled, not live broadcasts. |

The following mutations failed the specified repository tests. Commands were `forge test --root <scratch> --match-test <name> -vv`, or a filtered scratch lifecycle runner, or the concurrency runner. These failures establish sensitivity to the named change, not exhaustive coverage.

| Reverted fix | Failing test and observed result |
| --- | --- |
| GCD reduction, set divisor to 1 | **VERIFIED.** `test_largeDenominationPairSettlesWithTheBuiltPrices`: expected 1, got `340282366920938463463374607431768211456`. |
| Both `_limitPriceRespected` calls | **VERIFIED.** `test_predicateRefusesWhatTheSettlementRefuses`: `the predicate calls reciprocal what the settlement refuses on its limit price`. |
| Pass-through v, restore `if (v < 27) v += 27` | **VERIFIED.** `test_offBy27SignatureIsRefusedJustAsTheShedRefusesIt`: `the precheck accepted a signature the Shed refuses`. |
| Non-reverting proposal recovery | **VERIFIED.** `test_malformedProposalSignatureIsReportedNotReverted`: `ECDSA: invalid signature`. |
| UID maker owner, substitute beneficiary | **VERIFIED.** `test_settlesWithShedOwnedOrders`: `PrivateTrade_SettlementDidNotFill(0, ...)`. This checks owner/UID binding after order reuse. |
| Signature-route reloads, retaining queue | **VERIFIED.** Controlled concurrency test stores only maker. Removing only queue instead passes. Serialization of stale snapshots is not a substitute for reloading them. |
| Failed-read cache omission | **VERIFIED.** `one unreadable chain read is not remembered as a fact`: `true !== false`. |
| Funded-nonce balance bypass | **VERIFIED.** `a funded side can retry even though its wallet is now empty`: insufficient-owner-balance failure. |
| Persisting `settledAt` | **VERIFIED.** `a settled trade stays settled when the evidence stops being readable`: actual `settling`, expected `settled`. |
| Stopped-phase detection | **VERIFIED.** `an attempt that stopped is reported as needing recovery, not as current`: actual `funding`, expected `recovery_available`. |

For other `FIXED` entries below, no contrary execution was established. Unless a mutation is explicitly referenced, I could not falsify that entry and did not run a dedicated revert mutation. Unchanged intentional checks are distinguished from new repairs.

## Edge cases

| Original case | Disposition and evidence |
| --- | --- |
| Taker equals maker / SelfTaker | **FIXED · VERIFIED.** Existing `test_validateWrapperDataRejectsSelfTaker` passes; equality is refused by `PrivateTradeWrapper.sol:285`. No new fix needed. |
| Same order twice | **FIXED · VERIFIED.** `test_rejectsDuplicateMakerOrder` passes; ordered mirrored fields and owner comparison at `PrivateTradeWrapper.sol:359-382`. |
| Duplicate token entries and indices | **FIXED · READ.** Supported as before; at least two entries, bounds checked, each leg reads its own indices (`PrivateTradeWrapper.sol:345-346,365-392`). Reusing one index for different required tokens cannot satisfy equality. No dedicated new mutation. |
| Zero clearing prices | **FIXED · READ.** All four used prices must be nonzero (`PrivateTradeLib.sol:105-106`); wrapper converts false to `PrivateTrade_NotReciprocal` (`:387-394`). Unused zeros remain allowed. Zero amounts are structurally refused (`PrivateTradeWrapper.sol:279-283`), even though builder returns defined zero-containing arrays. |
| Equal clearing prices | **FIXED · VERIFIED.** Repository large-pair test and new uint256-max unit-price settlement pass. Positive equal prices need equal raw amounts under exact reciprocity (`PrivateTradeLib.sol:126-129`). |
| Rounding versus GPv2 limit | **FIXED · VERIFIED.** Both limit inequalities added before ceiling division (`PrivateTradeLib.sol:123-127`). The `(1,1)` / `(1,2,1,2)` regression and mutation behave as required. The new bounded arithmetic differential test passes 1,000 cases. |
| Type-limit amounts | **PARTIAL · VERIFIED.** Equal max amounts settle with unit prices. Large coprime amounts still cannot fit GPv2 products; structural validity does not imply settleability. Five-case arithmetic execution above. |
| Expiry type limit | **FIXED · READ.** `_validTo` checks `validFor <= uint32.max - block.timestamp` before conversion (`script/LinkCompute.s.sol:355-358`). No silent wrap in the current time range. After the uint32 timestamp horizon the subtraction itself fails, and no valid future uint32 expiry exists. No repository boundary test or mutation was found/run. |
| Shed owned by a contract | **PARTIAL · VERIFIED.** Real Safe and EOA owner suites pass, and the hash helper matches the vendored Safe. Service cap, generic-contract UI assumptions, withdrawal hash and classification limits remain. `test/PrivateTradeOwners.t.sol:102-127`, `PrivateTradeOwnerHash.t.sol:27-81`; findings 3, 5, 8, 9. |
| Empty proposal signature | **FIXED · READ.** Intentionally unsigned; `PrivateTradeWrapper.sol:250` skips attribution, while `_open` continues normal terms/settlement checks. This is not empty owner-bundle authentication. |
| Permit already expired | **PARTIAL · READ.** Shared initial deadlines remain (`LinkCompute.s.sol:139-153`), nonce skip and adequate-allowance skip precede permit execution (`LinkRelay.s.sol:54,82`). Expired unused hook bundles still fail (`LibAuthenticatedHooks.sol:24-26,39`). Acceptance's unconditional permit requirement remains inconsistent with this. |
| Balance changes between precheck and relay | **PARTIAL · READ.** Nonce-aware retry fixed; no reservation, maker refresh, or inclusion-time guarantee added. Taker-only check `server.mjs:1297`, separate relay calls `LinkRelay.s.sol:37-40`, dry run `server.mjs:280-298`. |
| Cancellation/expiry/watch-tower polling | **FIXED · VERIFIED for handler responses.** Existing unavailable/expired generator tests pass. `PrivateTradeOrder.sol:87-101` still permits earlier input/role errors and returns `PollNever` for unavailable or expired valid requests. Actual watch-tower pruning remains unexecuted. |

## State machines

### Service lifecycle

| Original state | Disposition and evidence |
| --- | --- |
| `open` | **FIXED · VERIFIED.** Creation persists empty signature maps (`server.mjs:1046-1056`); neither phase nor both signatures means open (`:664-676`). HTTP creation/restart and signature tests pass. |
| `signed` | **PARTIAL · VERIFIED.** Both stored signatures give signed (`:674`). Two signature POSTs preserve each other, but cancellation/acceptance can still overwrite newer records. `0x` is a truthy JavaScript string and therefore counts as signed; undefined does not. |
| `expired` | **PARTIAL · VERIFIED.** Now applies with a UID too (`:712-715`). No renew endpoint, still-expiring cancellation bundle, and withdrawal leaves this state unchanged. Unknown order/wrapper reads also enter expired after the local deadline, which does not establish absence of an earlier fill. |
| `funding` | **FIXED · VERIFIED for abandoned-phase detection.** Saved at `:1318-1321`; shown in progress only while `accepting.has(id)`, otherwise recovery (`:670-674`). HTTP stopped-attempt test passes and its mutation fails. No automatic relay resumes at startup. |
| `funded` | **FIXED · READ for abandoned-phase detection.** Saved after synchronous relay (`:1333-1334`); same three-phase stalled predicate as funding. Failure becomes failed, expiry/cancellation still override. No separate funded-phase restart test was run. |
| `published` | **PARTIAL · VERIFIED.** Same stopped-phase recovery, plus duplicate-order response UID adoption (`:540-545`) exercised by HTTP test. Adoption accepts any UID-looking substring in any 400/409 body, not a typed duplicate response checked against the expected UID. It does not establish adoption for every real orderbook error shape. |
| `recovery_available` | **PARTIAL · VERIFIED.** Failed or non-running funding/funded/published phase yields recovery (`:670-680`); nonce-aware funded retry passes. Permit acceptance still blocks an otherwise funded/approved path. Catch response may still say recovery while subsequent GET says expired/cancelled (`:1350-1354`, `:648,676`). Withdrawal is separate and does not advance phase. |
| `settling` | **PARTIAL · VERIFIED.** Known UID without complete evidence returns settling (`:684-717`). Known consumed or fulfilled evidence suppresses expiry, even when remaining evidence is permanently unavailable. No rejected/cancelled-orderbook-status transition before the local deadline. |
| `settled` | **FIXED · VERIFIED for remembering a proven observation.** Initially requires fulfilled order, transaction, successful receipt and consumed wrapper (`:684-687`). Snapshot is saved after a queued fresh read (`:697-702`), and later evidence loss does not unset it (`:653-661`). Custom interleaving preserved a concurrent withdrawal plan. This deliberately retains historical observations, not reorg-aware finality. No direct valid same-process writer was established that overwrites the snapshot once current wrapper consumption is readable. Broader stale-writer bugs remain. |
| `cancelled` | **PARTIAL · VERIFIED.** Chain state outranks remembered settlement (`:648`); cancellation HTTP lifecycle test passes. `cancelledAt` is still not a fallback when RPC is unavailable (`:1191-1192` versus `:647-648`). Expired cancellation plans remain unusable. |

**PARTIAL · READ. Cross-path clock agreement.** Readiness and status now both compare milliseconds with `Date.now()` (`server.mjs:863,665,712`). Contracts compare integer block seconds (`PrivateTradeWrapper.sol:339`, `PrivateTradeOrder.sol:99`). At `validTo*1000 + 1ms`, the service reports expired while a block timestamp equal to `validTo` is accepted. Equal comparison operators did not remove clock-source or precision disagreement. No chain-clock synchronization was added.

### Wrapper lifecycle

| Original transition | Disposition and evidence |
| --- | --- |
| Initial `Available` | **FIXED · READ.** Enum zero/default mapping (`IPrivateTrade.sol:15-18`, `PrivateTradeWrapper.sol:85`). Still no registration/funding inference. |
| `Available` to `Consumed` | **FIXED · VERIFIED.** All terms/proposal/shape/price/owner checks and both fill snapshots precede the write (`PrivateTradeWrapper.sol:171-203`). `test_failedSettlementDoesNotConsumeOffer` passes; downstream revert rolls everything back. |
| `Available` to `Cancelled` | **FIXED · VERIFIED.** Maker-only cancellation, independent of expiry (`:110-119`); maker cancellation tests pass. |
| `Cancelled` to `Cancelled` | **FIXED · VERIFIED.** Idempotent return (`:116`), existing idempotence test passes. Settlement checks cancellation earlier now (`:183`). |
| `Consumed` terminal | **FIXED · VERIFIED.** Repeat settlement and cancellation refused (`:115,182`), no reset setter. Existing terminal-state tests pass. |

**FIXED · READ.** Expiry is still a predicate, not a persisted wrapper state. During settlement the durable state is already consumed, but the handler validates against the active transient window rather than polling availability (`PrivateTradeOrder.sol:122-132`). No new incorrect wrapper transition was found.

### Original requested claims that already held

| Original claim | Disposition and evidence |
| --- | --- |
| Published pair window | **FIXED · VERIFIED.** Existing settlement/handler suites pass. Publication follows checks, active window is single, clearing precedes both fill checks (`PrivateTradeWrapper.sol:146,194-225`); handler uses supplied settlement sender and active pair (`PrivateTradeOrder.sol:69-72,122-132`). |
| Two mirrored full fee-free trades, no interactions, right owners | **FIXED · VERIFIED.** `PrivateTradeWrapper.sol:345-394`; normal settlement and shape tests pass. At least two token entries, not exactly two. |
| Single use, fill records, cancelled refusal | **FIXED · VERIFIED.** `PrivateTradeWrapper.sol:181-225,403-410`; UID-owner mutation fails a full Shed settlement. Fill guard still asks for positive deltas, with exact fills supplied by validated FOK orders and GPv2. |
| Nonempty offchain input refused | **FIXED · VERIFIED.** Both handler entry checks (`PrivateTradeOrder.sol:64,87`) and existing tests pass. |
| Authoriser context and beneficiary | **PARTIAL · VERIFIED.** Checked creation enforces the role beneficiary against the Shed admin (`PrivateTradeAuthoriser.sol:72-78`); owner tests pass. The documented guarantee is path-specific, not proof for every possible delegatecaller or unchecked authorization path. |
| Mirror construction and all-field equality | **FIXED · READ.** `PrivateTradeLib.sol:38-82`; canonical order construction still supplies all twelve fields and equality checks them. |
| Sub-solver validation and unsigned submission | **PARTIAL · READ.** Nonempty proposal checks remain (`PrivateTradeWrapper.sol:250-266`), malformed recovery repaired. Recovered identity remains attribution without an expected-signer allowlist, and commitment is pair-only. |
| Service settlement evidence and acceptance lock | **PARTIAL · VERIFIED.** HTTP evidence/lock tests pass. Lock is one-process, held only during active work and released in finally (`server.mjs:1281-1283,1326-1356`); it does not serialize other writers or stale body snapshots. |
| Relay simulation before broadcast | **FIXED · VERIFIED within opt-out boundary.** HTTP simulation-failure test passes. Explicit `RELAY_DRY_RUN=0` opt-out remains (`server.mjs:280-298`); simulation covers relay, not complete future settlement. |

## Overstated comments

| Original claim | Disposition and current evidence |
| --- | --- |
| Everything knowable before signing / cannot drift | **STILL THERE · READ.** Absolutes remain `server.mjs:19,794-799`. The structural-only call at `:817` cannot establish the execution checks at `PrivateTradeWrapper.sol:175-225,339-394`. Findings 6 and 7 still demonstrate the distinction. |
| Whatever ERC-1271 accepts | **PARTIAL · VERIFIED.** Short and empty now work, but the independent cap remains `server.mjs:469`. Custom 32,768-byte check is refused. |
| Owner never changes kind / one read enough | **PARTIAL · VERIFIED.** Failed reads no longer cached; mutation confirms it. Successful reads remain lifetime-cached and absolute comment remains `server.mjs:215`. |
| Safe domain carries version | **PARTIAL · READ.** Hash runtime now reads the actual separator (`OwnerMessageHash.s.sol:45-48`), but `server.mjs:896-898` still says the domain carries its version. New historical Safe-version assertions at `:723-724`, `page.mjs:702-705`, and `OwnerMessageHash.s.sol:14-18` are not established by this computation. |
| Service-wide safe retry | **PARTIAL · VERIFIED.** Nonce/balance retry fixed and tested, but permit acceptance still disagrees and stale record writers remain. `LinkRelay.s.sol:54,82`; `server.mjs:1308-1315`. |
| No other execution / signs settlement | **PARTIAL · READ.** Pair-only limitation now explicit (`PrivateTradeProposal.sol:27-34`, `PrivateTradeWrapper.sol:236-244`), without changing the commitment at `PrivateTradeProposal.sol:71-72`. |
| Malformed proposal returns zero | **FIXED · VERIFIED.** `tryRecover` now implements the comment (`PrivateTradeProposal.sol:89-96`); revert mutation fails the existing malformed-signature test. |
| Branches exactly as Shed | **PARTIAL · VERIFIED.** Literal branching and v handling now agree (`ShedBundle.sol:296-320`), with mutation-sensitive test. Stronger execution equivalence remains limited by factory version, nonce and deadline. |
| Version from deployed implementation | **STILL THERE · READ.** `ShedBundle.sol:164` still omits that the source is the factory implementation (`:159,171`) rather than the existing Shed's potentially changed implementation. |
| Only this offer spends standing DAI allowance | **STILL THERE · READ.** UI text remains `server.mjs:789`; allowance query is token/owner/spender only (`:642-643`). The unlimited note at `:786` does not cancel the incorrect offer-only text. |
| No orderbook / never public | **PARTIAL · READ.** `docs/DESIGN.md:117,132,164-168` now distinguishes intended direct transport from the implemented public taker-order route. Transport was documented, not replaced. |
| Submitter only causes a completed trade | **PARTIAL · READ.** Original blanket comment replaced with destination scope and standalone relay disclosure (`PrivateTradeSubmitter.sol:22-31,56-62`). The API still intentionally permits intermediate funding/authorization. |
| Exactly two token entries | **PARTIAL · READ.** Comment now correctly says at least two (`IPrivateTrade.sol:66-68`); duplicate entries remain supported (`PrivateTradeWrapper.sol:345-346`). |
| Two-field wrapperData tuple | **PARTIAL · READ.** `PrivateTradeWrapper.sol:128-132` now documents the actual three-field tuple. ABI was not changed. |
| Generator mirrors verify | **PARTIAL · READ.** `PrivateTradeOrder.sol:76-81` explicitly disclaims equivalence. Generator still runs outside the window with zero appData (`:92-101`); verify retains stronger checks. |

**STILL THERE · READ. Additional overclaims introduced or retained with fixes.** `PrivateTradeBuilder.sol:63-65` still describes unreduced prices, directly above the new reduction. `test/PrivateTradeBuilder.t.sol:41-42` says products cannot overflow, which the coprime example disproves. The queue comment says it shares a lock with every other write (`server.mjs:695-696`), but only signature/status writes use it. `service-concurrency.mjs:4-14` incorrectly generalizes that fetch cannot overlap handlers and overlooks cancellation/acceptance awaits. Its controlled-body delivery is useful; the general claim is unnecessary.

## Gas ideas

The following covers all 18 summary-table ideas. Current measured totals are whole Foundry tests, not transaction receipts. `test_settlesWithShedOwnedOrders` uses **1,120,191**, cancellation test **992,313**, and polling test **34,406** gas at this HEAD. Preparation measurements below independently revert one change at a time; savings are not additive.

| Original idea | Disposition and measured or traced evidence |
| --- | --- |
| Direct handler calldata-to-terms comparison | **DECLINED · READ.** Explicit decision `docs/decisions.tsv:49` / commit `d93c6d1`: duplicated field knowledge. Current `PrivateTradeOrder.sol:151-167` retains canonical construction and `PrivateTradeLib.equal`. Reason holds; it avoids an additional representation of twelve fields. No new timing claim. |
| Reuse validated orders for UIDs | **FIXED · VERIFIED.** `_validateSettlement` returns fixed canonical orders after checking actual trades (`PrivateTradeWrapper.sol:338,361-383`), passed directly to `_orderUids` (`:194-200,403-410`). Full settlement passes. Wrong UID-owner mutation fails completion. No isolated fresh gas delta for this one change; implementation is traced and current test total measured. |
| Combined active offer/taker getter | **FIXED · VERIFIED.** `activeTrade()` returns both transient fields (`PrivateTradeWrapper.sol:94-97`), handler calls once (`PrivateTradeOrder.sol:122-132`). Full handler/settlement tests pass. Could not falsify; no getter mutation or isolated fresh gas delta. Old getters are retained for callers. |
| Extraction-buffer reuse | **DECLINED · READ.** Original gas report names it as an alternative to UID reuse (`codex-astra-gas.md`, “Reuse extraction buffers”); current reuse eliminates the second extraction (`PrivateTradeWrapper.sol:194,403-410`). That reason still holds. No separate buffer optimization implemented or fresh saving assigned. |
| Compare calldata with constructed order | **STILL THERE · READ.** Smaller alternative remains unimplemented at `PrivateTradeOrder.sol:155`. The explicit decline concerns direct term comparison; there is no separate stated decision on this variant. |
| Direct call to settlement after LAST | **DECLINED · READ.** `docs/decisions.tsv:49`, commit `d93c6d1` reject coupling to LAST and selector checks for a small gain. `_next` remains (`PrivateTradeWrapper.sol:150`). Reason holds: shared continuation preserves independent validation. |
| Fixed expected-order array | **FIXED · READ.** `GPv2Order.Data[2]` at `PrivateTradeWrapper.sol:338`; part of UID reuse, not an independent additive saving. Full suite passed; no separate mutation. |
| Widen offer-state mapping | **DECLINED · READ.** Original gas review explicitly rejects weaker enum typing and worse polling. Enum mapping remains `PrivateTradeWrapper.sol:85`. The storage/type rationale holds; original before/after figures were not remeasured. |
| Rebuild canonical orders for UIDs | **DECLINED · READ.** Original report rejects measured regression. Current code reuses the canonical orders already checked (`PrivateTradeWrapper.sol:194-200,403-410`), avoiding either reconstruction. Reason holds. |
| Encode offer struct directly | **DECLINED · READ.** Original report rejects measured regression; explicit field hashing remains `PrivateTradeLib.sol:21-34`. Nothing in current code refutes the reason; no fresh performance comparison. |
| Checked multiplication plus ceilDiv | **DECLINED · READ.** Proposed implementation remains absent (`PrivateTradeLib.sol:126-127` retains mulDiv). Original measured-regression reason was not remeasured. Its former wider-domain argument no longer supports the current predicate: new GPv2 overflow guards intentionally exclude oversized products before mulDiv. |
| Compact authorization event | **DECLINED · VERIFIED for retained behavior.** Original report rejects removal of decoded terms. `PrivateTradeAuthoriser.sol:79-80` still emits them; `test_authorisationEmitsTheDecodedTerms` passes. Reason holds because event shape is a tested contract. No new compact-event mutation. |
| Early offer-state read | **FIXED · VERIFIED.** `PrivateTradeWrapper.sol:181-190`; custom cancelled+malformed settlement returns `PrivateTrade_OfferCancelled` first. Existing cancellation test passes. Successful path and consumed write ordering traced. No fresh isolated call-gas delta or early-check revert mutation. Error precedence changes are real, not equivalent behavior. |
| Local cancellation hash | **FIXED · VERIFIED.** `ShedBundle.sol:145`, same `keccak256(abi.encode(params))` as `ComposableCoW.sol:278-280`. Current cancellation test **992,313**; restoring external hash call **994,106**, saving **1,793**. Both pass. Only bundle preparation changes. |
| Hash call-hash array in place | **FIXED · VERIFIED.** `ShedBundle.sol:192-196`. Owner signature-check test **395,510**; restoring packed copy **398,742**, saving **3,232**. Both pass. Word-array payload has exactly length*32 bytes, excluding length word. Not an execution-cost saving in the deployed Shed. |
| Remove duplicate EOA digest | **FIXED · VERIFIED.** Digest inside contract branch only (`ShedBundle.sol:313-320`). Owner signature-check test **395,510**; restoring unconditional digest **405,188**, saving **9,678**. Both pass. This behavior-neutral optimization cannot be falsified by expecting functional tests to fail. |
| Reuse permit-domain read | **FIXED · VERIFIED.** `TokenPermit.sol:75-86,97-106`. EIP-2612 test **84,904**; restoring `kind(token)` reread **86,017**, saving **1,113**. Both pass. Current DAI test **86,154**; no fresh isolated DAI delta. |
| Combined runtime candidate | **PARTIAL · VERIFIED.** UID reuse/fixed array/getter adopted, direct comparisons and direct settlement declined. This is not the original four-change combination. Current settlement test **1,120,191**, not the original proposed **1,116,600**. Pins pass in the actual repository, while deployment docs retain two old addresses. |

**VERIFIED.** Preparation comparison command was `python3 /tmp/private-orders-audit-gas-check.py`; raw outputs are `gas-<idea>-current.log` and `gas-<idea>-reverted.log`. Reverting a pure optimization left the tests passing as expected. I could not falsify behavior preservation for these four changes; measured work increased when each was undone.

### Originally unmeasured ideas and boundaries

| Item | Disposition and evidence |
| --- | --- |
| Calldata-native settlement decoder | **STILL THERE · READ.** Memory decode remains `PrivateTradeWrapper.sol:294-309`; no new benchmark or candidate. |
| Withdrawal execution gas | **STILL THERE · READ.** Script still constructs/replays transfers (`Withdraw.s.sol:84-160`); no end-to-end withdrawal cost measurement established. |
| Custom errors / revert strings | **STILL THERE · READ.** No measured compatible rewrite adopted; polling still emits `PollNever(string)` (`PrivateTradeOrder.sol:97,99`). |
| Remove fills/state/transient clearing | **DECLINED · READ.** Original report rejects loss of behavior. All remain `PrivateTradeWrapper.sol:181-225`; UID mutation demonstrates fill guard importance. Reason holds. |
| Typed-data JSON, balance discovery, submitter forwarding | **STILL THERE · READ.** Existing paths remain (`ShedBundle.sol:211-266`, `Withdraw.s.sol:66-83`, `PrivateTradeSubmission.sol:77-102`); no fresh before/after implementation. |

**PARTIAL · VERIFIED. Measurement and deployment scope.** No production transaction-cost, cold-state, fork, L2 fee, or amortization result was obtained. The original proposed gas values were not silently promoted to fresh measurements. Full suite passes on the real checkout. A scratch copy using a symlinked `lib` failed only its CREATE2 pin because dependency/source-path metadata changed; its arithmetic and focused behavior tests still ran. Replacing the symlink with a physical copy of the same libraries made the scratch pin test pass too (`scratch-pin.log`, 1 passed). That scratch pin mismatch is not a repository defect. The actual docs/pin mismatch below is independent of it.

## Readiness and compatibility

### Inventory and six implementation requirements

| Original finding | Disposition and evidence |
| --- | --- |
| Four custom instances non-upgradable | **FIXED · READ.** Wrapper immutable settlement/authenticator (`src/vendor/CowWrapper.sol:139-150`), handler immutable dependencies (`PrivateTradeOrder.sol:40-48`), stateless submitter/authoriser (`PrivateTradeSubmitter.sol:35-63`, `PrivateTradeAuthoriser.sol:37-88`), direct deployment (`DeployPrivateTrade.s.sol:59-64`). No implementation/configuration upgrade mechanism was added. |
| Broader deployed accounts/dependencies mutable | **STILL THERE · READ.** Shed proxy can update implementation (`COWShedProxy.sol:24-29`); Shed control setters and chain-local authenticator membership remain (`COWShed.sol:45-51,66-77,122-136`, `GPv2AllowListAuthentication.sol:74-106`). Four immutable custom contracts do not establish immutability of the whole dependency graph. |
| 1. External audit/approval | **STILL THERE · READ.** `docs/MAINNET-ROADMAP.md:3-6,63-65` still lists external gates. This audit supplies no external approval or exemption. The previous invitation is not an issued production approval. |
| 2. Inherit CowWrapper | **FIXED · READ.** `PrivateTradeWrapper.sol:77`; inherited caller check/parser at `CowWrapper.sol:154-165`. Already implemented. |
| 3. Isolate user-defined execution | **FIXED · VERIFIED for private wrapper.** LAST plus no settlement interactions (`PrivateTradeWrapper.sol:140,348-350`) retained; full suite passes. Submitter's caller-selected destinations remain a separate limitation below. |
| 4. Validate commitments | **FIXED · VERIFIED.** Authorized static params reach handler (`ComposableCoW.sol:192-205`), and handler/window/shape checks remain (`PrivateTradeOrder.sol:64-72,122-155`, `PrivateTradeWrapper.sol:345-394`). Full suites pass. |
| 5. Deterministic parser | **FIXED · READ.** Pure structural parser `PrivateTradeWrapper.sol:129-132`; expiry remains execution-only at `:339`. A parser pass is deliberately narrower than settlement readiness. |
| 6. Pair execution in both directions | **FIXED · VERIFIED.** Handler window and both fill deltas retained (`PrivateTradeOrder.sol:122-132`, `PrivateTradeWrapper.sol:198-225`). Full settlement succeeds, wrong UID-owner mutation fails. |

### All five numbered reviewer surfaces

| Surface | Disposition and evidence |
| --- | --- |
| 1. Submitter destination scope | **PARTIAL · READ.** `PrivateTradeSubmitter.sol:22-31` now discloses caller-selected destinations and proposes immutables before requesting a seat. The actual destinations remain caller-controlled (`PrivateTradeSubmission.sol:77-88,97-102`). Documenting the limit does not remove it. No stated decision to decline the restriction. |
| 2. Own-wallet proceeds | **PARTIAL · READ.** Checked creation now explicitly scopes the guarantee (`PrivateTradeAuthoriser.sol:57-62,72-78`). Factory ownership is acknowledged at `:28-29`, yet `:30,45-47` still says external checking is impossible. Trusted factory `ownerOf` exists (`COWShedFactory.sol:22-23,81-82`). Unchecked authorization paths do not inherit checked creation's beneficiary test. |
| 3. Pair versus exact calldata attribution | **PARTIAL · READ.** Pair-only scope now stated (`PrivateTradeProposal.sol:27-34`, `PrivateTradeWrapper.sol:236-244`); hash fields still offerId/taker/wrapper, plus signed proposal expiry (`PrivateTradeProposal.sol:71-84`). Beneficiaries, appData and representation are not thereby committed. |
| 4. Deployment/API drift | **PARTIAL · VERIFIED/READ.** Tuple comment and CREATE2 roadmap corrected (`PrivateTradeWrapper.sol:128-132`, `MAINNET-ROADMAP.md:32-35`). Actual pin test passes. DEPLOY wrapper/handler match, but submitter/authoriser at `DEPLOY.md:52-53` do not match `PrivateTradeDeploy.t.sol:109,113`. `DEPLOY.md:7` still overstates cross-chain allowlisting; membership is chain-local state. |
| 5. Submission mode and proof | **PARTIAL · READ.** Direct/private versus public taker/JIT route now separated (`DESIGN.md:164-168`, `DEPLOY.md:77-85`). Operational stages 4 and 5 remain not started (`IMPLEMENTATION_PLAN.md:25-35`); one-process concurrency boundary remains at `:13`. No agreed external operator/fee/admission package was established. |

### All five staging-request checklist items

| Item | Disposition and evidence |
| --- | --- |
| 1. Deployment evidence | **STILL THERE · READ.** No selected staging deployment receipt/address/code package established. `MAINNET-ROADMAP.md:3-6,46-47` still lists deployment work. Local passing CREATE2 predictions do not supply it. |
| 2. Source verification | **STILL THERE · READ.** `DEPLOY.md:107-116` contains commands, not current explorer verification evidence. |
| 3. Exact allowlist scope | **PARTIAL · READ.** `DEPLOY.md:70-80` explains seats, but no issued selected-chain approval is recorded. Wrapper caller and settlement caller checks remain distinct (`CowWrapper.sol:156`, `GPv2Settlement.sol:121-126`). |
| 4. Dependencies/use case | **PARTIAL · READ.** Addresses/configuration and routes recorded (`MAINNET-ROADMAP.md:12-16`, `DEPLOY.md:77-85`). No selected staging-chain bytecode/current proxy-version verification. DEPLOY's own-wallet statement at `:83` remains broader than checked-path enforcement. |
| 5. Reproduction/integration agreement | **PARTIAL · VERIFIED/READ.** Current local suite, HTTP checks and focused browser checks were executed. Gate/browser defects prevent an all-green result; external integration agreement remains unestablished (`IMPLEMENTATION_PLAN.md:25-35`). |
| JSON `address` versus Solidity `target` | **FIXED · VERIFIED/READ.** `PrivateTradeAppData.sol:56-64` still emits `address`, `data`, `isOmittable`; schema test passes. Solidity helper tuple still uses `.target` (`CowWrapperHelpers.sol:73-80`). No current deployed Rust-deserializer execution was performed. |

### CowAuthWrapper comparison and five concrete adoption changes

The pinned template comparison was refreshed from revision `e683acf38efd7010eb4f90dcb10f3b2c7d6ac608`, not from a moving branch. Sources were fetched into `/tmp` and read. References below use that revision's [CowAuthWrapper.sol](https://github.com/cowprotocol/bundles-template/blob/e683acf38efd7010eb4f90dcb10f3b2c7d6ac608/src/CowAuthWrapper.sol), [PreApprovedHashes.sol](https://github.com/cowprotocol/bundles-template/blob/e683acf38efd7010eb4f90dcb10f3b2c7d6ac608/src/PreApprovedHashes.sol), [CowWrapper.sol](https://github.com/cowprotocol/bundles-template/blob/e683acf38efd7010eb4f90dcb10f3b2c7d6ac608/src/CowWrapper.sol), [helper](https://github.com/cowprotocol/bundles-template/blob/e683acf38efd7010eb4f90dcb10f3b2c7d6ac608/src/CowWrapperHelpers.sol), and [README](https://github.com/cowprotocol/bundles-template/blob/e683acf38efd7010eb4f90dcb10f3b2c7d6ac608/README.md). No conclusion about current PR merge status or deployed backend versions is claimed.

| Original finding | Disposition and evidence |
| --- | --- |
| Outer auth can coexist; LAST does not ban outer postlogic | **STILL THERE · READ.** Private LAST rejects only remaining inner wrappers (`PrivateTradeWrapper.sol:140`); outer `_next` returns normally after downstream execution (`CowWrapper.sol:205-218`). `DESIGN.md:231-234` still excludes outer post-settlement composition; new `DEPLOY.md:87-88` is similarly too broad. |
| Existing payload/appData are not auth-envelope bytes | **STILL THERE · READ.** Private ABI tuple at `PrivateTradeWrapper.sol:172-173`, JSON hash at `PrivateTradeAppData.sol:56-70`. Template fixed prefix/single 65-byte signature at `CowAuthWrapper.sol:128-136`, envelope check `:160-164`. No migration implemented. |
| Unrelated third auth-owned order cannot be added | **STILL THERE · READ.** Exactly two expected trades/owners remain (`PrivateTradeWrapper.sol:345-346,359-382`). This is an intentional pair restriction, not a new defect. |
| Shed signature validation does not consult auth commit | **STILL THERE · READ.** GPv2 calls prefixed owner (`GPv2Signing.sol:281-302`); Shed forwards to ComposableCoW (`ERC1271Forwarder.sol:30-46`), which calls private handler (`ComposableCoW.sol:196-205`). Handler uses only its private window/terms checks (`PrivateTradeOrder.sol:64-72,122-155`). Template `_settlementOrderOwner` changes UID construction (`CowAuthWrapper.sol:191-195,250-268`), not that dispatch. |
| Change 1. Add auth to actual validation | **STILL THERE · READ.** No auth verifier call added to foregoing route. Template's transient verifier reads its own storage (`:337-354`); naming the Shed as UID owner does not make the call happen. |
| Change 2. Authorize both parties / common envelope | **STILL THERE · READ.** Private static terms and equal JSON appData retained (`PrivateTradeWrapper.sol:355-362`). Template `_commitOrder` is private and commits one order (`:154-159,183-195`). No bilateral auth-envelope implementation. |
| Change 3. Port body or deliberately retain outer layers | **STILL THERE · READ.** Existing non-virtual concrete `_wrap` retained (`PrivateTradeWrapper.sol:136-152`); template concrete `_wrap` remains non-virtual (`:124-127`) and invokes `_authedWrap` (`:139`). No implemented composition/port. |
| Change 4. Signing/encoding/service integration | **STILL THERE · READ.** Existing Shed EIP-712 and JSON appData retained (`ShedBundle.sol:211-266`, `PrivateTradeAppData.sol:56-70`). Template accepts fixed 65-byte ECDSA/preapproval (`:128-132,173-180`), not arbitrary ERC-1271 blobs. Safe-message repair is a different change. |
| Change 5. Redeploy and configure lifecycle/custody | **STILL THERE · READ.** CREATE2 code dependencies remain (`PrivateTradeDeployment.sol:47-58`); no auth/private deployment established. Default auth owner is the wrapper (`CowAuthWrapper.sol:267`), which would also change GPv2 token source (`GPv2Settlement.sol:433-438`). |

### Four port invariants and preapproval semantics

| Original item | Disposition and evidence |
| --- | --- |
| Exact reciprocity | **FIXED · VERIFIED in current implementation only.** Two-leg exact execution/limit checks retained (`PrivateTradeWrapper.sol:345-394`, `PrivateTradeLib.sol:123-142`); arithmetic checks pass. No port exists in which to establish preservation. |
| Pair binding | **FIXED · READ in current implementation only.** Active offer/taker/role and expected owner checks remain (`PrivateTradeOrder.sol:122-155`, `PrivateTradeWrapper.sol:359-382`). No port preservation proof. |
| Single use | **FIXED · VERIFIED in current implementation only.** Durable check/write and cancellation remain (`PrivateTradeWrapper.sol:110-119,181-203`); terminal state tests pass. No port preservation proof. |
| Own-wallet proceeds | **PARTIAL · VERIFIED.** Checked creation/owner tests establish the named path (`PrivateTradeAuthoriser.sol:72-78`); template's abstract `_authorizingOwner` imposes no equivalent default (`CowAuthWrapper.sol:234-248`). |
| Auth preapproval is not automatically consumed | **STILL THERE · READ.** Refreshed template calls `isHashPreApproved` (`CowAuthWrapper.sol:174-176`), not `_consumePreApprovedHash` (`PreApprovedHashes.sol:58-66`). Transient commit is read without clearing (`CowAuthWrapper.sol:345-354`). Neither becomes offer-wide durable consumption merely through composition. |
| Template README/helper comment discrepancies | **STILL THERE · READ.** Pinned README `:27-30` summarizes appData verification and a computation helper differently from `CowAuthWrapper.sol:160-188,203-208,345-354`. Helper's “fully consumed” wording (`CowWrapperHelpers.sol:52-55`) still depends on delegated wrapper validation (`:77-81`). No change in the pinned sources. |

### All five ranked adoption ideas

| Rank / idea | Disposition and evidence |
| --- | --- |
| 1. Separate wallet, settlement owner, receiver, UID | **PARTIAL · VERIFIED/READ.** Authoriser scope and UID prose clearer (`PrivateTradeAuthoriser.sol:57-62`, `PrivateTradeWrapper.sol:398-410`); owner tests pass and wrong-owner UID mutation fails. Some external-ownership absolutes remain, and no broader common API was introduced. |
| 2. Preserve order-to-wrapper and wrapper-to-fill checks | **FIXED · VERIFIED.** Existing window and both UID checks remain; full suite and UID mutation establish sensitivity (`PrivateTradeOrder.sol:122-132`, `PrivateTradeWrapper.sol:198-225`). |
| 3. Reproducible tooling/deployment evidence | **PARTIAL · VERIFIED/READ.** CI invokes the gate (`.github/workflows/test.yml:46`) but it currently fails; Foundry installs are unpinned (`:22-23,67-68`), and two DEPLOY addresses are stale. Local pins pass, not deployment proof. |
| 4. Structured pair signing / nested envelope | **STILL THERE · READ.** Existing bundle/JSON encoding retained (`ShedBundle.sol:211-266`, `PrivateTradeAppData.sol:56-70`). No implemented port or stated decline; not established as a staging prerequisite either. |
| 5. Helper preflight / terminal preapproval | **PARTIAL · READ.** Existing helper already checks code, allowlisting, parsing and lengths (`CowWrapperHelpers.sol:71-91`). No adopted auth-preapproval lifecycle or newly integrated consumption. Current cancellation remains ComposableCoW plus wrapper. |

### Original proof limitations

| Original limit | Disposition and evidence |
| --- | --- |
| Live deployment/code/proxy/source/allowlist checks | **STILL THERE · READ.** Selected staging deployment was not provided/verified; predictions and command templates remain the available repository evidence (`DEPLOY.md:40-53,107-116`). |
| External approval/backend-envelope support | **STILL THERE · READ.** No actual auth-envelope path or selected-chain operator package established. Current source validation is the existing Shed/ComposableCoW path above. |
| Earlier selected-test-only proof | **PARTIAL · VERIFIED.** Full local suite and HTTP checks now run, with explicit gate/browser failures. Two environment-dependent tests remain skipped. No local result establishes external approval. |
| Schema test narrower than Rust execution | **PARTIAL · READ.** Scope now disclosed in `PrivateTradeDriverFormat.t.sol:18-22`; still Solidity JSON-path assertions. |
| Claimed four-byte appendix test used 32 bytes | **FIXED · VERIFIED.** Existing ABI-word test renamed, new packed-four-byte test present (`PrivateTradeDriverFormat.t.sol:24-52`); both pass in full suite. No mutation run; could not falsify accepted four-byte handling. |
| Cross-chain deployment test only compares predictions | **PARTIAL · VERIFIED/READ.** Renamed/qualified test at `PrivateTradeDeploy.t.sol:40-57` passes. It still does not deploy on two live chains, and its cross-chain allowlist comment remains too broad. |
| Auth/private integration unexecuted | **STILL THERE · READ.** No concrete port in the current handler/wrapper, no executed template-private composite. |

## New defects introduced by the fixes

### 1. GCD prices

**PARTIAL · VERIFIED.** Ratio reduction is correct, but universal overflow prevention is not established. For positive sell amount `S`, buy amount `B`, and `g = gcd(S,B)`, the returned prices are `[B/g,S/g]`. Both divisions are exact. Each GPv2 product is `S*B/g`, the least common multiple of the amounts. It can still exceed uint256. The equal-large case is repaired; coprime `(2**128,2**128+1)` is not representable with any positive integer prices for this exact pair.

The new arithmetic test verifies that example is accepted by `validateWrapperData` but refused at settlement validation, plus 1,000 full-width positive-pair reductions. Zero/zero returns `[0,0]`, and one-zero pairs contain a zero price; wrapper structural checks reject those amounts. Evidence is `PrivateTradeBuilder.sol:72-86`, `PrivateTradeWrapper.sol:279-283,387-394` and `arithmetic.log`.

**FIXED · READ for caller compatibility.** No current repository caller was found that requires the old scale. `settleData` uses the vector directly (`PrivateTradeBuilder.sol:135-138`), JSON builders export both reduced prices (`LinkCompute.s.sol:96-98`, `PreparePrivateTrade.s.sol:207-220`), and the solver forwards them (`subsolver/private-trade-solver.mjs:82`). The reference test now compares ratios (`PrivateTradeBuilder.t.sol:34-46`). Normal settlement/builder tests pass. External consumers were not inventoried. No new incorrect-ratio defect found.

### 2. Reciprocity predicate and GPv2

**FIXED · VERIFIED.** For each leg, the predicate now checks the same two multiplication bounds and limit inequality as GPv2, then the same ceiling result (`PrivateTradeLib.sol:123-142`; `GPv2Settlement.sol:368-391`). Vendored `SafeMath.mul` itself requires a representable product (`lib/cow-contracts/src/contracts/libraries/SafeMath.sol:68-72`). Therefore rejecting either overflowing limit product cannot refuse an exact pair that this GPv2 implementation would accept.

For positive integer prices, GPv2's limit inequality plus `ceil(S*sellPrice/buyPrice) == B` actually forces `S*sellPrice == B*buyPrice`. The limits require the quotient at least B, and the ceiling equality requires it at most B. This also shows why merely rounding to B was insufficient. The predicate still deliberately excludes GPv2-acceptable better-than-agreed fills; that is the private pair's exact-execution contract, not a guard regression. One thousand bounded differential cases, max-amount unit-price settlement and the limit-check mutation passed their expected outcomes. No new arithmetic defect was found in the predicate.

### 3. Earlier consumed/cancelled check

**PARTIAL · VERIFIED for error compatibility; FIXED · READ for write ordering.** The change is before decoding settlement calldata, not before decoding wrapper data. Terms and proposal still run first (`PrivateTradeWrapper.sol:172-183`). For a cancelled offer with `hex"1234"` settlement calldata, the new check returns `PrivateTrade_OfferCancelled`; previously the decoder would return `PrivateTrade_InvalidSettleData`. Expiry, shape, price, and fill-read errors similarly become secondary for unavailable offers.

The custom precedence test passed. Repository client searches found no application branch depending on the displaced error for unavailable offers; tests for available malformed calldata still pass. That does not establish compatibility for unknown external callers. The consumed write remains after all settlement checks, UID construction and both pre-fill reads (`:194-203`), and before the external settlement/window use. Full suite rollback tests pass. No new state-write ordering defect found.

### 4. Expired, remembered settlement and stopped phases

**PARTIAL · VERIFIED/READ.** The new ordinary transitions work, but the status contract has limits. `fulfilled` or `consumed` deliberately suppresses expiry while waiting for other evidence (`server.mjs:687,713`); both unavailable reads do not. If the first evidence retrieval happens after the deadline during an outage, `unknown/unknown` can produce expired without establishing whether an earlier settlement happened. Remembered `settledAt` avoids this only after a successful earlier observation. Host milliseconds also differ from chain seconds.

**FIXED · VERIFIED for the remembering write.** The queued callback re-reads and changes only `settledAt`/`settlementTx`; there is no await between its fresh read and save (`:697-702`). A custom pending-order-response test wrote a withdrawal plan in the interim and verified it survived. Existing terminal-memory mutation fails as expected. The comment that every writer uses this lock is false, but no valid ordinary single-process path was established that erases a proven snapshot while consumed state remains readable. A fake successful cancellation after consumption would not prove such a path, because the real wrapper rejects it.

**PARTIAL · READ for page recovery.** `poll()` only reloads for settled (`page.mjs:723-740`). A response that first becomes expired/recovery updates a label, not the displayed controls, and the polling timer continues. Reload renders recovery, but that is not the promised automatic transition. Further, recovery copy says funding succeeded and the order was never placed (`:414-418`) even for a stopped funding phase or an uncertain remote-post outcome. No fresh browser poll-transition test was run.

### 5. Empty/variable signatures and EOA paths

**PARTIAL · VERIFIED.** Healthy code reads enforce 65-byte EOA shape in `/signature`, `/accept`, `/withdraw` through `signatureProblem` (`server.mjs:146-148,1291-1292,1224-1226`). `verifies` requires 65 bytes for EOA verification (`:443`). Cancellation requires `verifies(...) === true` (`:1166`), so null does not pass that route. Actual withdrawal and relay authentication additionally call `ShedBundle.validSignature` (`Withdraw.s.sol:147-150`, `LinkRelay.s.sol:145-169`), whose EOA recovery requires 65 bytes (`ShedBundle.sol:286-299`).

The service cap of 32,767 contract-signature bytes remains, independent of `verifies` accepting any even-length blob. The transient-read exception below means “65 bytes on every service path” is not true. No invalid on-chain EOA execution was established.

### 6. Failed `hasCode` read can change classification mid-request

**STILL THERE · VERIFIED.** Removing failure caching fixes process-long misclassification but exposes disagreement among repeated calls. A failing first read makes `signatureProblem` treat a nonempty one-byte EOA signature as a contract blob. The next successful read during `checksBeforeSigning` classifies that same owner as EOA and caches false. `verifies` then returns null for the short EOA blob, while `preflight` rejects only false (`server.mjs:425-442,458-470,512-517`). The signature POST saves the blob and returns 200.

Custom execution printed `first code read fails, next identifies EOA: 1-byte signature saved with 200; code reads 2`. The check changes only the controlled RPC read sequence, and uses the actual request handler. For withdrawal, the service shape check can also temporarily use the contract branch, but the real Solidity script still rejects invalid EOA authentication. The defect is an inconsistent service precheck and success response, not established successful execution with an invalid signature.

Other repeated readers can disagree in the same response. `/role` computes funding before owner/ready classification (`server.mjs:1090,1124-1129`), and `signatureProblem` can call `hasCode` twice for an empty blob. Failed reads are retried immediately; repeated failures cause repeated synchronous RPC work rather than a cached answer. Successful reads are consistent thereafter. No request-scoped single result or explicit unknown state exists.

### 7. Page hash flow, withdrawal and permit-funded render

**FIXED · VERIFIED for the Safe trade hash.** A digest is one bytes32, so `abi.encode(digest)` and `abi.encodePacked(digest)` both contain exactly the same 32 bytes. The script computes the same `SafeMessage(bytes)` hash as the compatibility handler (`CompatibilityFallbackHandler.sol:28-35,54-58,77-80`) and the default extensible handler (`SignatureVerifierMuxer.sol:152-166`). The live-contract hash tests and focused Chrome empty-signature flow pass. The extensible handler's separately registered custom-domain path is not a universal SafeMessage promise.

**PARTIAL · READ for contract-account support.** Empty signatures check `safe.signedMessages(messageHash)`, not the per-owner `approvedHashes` mapping. The ordinary mechanism sets that message state through `SignMessageLib.signMessage` (`SignMessageLib.sol:22-35`). The page only tells users to approve a hash, and has no generic ERC-1271 signature input. `ownerMessageHash` additionally depends on readable Safe-style `getThreshold`, `getOwners`, and `VERSION` calls before it is requested (`server.mjs:891-903`). Contract accounts without those getters, even if they validly authenticate nonempty blobs through the service, cannot complete this page flow.

**STILL THERE · READ. Withdrawal uses the wrong approval context.** `appendShedContents` calls `signDigest(plan.typedData, plan.digest)` (`page.mjs:310`), but the contract branch ignores both arguments and checks only `me.ready.account.messageHash`, which belongs to the trade (`:711-719`; `server.mjs:900`). Neither withdrawal response nor page computes/displays the withdrawal's Safe message hash. Approving the trade's message does not approve the different withdrawal message. The API and on-chain helpers can support a correctly authorized contract withdrawal; the new empty-signature page path does not supply that workflow. No real Safe withdrawal was executed.

**STILL THERE · VERIFIED. Permit-funded pages throw during render.** `page.mjs:456` declares `approved`, but `:466` uses undeclared `covered`. With permit funding, evaluating `!covered` throws `ReferenceError: covered is not defined` before the signing controls and chain warning render. With approve funding, short-circuit evaluation avoids the undefined reference, explaining why those focused tests pass. The existing real-Chrome chain-check test reproduced the failure; a scratch diagnostic called `render()` and captured that exact error. `node scripts/check-page.mjs` passes because this is a runtime identifier error, not syntax.

**FIXED · VERIFIED for healthy EOA approve-and-sign.** The existing Chrome test passes through `eth_sendTransaction`, allowance polling, typed-data signing and stored maker authorization without a permit. Source preserves active-account check, approve calldata and allowance confirmation (`page.mjs:580-598`), then EIP-712 signing (`:610`, `:711-712`). This result does not extend to the broken permit-funded path.

### 8. Signature serialization and other writers

**FIXED · VERIFIED for queue completion/cleanup.** `serialize` chains `previous.then(run,run)`, settles its tail on either result, and deletes only the current tail (`server.mjs:121-132`). A custom rejected callback followed by a successful one returned 42 and left `offerQueues.size == 0`. Current queued callbacks are synchronous and nonrecursive; request bodies are read before queuing. No deadlock or retained queue entry was found on these paths. A future callback that never resolves would hold its queue, but no such callback exists here.

**STILL THERE · VERIFIED. Other writers can still lose successful updates.** Both were reproduced against the actual handler with controlled asynchronous boundaries:

| Interleaving | Executed result and source |
| --- | --- |
| Cancellation loads an offer, waits for its body; maker signature is then saved; cancellation body arrives | Signature 200, cancellation 200, stored signatures `{}`. The cancel route saves its original snapshot (`server.mjs:1075,1161,1191-1192`), outside the queue. This is a valid available-offer cancellation sequence, not cancellation after consumption. |
| Acceptance pauses during orderbook POST; maker signature POST updates the record; order POST returns | Signature 200, acceptance 202, older maker signature restored. The final accept save uses its pre-POST object (`server.mjs:1344-1347`). A fresh withdrawal plan written in the same interval is equally outside that old snapshot by source tracing. |

`GET /withdraw` itself runs synchronously from load to save (`server.mjs:1203-1215`), so its own two GETs do not interleave in one event-loop turn. That does not prevent a later acceptance/cancellation snapshot from removing its write. `POST /withdraw` awaits a body but does not save the record; the comment must distinguish it from cancellation/acceptance. The queue does not protect multiple service processes, which remains an expressly documented limit.

**PARTIAL · VERIFIED. Redundant-permit fix stops at signature recording.** With sufficient allowance on both permit-capable sides, maker `/signature` succeeds without a permit. `/accept` still returns 400 asking for the maker's permit (`server.mjs:1308-1315`). The real relay would skip the permit at `LinkRelay.s.sol:82`. The repository test covers only `/signature`, so its pass does not establish the end-to-end claim. This is a residual omission exposed by the new page/API behavior, rather than new GPv2 behavior.

### Additional process defects

| Item | Disposition and evidence |
| --- | --- |
| Gate does not copy new script dependency | **STILL THERE · VERIFIED.** `run-counterexamples.sh:20-24` copies src/test/config and links lib, but `PrivateTradeOwnerHash.t.sol:10` imports a script. Exact gate fails before its test selection, even though only ReviewCounterexamples is requested. |
| Isolated status fixture lacks new persistence dependencies | **STILL THERE · VERIFIED.** `service-counterexamples.mjs:15-24` supplies neither `serialize` nor load/save dependencies. Its fulfilled-evidence branch fails at `:43` with `ReferenceError: serialize is not defined`. Fixing only the gate copy will expose this second failure. |
| Two documentation deployment addresses are stale | **STILL THERE · VERIFIED/READ.** Real pin test passes. `DEPLOY.md:52-53` lists submitter `0xe833E42Ad12bF2c72Ee4B761Ca020F638EF28AE5` and authoriser `0x46724A7550549C4Df246819F6D4Eb4a22AF9600B`; current pins are `0x897bA1d0020517Cb7a08FFAE1504DA880828699C` and `0xd449F8F37802959d6369Fd701A9A88f5931588a5` (`PrivateTradeDeploy.t.sol:109,113`). Wrapper/handler entries agree. These are predictions, not fresh deployment observations. |

## What I could not establish

1. **PARTIAL · VERIFIED/READ. Local proof only.** Read-only probes returned chain ID `1` from `http://localhost:8545` and HTTP 200/version text from `http://localhost:8080/api/v1/version`. No transaction was sent to that stack. Both advertised e2e scripts stop/restart solver/service processes and alter local stores (`scripts/link-service-e2e.sh:99-116`, `scripts/app-e2e.sh:58-69`), conflicting with the instruction not to stop or reconfigure it. They were read, not run. No new live settlement, Safe transaction, withdrawal, fork or extension-wallet proof is claimed.
2. **PARTIAL · VERIFIED. The gate is not green.** Full repository Forge, 24 HTTP lifecycle tests, one controlled concurrency test, two focused Chrome paths and scratch arithmetic/mutations were run. The exact gate and isolated service-counterexample runner fail, and a permit-funded page fails at runtime. The whole browser suite was not completed after the repeated render failure. Passing focused checks do not replace these failures.
3. **PARTIAL · READ. Remaining boundaries.** No independently upgraded Shed, generic custom ERC-1271 wallet page, multiple-process exclusion, unknown external error consumer, real lost orderbook response, reorg-aware status, deployed Rust parser or staging approval was established. Durable settlement remembering intentionally trusts its first complete observation. No incorrect agreed-amount transfer was observed in this audit.
4. **PARTIAL · VERIFIED/READ. Reproducibility scope.** Scratch code, custom checks and raw logs remain under `/tmp/private-orders-audit.EYkbPv` and `/tmp/private-orders-audit-*`; they are temporary artifacts, not committed tests. Mutation failures, commands, mathematical conditions and current code references are recorded above. Dedicated mutations were not run for every unchanged property, comment-only correction, expiry bound, gas getter or four-byte appendix. Those entries explicitly state their limits; none is an exhaustive proof.
5. **FIXED · VERIFIED. Workspace constraint.** Final tracked diff is empty and the only new repository file is `docs/review/codex-astra-audit.md`. No commit was created. Existing plan/review/code/test files were left untouched.
