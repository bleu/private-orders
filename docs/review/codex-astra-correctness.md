# Correctness review

Reviewed `d2b7391` on 2026-09-15. This is a correctness and maintainability review, not a security assessment. No new wrong-settlement result was established. The main discrepancies concern recovery, signatures, and claims that a preliminary check establishes more than it actually checks.

**Evidence labels.** VERIFIED means executed here, with the execution boundary stated. READ means traced in source. SUSPECTED means reasoning without confirmation. Previously established findings in `docs/ASSESSMENT.md` are treated as covered, not presented as new defects.

## Claims the code does not establish

### 1. VERIFIED: a successfully funded offer can be refused on retry because funding emptied the owner's wallet

`checksBeforeSigning` always requires the owner's current balance to cover the entire sale (`link-service/server.mjs:701-714`). `/accept` runs that check again before attempting recovery (`:1141-1143`). It does not inspect the Shed's balance or the bundle nonce.

The relay has a different definition of readiness. It skips a side whose bundle nonce is already consumed (`script/LinkRelay.s.sol:53-56`). After funding succeeds but publication or order posting fails, the service records `failed` and advertises `recovery_available` (`server.mjs:1177-1198`). An owner who originally held exactly the sale amount now has zero. Retrying fails with 409 before reaching the relay's skip.

**Smallest execution.** The service harness below executes the real `/accept` handler with a persisted failed attempt, available wrapper, live offer, and owner balance zero. It returns `409`, with `this side must hold 100 ... before it can fund its Shed`. The fixture does not execute token transfers; the already-funded path and nonce skip are READ. This is distinct from the historical regression whose fixture retained a sufficient owner balance.

**Missing condition and cost.** Retry currently requires the taker to retain another full sale amount in their wallet, even when funding already happened. Recovery can be blocked with tokens in the Shed. Replenishment, withdrawal, or an external submission is needed; the advertised retry alone is insufficient.

### 2. VERIFIED: a posted order can remain `settling` after expiry, with no service transition to recovery

Expiry is considered only when `offer.orderUid` is absent (`link-service/server.mjs:563-568`). Once it exists, every result short of all settlement evidence becomes `settling` (`:570-584`), including an expired order. Acceptance refuses any stored UID unconditionally (`:1117`). Withdrawal returns `moved: true` without changing the lifecycle (`:1042-1082`).

**Smallest execution.** Calling the real `status` function with an old `validTo`, an order UID, available wrapper, and an orderbook response `{status:'expired'}` returns `settling`. The same no-success branch covers orderbook cancellation, an unknown order, and a missing receipt, although those conditions have different recovery needs.

The cancellation plan is also fixed at creation with the offer's original duration (`script/LinkCompute.s.sol:111-124`). After its deadline the Shed refuses it (`lib/cow-shed/src/LibAuthenticatedHooks.sol:24-26`); GET cancellation simply returns that old plan (`server.mjs:979-985`). Thus cancellation is not a general service-provided exit for an already expired posted order.

**Cost.** The UI can wait for a settlement that can no longer occur. Funds can require withdrawal while the status continues to say `settling`. This does not contradict the already-reviewed strict requirements for reporting `settled`; it identifies a missing failure transition.

### 3. VERIFIED: the page constructs the wrong Safe signing domain

The service says a Safe's domain carries its version (`link-service/server.mjs:726-728`). The page builds `EIP712Domain(name='Safe', version=VERSION(), chainId, verifyingContract)` for every contract owner (`link-service/page.mjs:678-693`). The vendored Safe 1.4.1 instead uses `EIP712Domain(uint256 chainId,address verifyingContract)` (`lib/composable-cow/lib/safe/contracts/Safe.sol:47-52`). Its fallback handler validates against `safe.domainSeparator()` (`lib/composable-cow/lib/safe/contracts/handler/extensible/SignatureVerifierMuxer.sol:154-166`).

**Smallest execution.** `test_reviewPageSafeDomainDoesNotMatchSafe` deploys the same Safe fixture as the repository, signs a Shed bundle using the page's domain, and observes `ShedBundle.validSignature == false`. Signing the same message using the Safe's actual domain yields `true`. The test passed. This is an actual Safe signature check, not a browser fixture that merely inspects a requested JSON shape.

**Missing condition and cost.** A wallet must produce the signature the Safe really validates. Signing the page's typed data literally fails. The page also assumes that every contract owner uses SafeMessage; ERC-1271 alone does not establish that assumption. Safe users can reach a prompt that produces an unusable signature. A live wallet connector that transforms the request was not tested.

### 4. VERIFIED: two successful signature submissions can lose one party's signature

The handler loads the offer before awaiting the request body (`link-service/server.mjs:903`, `:1088`). Each request then modifies its own snapshot and replaces the entire JSON file (`:1109-1111`, `:106-110`). Atomic file replacement prevents partial JSON, but does not merge concurrent updates. The acceptance lock protects `/accept`, not `/signature`.

**Smallest execution.** Starting maker and taker `/signature` requests together against an unsigned offer, then delivering both bodies, produces `200,200`; the stored offer contains only `taker`. The service harness executes the actual request handler with signature verification stubbed successful. No second service process is needed.

**Cost.** A party is told its signature was saved, but the offer returns to a state needing that signature again. The normal page sequences maker before taker (`link-service/page.mjs:343`), which reduces exposure in that flow; the API and multiple open clients do not enforce that ordering. This is separate from the already-covered concurrent acceptance lock.

### 5. VERIFIED: contract-owner support imposes signature lengths that the Shed does not require

The comments say a contract account decides what signature it accepts (`link-service/server.mjs:382-384`, `:717-720`). `verifies` and `signatureProblem` reject fewer than 65 bytes before asking the account (`:354`, `:387-390`). `signatureProblem` also caps signatures at 4096 bytes. Withdrawal has a different rule again: exactly 65 bytes (`:1046-1047`).

**Smallest executions.** A real Shed accepted a one-byte `0x01` signature from a small ERC-1271 owner in `test_shortContractSignatureIsValidOnShed`. The real service function rejects that same signature shape before ERC-1271. A 130-byte withdrawal request returns `400`, `signature must be 65 bytes, r || s || v`, before reading a withdrawal plan. Both checks passed. The vendored Safe handler itself also has an empty-signature approved-message branch (`SignatureVerifierMuxer.sol:161-163`).

**Cost.** Some otherwise valid contract owners cannot sign through the service. A multi-owner Safe whose normal trade signature is accepted can still be unable to use the service's withdrawal path. This is a service limitation, not a loss of the owner's direct control over its Shed.

### 6. VERIFIED: the builder's prices fail for representable amounts that the wrapper accepts

`PrivateTradeBuilder.clearingPrices` chooses `[buyAmount,sellAmount]` (`src/libraries/PrivateTradeBuilder.sol:61-68`). `PrivateTradeLib.isReciprocal` uses full-precision `Math.mulDiv` (`src/libraries/PrivateTradeLib.sol:114-115`). GPv2 first multiplies amounts by prices in uint256 arithmetic (`lib/cow-contracts/src/contracts/GPv2Settlement.sol:368-370`, `:389-391`). The structural validator imposes no product bound (`src/PrivateTradeWrapper.sol:267-275`).

**Smallest execution.** Both amounts equal `2**128`. Reciprocity returns true for the builder's equal `2**128` prices. The full wrapper-to-GPv2 call reverts with arithmetic panic `0x11` in the locally compiled dependency. The identical authorised pair settles with prices `[1,1]`. `test_builderPricesOverflowActualSettlement` passed with both assertions.

**Missing condition and cost.** The builder requires `sellAmount * buyAmount <= type(uint256).max` for GPv2's products. The full-precision predicate does not establish this. Large-denomination offers can be constructed and funded but cannot settle using the supplied builder output. This is a failed settlement, not an incorrect transfer. Error encoding can differ for separately deployed older-compiler GPv2 bytecode; the bounded-product requirement remains.

### 7. VERIFIED/READ: pre-signing readiness and relay readiness disagree

The broad promise at `link-service/server.mjs:639-644` is not established. `checksBeforeSigning` checks structural wrapper data, the wrapper's solver seat, offer state, wall-clock expiry, and this side's owner balance. `validateWrapperData` performs only `_validateTerms`, not the complete settlement check (`src/PrivateTradeWrapper.sol:124-127`).

**Executed discrepancies.** With an approve-funded side and allowance zero, `ready.ok` is true. Conversely, with a permit-capable token and adequate standing approval, `/signature` still demands a permit signature (`server.mjs:1099-1104`), whereas the relay deliberately skips permits when allowance suffices (`script/LinkRelay.s.sol:81-82`). The harness returns `400` for that redundant-permit case. The normal approve page waits for allowance before its signing prompt (`page.mjs:554-569`); the API does not enforce that page behavior.

**READ omissions.** At acceptance only the taker balance is rechecked (`server.mjs:1141`). Maker balance changes, used permit nonces, and existing Shed authorisation/funding state are not compared. An unreadable solver seat or balance is recorded as `ok: true` (`:684-686`, `:713-714`). The incoming submitter's solver seat is not checked, although `CowWrapper.wrappedSettle` requires it (`src/vendor/CowWrapper.sol:154-156`).

**Cost and boundary.** Known prerequisites can still be discovered after prompts; some already-satisfied prerequisites cause redundant prompts. Dry run is correctly before broadcast by default (`server.mjs:212-223`), but it simulates `LinkRelay`, not settlement, and `RELAY_DRY_RUN=0` bypasses this explicit extra pass. It is a snapshot of chain state, not a reservation. A balance change after simulation can still invalidate a later broadcast. `LinkRelay.run` issues separate maker/taker broadcasts (`script/LinkRelay.s.sol:37-40`); those funding transactions are not one atomic settlement.

### 8. VERIFIED: a transient RPC failure permanently selects the wrong owner path in that process

`hasCode` caches `true` when `cast code` fails and never refreshes the entry (`link-service/server.mjs:145-158`). The assumption that one read suffices (`:140-144`) therefore holds only if that first read succeeds and code presence remains stable.

**Smallest execution.** First code lookup throws an RPC error; the next available response is `0x`. Both `hasCode` calls return true and the second call performs no RPC read. The service harness passed this assertion.

**Cost.** A temporary RPC failure routes an EOA into approval, ERC-1271 verification, and the page's contract-account signing path until service restart. A conservative temporary classification has become a permanent false fact.

### 9. VERIFIED/READ: matching owner-kind branches is not matching Shed authentication

The literal branch claim holds: both `ShedBundle.validSignature` and `LibAuthenticatedHooks.authenticateHooks` test `owner.code.length > 0` (`src/libraries/ShedBundle.sol:304`, `lib/cow-shed/src/LibAuthenticatedHooks.sol:43`). The stronger suggestion that the precheck predicts execution has conditions.

**VERIFIED.** `ShedBundle.recover` changes `v < 27` to `v + 27` (`ShedBundle.sol:287`). The actual Shed passes v unchanged to Solady recovery (`LibAuthenticatedHooks.sol:49-50`). An ordinary signed bundle encoded with `v-27` returns true from the helper but is refused by the real factory/Shed call. `test_precheckAcceptsV01ButActualShedRefuses` passed. Separately, the helper checks a signature, not expiry or nonce; the Shed checks the deadline at `LibAuthenticatedHooks.sol:39`.

**READ.** Digest construction reads the factory implementation's version (`ShedBundle.sol:155-168`, `:218`), but an existing Shed can change its implementation independently (`lib/cow-shed/src/COWShedProxy.sol:24-29`). Actual Shed authentication uses its executing implementation's version (`lib/cow-shed/src/COWShed.sol:152-155`). The claimed version source is correct only while those versions match.

**Cost.** A valid local precheck can be followed by a failed relay. An independently upgraded Shed can be given consistently wrong signing data. No upgraded-proxy execution was run.

### 10. VERIFIED/READ: proposal recovery and commitment comments describe stronger APIs than implemented

**VERIFIED malformed signature.** `PrivateTradeProposal.recover` says malformed signatures return zero (`src/libraries/PrivateTradeProposal.sol:84`). Only wrong length returns zero; a 65-byte malformed signature calls reverting OpenZeppelin `ECDSA.recover` (`:86-87`). `new bytes(65)` reverts with `ECDSA: invalid signature` in `test_malformed65ByteProposalRevertsInsteadOfReturningZero`. The wrapper's named `PrivateTrade_ProposalBadSignature` branch does not classify this case (`src/PrivateTradeWrapper.sol:250-251`). Cost is an inaccurate error contract for callers and diagnostics.

**READ commitment scope.** `termsHash` commits to `(offerId,taker,wrapper)` (`PrivateTradeProposal.sol:68-69`), and proposal expiry is also signed (`:76-81`). The offer ID contains the maker offer fields (`PrivateTradeLib.sol:21-34`), not either beneficiary. AppData, authorisation payloads, token-array layout, and price representation are also outside this commitment. Thus “no other valid execution of the same pair exists” (`PrivateTradeProposal.sol:27-31`) and “signs the settlement” (`PrivateTradeWrapper.sol:227`) are too broad. Parties' conditional-order data separately binds their terms, and the wrapper separately checks the settlement. Cost is treating pair attribution as exact-payload attribution when maintaining BYOS integration, not an observed wrong settlement.

An empty proposal signature intentionally skips all proposal checks, including its wrapper, terms hash, and expiry (`PrivateTradeWrapper.sol:238`). Ordinary trade validation still runs. Permissionless transport additionally needs an allowlisted submitter contract; unsigned does not bypass `CowWrapper`'s caller check.

## Edge cases

| Case | Verdict and evidence |
| --- | --- |
| Taker equals maker; “SelfTaker” | **VERIFIED/READ, refused.** `PrivateTradeWrapper.sol:273` rejects equality; the baseline `test_validateWrapperDataRejectsSelfTaker` passed. `SelfTaker` is the existing test's name, not a separate type found in the scoped code. The authoriser is maker-first at `PrivateTradeAuthoriser.sol:77-78`, but cannot make such terms settle. |
| Same order twice | **VERIFIED, refused.** `test_sameOrderTwiceRefused` returns `PrivateTrade_OrderMismatch(1)`. Distinct tokens, mirrored directions, and ordered owner checks establish two distinct orders (`PrivateTradeWrapper.sol:267-273`, `:347-371`). |
| Duplicate token-array entries and indices | **READ, supported conditionally.** Repeated addresses are allowed. Each index must be in range and resolve to the expected token; each leg uses its own prices (`PrivateTradeWrapper.sol:329-338`, `:354-362`, `:376-382`). Reusing the same index for a trade's sell and buy cannot match the required distinct tokens. The historical independent-price regression is not re-derived here. |
| Zero clearing prices | **VERIFIED/READ, used zeros refused.** `isReciprocal` returns false for any zero price used by either leg (`PrivateTradeLib.sol:105-106`); wrapper maps this to `PrivateTrade_NotReciprocal`. Unused token entries may have zero prices because neither trade reads them. |
| Equal clearing prices | **VERIFIED.** With positive equal prices, equal raw-unit amounts pass; unequal amounts do not. The full large-amount settlement with unit prices also passed. Equality of prices is not itself invalid. |
| Reciprocity rounding | **VERIFIED, exact integer result is not the full GPv2 limit-price check.** For amounts `(1,1)` and per-leg prices `(1,2,1,2)`, both ceiling results are 1, so `isReciprocal` returns true; real settlement rejects `GPv2: limit price not respected`. `test_roundingPredicateTrueButLimitPriceFails` passed. GPv2 requires the unrounded product inequality too (`GPv2Settlement.sol:368-370`). This narrows the helper's meaning; no incorrect fill occurred. Shared two-entry prices with positive amounts satisfying both GPv2 limits require equality of the two products. |
| Type-limit amounts | **VERIFIED.** Equal uint256-max amounts pass reciprocity and settle through the real wrapper/GPv2 fixture with unit prices (`test_uintMaxAmountsSettleWithUnitPrices`). Full `2**128` execution distinguishes overflowing builder prices from working unit prices, as finding 6 shows. |
| Expiry type limit | **READ.** `LinkCompute.s.sol:342` casts `block.timestamp + validFor` to uint32, while bundle deadlines remain uint256 (`:139`). The API does not bound `validFor` (`server.mjs:861`). Beyond uint32 range the order expiry truncates, so requested duration and computed expiry can disagree. Cost is a wrong expiry or unusable offer. |
| Shed owned by a contract | **VERIFIED for on-chain Safe/EOA fixtures; conditional in the service.** The baseline owner tests pass real Safe-owned settlement and beneficiary checks. Approval routing and ERC-1271 querying exist (`server.mjs:600-617`, `:356-365`). Findings 3, 5, 8, and 9 delimit the claim. |
| Empty proposal signature | **READ, intentionally accepted as unsigned.** `PrivateTradeProposal.sol:92-93`, `PrivateTradeWrapper.sol:238`. No sub-solver attribution check is performed; all ordinary trade checks remain. |
| Permit deadline already past | **READ.** Normal LinkCompute output gives permit/bundle deadlines and order expiry the same timestamp before uint32 truncation (`LinkCompute.s.sol:139`, `:153`, `:342`). Thus ordinary expired offers are rejected by pre-signing expiry checks, subject to host/chain clock agreement. Signature recovery itself does not check time. A token permit failure is tolerated only if allowance is sufficient afterward (`LinkRelay.s.sol:103-116`); unused expired hook bundles are still refused by the Shed. An already-used hook nonce is skipped before permit handling (`:54`). |
| Balance changes between precheck and relay | **READ.** No balance is reserved. Taker balance is reread at acceptance; maker balance is not. The relay dry run can catch changes already present in its snapshot, but cannot establish future inclusion-state balances. A successful funding transaction followed by later failure leads to the recovery problem in finding 1. |
| Cancellation/expiry and watch-tower polling | **VERIFIED/READ.** For correctly encoded inputs, correct owner, valid taker, and empty offchain input, unavailable or expired offers return `PollNever` (`PrivateTradeOrder.sol:84-96`); baseline cancelled/expired tests pass. Non-empty input and malformed/incorrect-role data can fail earlier. Consumed offers also hit `PollNever`. Actual watch-tower pruning was not run. |

### Requested claims that hold

| Area | Result |
| --- | --- |
| Published pair window | **VERIFIED/READ.** Wrapper validates before setting transient offer/taker (`PrivateTradeWrapper.sol:169-199`), refuses a second window (`:141`), and clears after settlement (`:207-216`). Handler checks supplied settlement sender, hash, active offer, active taker, role, and order (`PrivateTradeOrder.sol:69-72`, `:109-154`). Baseline direct-outside-window tests pass. The sender is the forwarded `sender` argument, not handler `msg.sender`; the ComposableCoW integration supplies that context. |
| Exactly two mirrored, full, fee-free orders; zero interactions; right owners | **VERIFIED/READ.** Shape, all interaction phases, common appData, extracted flags/order fields, full amounts, and EIP-1271 owner prefixes are checked at `PrivateTradeWrapper.sol:333-371`. Last-wrapper requirement plus direct forwarding preserves checked calldata (`:135`, `src/vendor/CowWrapper.sol:189-196`). Successful GPv2 execution adds its own limit/overflow constraints. |
| Single-use, filled records, cancelled refusal | **VERIFIED/READ.** Single-use and cancellation are prior-covered properties; this pass found no new discrepancy. Durable state checks are at `PrivateTradeWrapper.sol:187-195`. UIDs use order hash, own owner, and uint32 expiry (`:397-405`); both records are read before and required to increase afterward (`:183-185`, `:211-215`). Exact increments rely on the validated fill-or-kill orders and real GPv2 execution, not on an equality check in `_close` itself. |
| Non-empty offchain input | **VERIFIED.** Both handler entry points refuse it (`PrivateTradeOrder.sol:64`, `:84`); baseline handler tests pass. |
| Authoriser context and beneficiary | **VERIFIED/READ.** On the expected Shed, delegatecall makes `address(this)` the Shed; its self-call to `admin()` returns its owner (`PrivateTradeAuthoriser.sol:64-70`, `COWShedProxy.sol:39-47`). Derived side and beneficiary equality are checked before creation. The proxy condition is self-caller identity, not detection of the delegatecall opcode. A plain call to this authoriser does not acquire a Shed's identity. This is a property in the specified Shed context, not a generic proof that every possible delegatecaller is a canonical Shed. |
| Mirror construction and field equality | **READ, holds.** Tokens and amounts swap; each receiver is its own beneficiary; flags/expiry/appData agree (`PrivateTradeLib.sol:38-73`). Equality covers all 12 GPv2 order fields (`:77-82`). No additional discrepancy found. |
| Sub-solver verification and unsigned submission | **READ, holds within finding 10's scope.** Nonempty proposal validates wrapper, expiry, terms commitment, and recovered identity (`PrivateTradeWrapper.sol:238-254`). There is no expected-signer allowlist; the recovered signer is the attribution identity. Unsigned submission deliberately skips this layer. |
| Service settlement evidence and acceptance lock | **VERIFIED/READ, prior-covered properties hold.** `settled` requires fulfilled order, successful receipt, and consumed wrapper (`server.mjs:570-583`). In-flight acceptance is refused within one process (`:1125-1127`), with release in `finally` (`:1200`). Multi-process exclusion is expressly not promised (`:1124`). The new signature lost update concerns a different route. |
| Relay simulation before broadcast | **VERIFIED/READ, conditional.** Existing regression fixture confirms dry-run failure prevents broadcast; code sequence is `server.mjs:212-223`. The stated opt-out and snapshot/relay-only boundaries in finding 7 apply. |

## State machines

### Service lifecycle

These are derived statuses over JSON fields and chain/orderbook reads, not an enforced transition enum. Apart from `cancelledAt`, `settled` and `cancelled` are not saved phases. The following describes current paths, including missing ones.

| State | Entry code | Defined exits and gaps |
| --- | --- | --- |
| `open` | Create persists empty signatures (`server.mjs:874-884`); `status` returns open until both signatures exist (`:566`). | `/signature` can lead to `signed`; `/accept` can proceed using the submitted taker signature; expiry and on-chain cancellation override. A single maker signature still shows open. |
| `signed` | Both signatures present and no acceptance phase (`:566`); writes at `:1109-1111`. | Acceptance to funding, expiry, or cancellation. Lost updates can erase a signature despite successful responses (finding 4). |
| `expired` | Host-clock comparison only without an order UID (`:564-567`). | No renew/recompute endpoint. Acceptance fails readiness. Withdrawal is possible but does not change status. The precomputed cancellation bundle also expires. This is a terminal offer, though wallet recovery may remain necessary. |
| `funding` | Acceptance sets and saves it (`:1162-1165`). | Relay success to funded, caught failure to failed/recovery, or expiry/cancellation through status. Restart does not reconcile an abandoned funding phase; the fixture confirms it remains funding without a running request. Manual retry is the only continuation and may hit finding 1. |
| `funded` | Relay returns and service saves (`:1177-1178`). | Publish to published or caught failure to recovery. A crash after funds moved but before this save can leave funding instead. No startup reconciliation. |
| `published` | Atomic solver-file rename then save (`:1180-1186`). | Successful POST to settling; failure to recovery. A successful remote POST with lost response/local save can leave an order on the book without a stored UID. `postOrder` treats non-2xx, including duplicate responses, as errors (`:453-461`); no lookup/adoption path exists. This is READ, not an executed lost-response test. |
| `recovery_available` | Failed acceptance maps to this status (`:566-567`); catch also returns it (`:1194-1198`). | Retry returns to funding only if all current early checks pass, including the inappropriate owner balance check. Withdrawal does not advance phase. Expiry/cancellation overrides it. The catch's immediate response can say recovery while a following GET says expired/cancelled. |
| `settling` | UID/acceptedAt/phase saved (`:1188-1191`); status selects this for any UID lacking complete settlement evidence (`:575`). | Can become settled or on-chain cancelled. No expired/rejected-order recovery transition, and accept refuses UID-bearing offers. It can persist permanently after expiry (finding 2). |
| `settled` | Derived fulfilled order + transaction + successful receipt + consumed wrapper (`:570-583`). | Logically terminal. A later missing/unavailable evidence read can make status return settling again because no terminal snapshot is persisted. Historical reorg/evidence-loss behavior was not executed. |
| `cancelled` | Successful signed cancellation script; file removed and timestamp saved (`:1004-1021`). Subsequent status is determined by wrapper state (`:561-562`). | Wrapper cancellation is terminal. Direct on-chain cancellation is also observed. `cancelledAt` alone is not used if the RPC later becomes unavailable. |

**Cross-path disagreements.** Service retry checks owner balances while relay retry checks consumed nonces. Status expiry applies before publication of a UID but not after it. Permit requirements follow token capability in the API but current allowance in the relay. Host time is used by the service, while contracts use block time. At exact `validTo`, contracts allow equality (`PrivateTradeWrapper.sol:327`; `PrivateTradeOrder.sol:96`), readiness requires strictly later expiry (`server.mjs:698`), and status uses a different strict comparison (`:564`). No code synchronises those clocks.

### Wrapper lifecycle

| Transition | Code and result |
| --- | --- |
| Implicit initial `Available` | Enum zero value and mapping default (`src/interfaces/IPrivateTrade.sol:15-18`, `PrivateTradeWrapper.sol:85`). This does not prove an offer was registered, valid, authorised, or funded. |
| `Available → Consumed` | `_open` after validation and fill snapshots (`PrivateTradeWrapper.sol:166-195`), before publishing the window and executing GPv2. A subsequent revert rolls back both state and settlement effects. |
| `Available → Cancelled` | `cancelOffer`, only from `offer.maker` (`:105-114`). It does not require the offer to be unexpired. |
| `Cancelled → Cancelled` | Idempotent return (`:111`). Settlement refuses it (`:191`). |
| `Consumed` terminal | Settlement refuses repeat (`:188-190`); cancellation refuses (`:110`). There is no reset to Available. |

**READ conclusion.** These are intentional terminal states, not a stuck intermediate state. Expiry is a validation condition rather than a stored wrapper state; an expired offer can remain Available in storage. During the active settlement the state already reads Consumed; signature `verify` uses the published window and does not call the off-chain generator's unavailable-state check. No new wrapper transition discrepancy was established.

## Overstated comments

The scan covered first-party `src`, `link-service/server.mjs`, and `docs/DESIGN.md`, then followed relevant scripts, page code, and vendored implementations. Rows below give the unsupported part, its actual boundary, and its cost. Previously reviewed properties are not new findings here.

| Claim and location | Evidence, correction, cost |
| --- | --- |
| “Everything that can be known before a party signs” (`server.mjs:639-644`); “cannot drift from the on-chain rules” (`:18-19`). | **VERIFIED/READ.** Findings 1, 3, 6, 7, and 9 show that structural validation, service readiness, and actual execution are different predicates. Costs are wasted prompts or blocked execution. |
| Contract account produces “whatever its own ERC-1271 implementation accepts” (`server.mjs:382-384`, `:719-720`). | **VERIFIED.** Length limits and withdrawal's 65-byte rule contradict this; finding 5. |
| “A party's owner never changes kind, so one read is enough” (`server.mjs:144`). | **VERIFIED/READ.** A failed first read is cached as fact; finding 8. Even without code changes this rationale is insufficient. |
| “A Safe's domain carries its own version” (`server.mjs:726`; `page.mjs:685-687`). | **VERIFIED.** False for the vendored Safe; finding 3. |
| “safe to retry” relay (`server.mjs:180`) read as a service-wide property. | **VERIFIED/READ.** The nonce-aware relay is retryable, but acceptance can refuse to call it after funding; finding 1. |
| “no other valid execution of the same pair exists” (`PrivateTradeProposal.sol:31`); “signs the settlement” (`PrivateTradeWrapper.sol:227`). | **READ.** Commitment excludes representations and beneficiaries; finding 10. Different price scales can describe the same economic execution. Exact calldata attribution is not established. |
| “Returns address(0) for a malformed signature” (`PrivateTradeProposal.sol:84`). | **VERIFIED.** Malformed 65-byte input reverts; finding 10. |
| “Branches exactly as the Shed does” (`ShedBundle.sol:292`). | **READ, literal branch claim holds. VERIFIED, stronger acceptance-equivalence reading does not.** v normalization differs; finding 9. |
| Version read “from the deployed implementation” (`ShedBundle.sol:161`). | **READ.** Specifically the factory implementation, not necessarily the existing proxy's implementation; finding 9. |
| “only this offer can spend” the standing DAI allowance (`server.mjs:634`). | **READ.** Allowance is keyed by token owner and Shed spender, with no offer identifier (`:602`, `:622-635`). Later owner-authorised Shed operations can use remaining allowance. Cost is overstating the scope of an ordinary standing approval. No new allowance scenario was executed. |
| “There is no orderbook” and orders “never become public” (`docs/DESIGN.md:116`, `:131`). | **READ.** Current service posts the taker order to `/api/v1/orders` (`server.mjs:453-460`, `:1188`). Document describes a different transport architecture. Cost is incorrect integration expectations. |
| “caller can only ever cause a private trade ... to execute, and cannot cause anything else” (`src/PrivateTradeSubmitter.sol:23-24`). | **READ.** The public `relayBundles` method intentionally authorises/funds without settling (`:46-52`). Narrow that statement to completed settlement validation. Cost is misunderstanding the public API's intermediate effects. |
| “exactly two tokens and two trades” (`src/interfaces/IPrivateTrade.sol:66`). | **READ.** Exactly two trades, at least two token entries; wrapper explicitly permits duplicated token entries (`PrivateTradeWrapper.sol:329-338`). Cost is writing a client against the wrong shape. |
| `wrapperData` documented as a two-field tuple (`PrivateTradeWrapper.sol:123`). | **READ.** Decoder requires a third Proposal field (`:125-126`). Cost is a client encoding that fails ABI decoding. |
| Generator “Mirrors verify” (`PrivateTradeOrder.sol:76`). | **READ.** Generator is deliberately usable outside the window, returns appData zero, and does not check allowedTaker or all structural terms (`:84-98` versus `:109-158`). It is an order-construction/polling helper, not equivalent validation. Cost is treating a generated order as executable proof. |

Comments that accurately describe offchain-input rejection, mirror fields, equality, owner prefixes, zero interactions, last-wrapper forwarding, and transient storage have no additional discrepancy to report. Transient storage prevents cross-transaction persistence, not an omitted clear within the same transaction; current code explicitly clears it. Stale replay-error rationale in proposal comments was noticed but is not re-derived as a new single-use finding.

## What I could not establish

**Execution record.** `forge test` passed 88 tests with two skipped environment-dependent tests. `bash docs/review/run-counterexamples.sh` passed its syntax checks, two contract regressions, service checks, 15 lifecycle checks, and 10 browser checks. Eight new isolated Solidity checks plus the separate Safe-domain check passed. The Node fixture executed actual service functions and request handlers with controlled RPC/Forge/orderbook responses; it does not prove live broadcasts or a real RPC race.

**Live boundary.** Read-only probes returned chain ID `0x1` and orderbook version HTTP 200. I did not run `scripts/link-service-e2e.sh`: it kills the solver and service and removes their stores (`:99-107`), conflicting with the instruction to leave the running stack unchanged. No live settlement, wallet connector, process crash, lost HTTP response, or upgraded-Shed scenario was executed in this review. Those conclusions remain READ where stated. No SUSPECTED finding is promoted as a defect.

**Scope.** No transfer with wrong agreed amounts was observed, and no new discrepancy was found in the already-reviewed single-use/cancellation/settlement-evidence properties. Third-party BYOS operational attribution, watch-tower behavior, and unusual token transfer semantics were not established by these local tests.

### Reproducing the new checks without changing tracked files

The executed fixtures were kept under `/tmp`. Their complete sources follow so the evidence does not depend on those temporary files surviving. From the repository root, prepare a temporary copy, save the two Solidity blocks under its `test` directory, and save the Node block anywhere outside the repository.

```sh
review_dir=$(mktemp -d /tmp/private-orders-correctness.XXXXXX)
cp -R src test "$review_dir/"
cp foundry.toml "$review_dir/"
ln -s "$PWD/lib" "$review_dir/lib"
# Save the Solidity blocks as test/Correctness.t.sol and test/CorrectnessSafe.t.sol there.
forge test --root "$review_dir" --match-contract '^CorrectnessTest$' -vv
forge test --root "$review_dir" --match-test test_reviewPageSafeDomainDoesNotMatchSafe -vv
# Save the Node block as /tmp/private-orders-correctness-service.mjs.
node /tmp/private-orders-correctness-service.mjs
```

Expected Solidity summaries are `8 passed; 0 failed` and `1 passed; 0 failed`. Expected Node observations include `expired posted order => settling`, funded retry `409`, contract withdrawal `400`, and concurrent signature submissions `200,200; stored roles: taker`.

<details>
<summary>Solidity arithmetic, signature, and shape checks</summary>

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;
import {PrivateTradeTestBase} from "./utils/PrivateTradeTestBase.sol";
import {PrivateTradeTerms,PrivateTradeRole,PrivateTrade_BadTaker,PrivateTrade_OrderMismatch,PrivateTrade_NotReciprocal} from "../src/interfaces/IPrivateTrade.sol";
import {PrivateTradeLib} from "../src/libraries/PrivateTradeLib.sol";
import {PrivateTradeBuilder} from "../src/libraries/PrivateTradeBuilder.sol";
import {PrivateTradeProposal} from "../src/libraries/PrivateTradeProposal.sol";
import {ShedBundle} from "../src/libraries/ShedBundle.sol";
import {IConditionalOrder} from "composable-cow/interfaces/IConditionalOrder.sol";
import {GPv2Trade} from "cowprotocol/contracts/libraries/GPv2Trade.sol";
import {IERC20} from "cowprotocol/contracts/interfaces/IERC20.sol";
import {Call} from "cow-shed/ICOWAuthHook.sol";
import {COWShed} from "cow-shed/COWShed.sol";
import {COWShedFactory} from "cow-shed/COWShedFactory.sol";
import {LibAuthenticatedHooks} from "cow-shed/LibAuthenticatedHooks.sol";
contract CorrectnessTest is PrivateTradeTestBase {
 function recoverProposal(PrivateTradeProposal.Proposal memory p) external view returns(address) { return PrivateTradeProposal.recover(p,address(wrapper)); }
 function test_malformed65ByteProposalRevertsInsteadOfReturningZero() public {
  PrivateTradeProposal.Proposal memory p; p.signature=new bytes(65);
  vm.expectRevert(bytes("ECDSA: invalid signature")); this.recoverProposal(p);
 }
 function test_precheckAcceptsV01ButActualShedRefuses() public {
  COWShedFactory f=new COWShedFactory(address(new COWShed()));
  (address owner,uint256 pk)=makeAddrAndKey("signature-owner");
  ShedBundle.Bundle memory b=ShedBundle.Bundle(owner,f.proxyOf(owner),new Call[](0),bytes32(uint256(1)),block.timestamp+100);
  (uint8 v,bytes32 r,bytes32 s)=vm.sign(pk,ShedBundle.digest(b,address(f)));
  bytes memory sig=abi.encodePacked(r,s,v-27);
  assertTrue(ShedBundle.validSignature(b,address(f),sig));
  vm.expectRevert(); f.executeHooks(b.calls,b.nonce,b.deadline,b.owner,sig);
 }
 function test_shortContractSignatureIsValidOnShed() public {
  COWShedFactory f=new COWShedFactory(address(new COWShed()));
  address owner=address(new ShortSignatureOwner());
  ShedBundle.Bundle memory b=ShedBundle.Bundle(owner,f.proxyOf(owner),new Call[](0),bytes32(uint256(1)),block.timestamp+100);
  assertTrue(ShedBundle.validSignature(b,address(f),hex"01"));
  f.executeHooks(b.calls,b.nonce,b.deadline,b.owner,hex"01");
 }
 function test_builderPricesOverflowActualSettlement() public {
  PrivateTradeTerms memory t=_terms(address(bob)); t.offer.sellAmount=2**128; t.offer.buyAmount=2**128;
  assertTrue(PrivateTradeLib.isReciprocal(t,2**128,2**128));
  _fundAndApprove(t);
  IConditionalOrder.ConditionalOrderParams memory m=_authorize(alice,PrivateTradeRole.Maker,t,"m");
  IConditionalOrder.ConditionalOrderParams memory k=_authorize(bob,PrivateTradeRole.Taker,t,"t");
  bytes memory data=_settleDataWith(_tokens(),PrivateTradeBuilder.clearingPrices(t),_trades(t,m,k),_emptyInteractions());
  vm.prank(solver); vm.expectRevert(abi.encodeWithSignature("Panic(uint256)",0x11)); wrapper.wrappedSettle(data,_chainedWrapperData(t));
  uint256[] memory prices=new uint256[](2); prices[0]=1; prices[1]=1;
  data=_settleDataWith(_tokens(),prices,_trades(t,m,k),_emptyInteractions());
  vm.prank(solver); wrapper.wrappedSettle(data,_chainedWrapperData(t));
  assertEq(usdc.balanceOf(bobOwner),2**128);
 }
 function test_roundingPredicateTrueButLimitPriceFails() public {
  PrivateTradeTerms memory t=_terms(address(bob)); t.offer.sellAmount=1; t.offer.buyAmount=1;
  assertTrue(PrivateTradeLib.isReciprocal(t,1,2,1,2));
  _fundAndApprove(t);
  IConditionalOrder.ConditionalOrderParams memory m=_authorize(alice,PrivateTradeRole.Maker,t,"m");
  IConditionalOrder.ConditionalOrderParams memory k=_authorize(bob,PrivateTradeRole.Taker,t,"t");
  GPv2Trade.Data[] memory trades=_trades(t,m,k); trades[1].sellTokenIndex=2;trades[1].buyTokenIndex=3;
  IERC20[] memory tokens=new IERC20[](4);tokens[0]=IERC20(address(usdc));tokens[1]=IERC20(address(wbtc));tokens[2]=tokens[1];tokens[3]=tokens[0];
  uint256[] memory p=new uint256[](4);p[0]=1;p[1]=2;p[2]=1;p[3]=2;
  bytes memory data=_settleDataWith(tokens,p,trades,_emptyInteractions());
  vm.prank(solver);vm.expectRevert(bytes("GPv2: limit price not respected"));wrapper.wrappedSettle(data,_chainedWrapperData(t));
 }
 function test_sameOrderTwiceRefused() public {
  PrivateTradeTerms memory t=_terms(address(bob));
  GPv2Trade.Data[] memory trades=_trades(t,_params(PrivateTradeRole.Maker,t,"m"),_params(PrivateTradeRole.Taker,t,"t"));trades[1]=trades[0];
  bytes memory data=_settleDataWith(_tokens(),_clearingPrices(),trades,_emptyInteractions());
  vm.prank(solver);vm.expectRevert(abi.encodeWithSelector(PrivateTrade_OrderMismatch.selector,1));wrapper.wrappedSettle(data,_chainedWrapperData(t));
 }
 function test_zeroPriceRefusedAndEqualPriceWorksForEqualAmounts() public view {
  PrivateTradeTerms memory t=_terms(address(bob));t.offer.sellAmount=1;t.offer.buyAmount=1;
  assertFalse(PrivateTradeLib.isReciprocal(t,0,1));assertTrue(PrivateTradeLib.isReciprocal(t,1,1));
 }
 function test_uintMaxAmountsSettleWithUnitPrices() public {
  PrivateTradeTerms memory t=_terms(address(bob));t.offer.sellAmount=type(uint256).max;t.offer.buyAmount=type(uint256).max;
  assertTrue(PrivateTradeLib.isReciprocal(t,1,1));
  _fundAndApprove(t);
  IConditionalOrder.ConditionalOrderParams memory m=_authorize(alice,PrivateTradeRole.Maker,t,"m");
  IConditionalOrder.ConditionalOrderParams memory k=_authorize(bob,PrivateTradeRole.Taker,t,"t");
  uint256[] memory prices=new uint256[](2);prices[0]=1;prices[1]=1;
  bytes memory data=_settleDataWith(_tokens(),prices,_trades(t,m,k),_emptyInteractions());
  vm.prank(solver);wrapper.wrappedSettle(data,_chainedWrapperData(t));
  assertEq(usdc.balanceOf(bobOwner),type(uint256).max);
 }
}
contract ShortSignatureOwner {
 function isValidSignature(bytes32,bytes calldata signature) external pure returns(bytes4) {return keccak256(signature)==keccak256(hex"01")?bytes4(0x1626ba7e):bytes4(0xffffffff);}
}
```

</details>

<details>
<summary>Safe domain check</summary>

```solidity
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;
import {PrivateTradeOwnersTest} from "./PrivateTradeOwners.t.sol";
import {ShedBundle} from "../src/libraries/ShedBundle.sol";
import {Call} from "cow-shed/ICOWAuthHook.sol";
import {Safe} from "safe/Safe.sol";
contract CorrectnessSafeTest is PrivateTradeOwnersTest {
 function test_reviewPageSafeDomainDoesNotMatchSafe() public {
  Party memory p=_safeParty("page-safe");
  ShedBundle.Bundle memory b=ShedBundle.Bundle(p.owner,p.shed,new Call[](0),bytes32(uint256(1)),block.timestamp+100);
  bytes32 digest=ShedBundle.digest(b,address(factory));
  bytes32 pageDomain=keccak256(abi.encode(keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),keccak256("Safe"),keccak256(bytes(Safe(payable(p.owner)).VERSION())),block.chainid,p.owner));
  assertNotEq(pageDomain,Safe(payable(p.owner)).domainSeparator());
  bytes32 messageHash=keccak256(abi.encode(SAFE_MSG_TYPE_HASH,keccak256(abi.encode(digest))));
  bytes32 pageDigest=keccak256(abi.encodePacked(hex"1901",pageDomain,messageHash));
  (uint8 v,bytes32 r,bytes32 s)=vm.sign(p.pk,pageDigest);
  assertFalse(ShedBundle.validSignature(b,address(factory),abi.encodePacked(r,s,v)));
  (v,r,s)=vm.sign(p.pk,_safeMessageHash(p.owner,digest));
  assertTrue(ShedBundle.validSignature(b,address(factory),abi.encodePacked(r,s,v)));
 }
}
```

</details>

<details>
<summary>Service state and request-handler checks</summary>

```javascript
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
const root=process.cwd(), store=fs.mkdtempSync('/tmp/private-orders-service-');
const addr=n=>'0x'+String(n).repeat(40), sig='0x'+'11'.repeat(65);
let callback, allowance='0', balance='100', code='0x', wrapperState='0', orderState='expired', failCode=false, codeReads=0;
const casts=[];
const execFileSync=(bin,args)=>{
 casts.push(args);
 if(bin==='forge') return Buffer.from('bundles relayed');
 if(args[0]==='code'){codeReads++;if(failCode)throw Error('RPC unavailable');return code;}
 const method=args[2]??'';
 if(method.startsWith('balanceOf'))return balance;
 if(method.startsWith('allowance'))return allowance;
 if(method.startsWith('offerState'))return wrapperState;
 if(method.startsWith('AUTHENTICATOR'))return addr(8);
 if(method.startsWith('isSolver'))return 'true';
 if(method.startsWith('isValidSignature'))return '0x1626ba7e';
 return '';
};
const ctx={fs,path,crypto,execFileSync,spawnSync:()=>({status:0}),http:{createServer:fn=>{callback=fn;return {listen(){}}}},process:{env:{PRIVATE_TRADE_ROOT:store,PRIVATE_TRADE_WRAPPER:addr(9)},pid:process.pid},console,URL,Buffer,Date,fetch:async()=>({ok:true,json:async()=>({status:orderState})}),render(){},renderCreate(){}};
let source=fs.readFileSync(path.join(root,'link-service/server.mjs'),'utf8').replace(/^import .*;\n/gm,'').replaceAll('import.meta.dirname',JSON.stringify(path.join(root,'link-service')));
source+='\nglobalThis.api={status,checksBeforeSigning,signatureProblem,verifies,hasCode,funding,saveOffer,codeCache};';
vm.runInNewContext(source,ctx); const api=ctx.api;
const side={owner:addr(1),shed:addr(3),sellToken:addr(5),sellAmount:'100',deadline:Math.floor(Date.now()/1000)+3600,permitKind:'none',permitTypedDataAvailable:false,digest:'0x'+'22'.repeat(32),bundleTypedData:{}};
const fresh=()=>({id:'review',computed:{wrapper:addr(9),wrapperData:'0x',offerId:'0x'+'33'.repeat(32),validTo:Math.floor(Date.now()/1000)+3600,maker:addr(2),makerBundle:{...side,owner:addr(2)},takerBundle:{...side},takerOrder:{}},request:{taker:addr(1)},signatures:{maker:sig,taker:sig},permits:{}});
const request=async(url,body)=>{
 const req=new EventEmitter();req.method='POST';req.url=url;
 let response;const res={writeHead(status){this.status=status;return this},end(text){response={status:this.status,body:JSON.parse(text)};return this}};
 const pending=callback(req,res);req.emit('data',JSON.stringify(body));req.emit('end');await pending;return response;
};
let offer=fresh();offer.orderUid='uid';offer.computed.validTo=1;
let s=await api.status(offer);assert.equal(s.status,'settling');console.log('expired posted order =>',s.status);
offer=fresh();offer.acceptance={phase:'failed',error:'orderbook unavailable'};balance='0';
let ready=api.checksBeforeSigning(offer,'taker');assert.equal(ready.ok,false);api.saveOffer(offer);
let res=await request('/offers/review/accept',{});assert.equal(res.status,409);console.log('retry after funds moved to Shed =>',res.status,res.body.problems[0]);
balance='100';offer=fresh();ready=api.checksBeforeSigning(offer,'taker');assert.equal(ready.ok,true);console.log('zero approval => ready.ok',ready.ok);
api.codeCache.clear();code='0x6000';assert.equal(api.verifies({owner:addr(1),digest:side.digest,signature:'0x01'}),null);console.log('ERC-1271 1-byte blob =>',api.signatureProblem(addr(1),'0x01'));
api.saveOffer(fresh());res=await request('/offers/review/withdraw',{address:addr(1),signature:'0x'+'11'.repeat(130)});assert.equal(res.status,400);console.log('130-byte contract withdrawal signature =>',res.status,res.body.error);
api.codeCache.clear();failCode=true;assert.equal(api.hasCode(addr(1)),true);failCode=false;code='0x';const before=codeReads;assert.equal(api.hasCode(addr(1)),true);assert.equal(codeReads,before);console.log('one failed code read, then healthy EOA RPC => cached contract classification; no retry');
api.codeCache.clear();offer=fresh();offer.acceptance={phase:'funding'};s=await api.status(offer);assert.equal(s.status,'funding');console.log('persisted funding phase without a running request =>',s.status);
api.codeCache.clear();code='0x';balance='100';offer=fresh();offer.signatures={};api.saveOffer(offer);
const both=await Promise.all([request('/offers/review/signature',{role:'maker',signature:sig}),request('/offers/review/signature',{role:'taker',signature:sig})]);
assert.equal(both[0].status,200);assert.equal(both[1].status,200);
const stored=JSON.parse(fs.readFileSync(path.join(store,'out-json/link/review.json'),'utf8'));
assert.equal(Object.keys(stored.signatures).length,1);console.log('concurrent maker+taker signature POSTs => 200,200; stored roles:',Object.keys(stored.signatures).join(','));
offer=fresh();offer.computed.makerBundle.permitKind='eip2612';offer.computed.makerBundle.permitTypedDataAvailable=true;offer.computed.makerBundle.permitTypedData={};allowance='100';api.saveOffer(offer);
res=await request('/offers/review/signature',{role:'maker',signature:sig});assert.equal(res.status,400);console.log('existing adequate approval on permit token, no permit signature =>',res.status,res.body.error);
fs.rmSync(store,{recursive:true,force:true});
```

</details>
