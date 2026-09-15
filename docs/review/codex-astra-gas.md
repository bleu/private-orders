# Gas review

Review of commit `d2b73919cb98bfa3b8e404705205eeee74509c7a`. Performance only. Experiments changed scratch copies, not repository contracts or tests. No commits were made.

The measured combination reduces the settlement test from VERIFIED 1,123,065 gas to VERIFIED 1,116,600 gas, a VERIFIED saving of 6,465 gas. It preserves transient storage and the existing events. The baseline trace attributes VERIFIED 313,153 gas to `wrappedSettle`; the combination uses VERIFIED 306,688 gas in that call.

## Summary table

Every gas value and delta below is VERIFIED by local Forge execution. Deltas are after minus before. Each isolated experiment starts from the baseline, except the explicitly named combination. Rows use different tests where indicated; their savings must not be added together.

| idea | before | after | delta | verdict |
| --- | ---: | ---: | ---: | --- |
| Compare handler calldata directly with terms (settlement) | VERIFIED 1,123,065 | VERIFIED 1,120,416 | VERIFIED -2,649 | Take with parity coverage |
| Reuse validated orders for UIDs (settlement) | VERIFIED 1,123,065 | VERIFIED 1,120,719 | VERIFIED -2,346 | Take |
| Read active offer and taker together (settlement) | VERIFIED 1,123,065 | VERIFIED 1,121,969 | VERIFIED -1,096 | Take |
| Reuse extraction buffers (settlement) | VERIFIED 1,123,065 | VERIFIED 1,122,335 | VERIFIED -730 | Alternative to UID reuse |
| Compare calldata against a constructed order (settlement) | VERIFIED 1,123,065 | VERIFIED 1,122,651 | VERIFIED -414 | Smaller alternative to direct terms |
| Call settlement after last-wrapper validation (settlement) | VERIFIED 1,123,065 | VERIFIED 1,122,691 | VERIFIED -374 | Take |
| Use a fixed expected-order array (settlement) | VERIFIED 1,123,065 | VERIFIED 1,122,930 | VERIFIED -135 | Included in UID reuse |
| Widen offer-state mapping values (settlement) | VERIFIED 1,123,065 | VERIFIED 1,122,975 | VERIFIED -90 | Reject tradeoff |
| Rebuild canonical orders for UIDs (settlement) | VERIFIED 1,123,065 | VERIFIED 1,123,122 | VERIFIED +57 | Reject regression |
| Encode the offer struct directly (settlement) | VERIFIED 1,123,065 | VERIFIED 1,123,472 | VERIFIED +407 | Reject regression |
| Use checked multiplication and ceilDiv (settlement) | VERIFIED 1,123,065 | VERIFIED 1,123,095 | VERIFIED +30 | Reject regression |
| Omit decoded terms from authorisation event (settlement) | VERIFIED 1,123,065 | VERIFIED 1,116,599 | VERIFIED -6,466 | Reject behavior change |
| Check offer state before settlement decoding (cancellation flow) | VERIFIED 1,024,774 | VERIFIED 994,083 | VERIFIED -30,691 | Take for rejected submissions |
| Hash cancellation params locally (cancellation flow) | VERIFIED 1,024,774 | VERIFIED 1,022,981 | VERIFIED -1,793 | Take for preparation only |
| Hash the bundle hash-array in place (owner flow) | VERIFIED 1,108,123 | VERIFIED 1,107,473 | VERIFIED -650 | Optional preparation saving |
| Avoid a duplicate digest for EOA verification (signature checks) | VERIFIED 409,182 | VERIFIED 398,846 | VERIFIED -10,336 | Take for preparation only |
| Reuse the permit domain read (permit flow) | VERIFIED 85,952 | VERIFIED 84,898 | VERIFIED -1,054 | Take for preparation only |
| Combined runtime changes (settlement) | VERIFIED 1,123,065 | VERIFIED 1,116,600 | VERIFIED -6,465 | Measured combination, deployment work required |

### Measurement method and scope

The local tool reports Forge `1.7.1`. The unchanged compiler configuration uses Solidity `0.8.28`, Cancun, the optimizer enabled with `optimizer_runs = 1000`, and `via_ir = false`. These are verified configuration values, not estimated gas figures.

The original checkout had an existing untracked `docs/review/codex-astra-policy.md`. It was left untouched. The baseline and isolated variants are under `/tmp/private-orders-gas.b4Qwnb/`. That directory holds experiment source, runner scripts, and raw logs for this session; it is temporary evidence, not a committed deliverable.

Run these commands in the baseline or the named variant directory. Each section below names its variant.

```sh
forge test --match-test test_settlesWithShedOwnedOrders
forge test --match-test test_makerCancellationAtomicallyRevokesOrderAndOffer
forge test --match-path 'test/PrivateTradeShed.t.sol'
forge test
```

Other table metrics use these exact test names with `forge test --match-test <name>`.

| Metric | Test |
| --- | --- |
| Poll | `test_getTradeableOrderReturnsTheOrderWhileAvailable` |
| Owner flow | `test_eoaOwnedShedSettlesAndPaysItsOwner` |
| Signature checks | `test_bundleSignatureCheckHandlesBothOwnerKinds` |
| EIP-2612 permit flow | `test_eip2612PermitGrantsTheShedAnAllowanceSubmittedByTheRelay` |
| DAI permit flow | `test_daiStylePermitGrantsTheShedAnAllowanceSubmittedByTheRelay` |

The requested settlement test includes minting, deployment of Sheds, bundle construction, signing helpers, authorisation, settlement, and assertions. Its gas is not the price of a standalone settlement transaction. The cancellation test includes initial authorisations, cancellation, and a deliberately rejected settlement after cancellation. `getTradeableOrder` is normally polled off-chain; its test gas is an EVM-work measure, not a user fee.

Additional `-vvvv` runs distinguish nested call costs. Those values have the warmth and state of this test and are not standalone transaction receipts. No production fee, calldata fee, deployment break-even point, or chain-specific estimate is claimed.

## Each idea

### Compare handler calldata directly with terms

Scratch variant `direct_terms`.

In `src/PrivateTradeOrder.sol`, `_requireOrderMatches` reads `order` from calldata and compares it directly with the role-selected fields in `terms`. It checks token addresses, beneficiary, amounts, expiry, the fee, kind, fill mode, and balance modes. It stops allocating a canonical order and copying the supplied order into memory solely for `equal`.

The previous appData comparison compares the supplied appData with itself because `_orderFor` receives `order.appData`. The experiment omits that tautology; the wrapper still checks that both trades agree on appData. `getTradeableOrder` and its canonical construction remain unchanged.

I would take this with explicit comparison-parity coverage when implementing it. The tradeoff is duplicated knowledge of order fields and constants between construction and verification. Existing tests pass except the deployment-address pin; they do not establish exhaustive parity over every possible order.

- `test_settlesWithShedOwnedOrders`. VERIFIED 1,123,065 → VERIFIED 1,120,416 gas; delta VERIFIED -2,649 gas.
- `test_makerCancellationAtomicallyRevokesOrderAndOffer`. VERIFIED 1,024,774 → VERIFIED 1,024,774 gas; delta VERIFIED +0 gas.
- `test_getTradeableOrderReturnsTheOrderWhileAvailable`. VERIFIED 34,406 → VERIFIED 34,406 gas; delta VERIFIED +0 gas.

### Reuse validated orders for UIDs

Scratch variant `reuse_validated_orders`.

In `src/PrivateTradeWrapper.sol`, `_validateSettlement` returns its expected orders as `GPv2Order.Data[2] memory`. `_open` passes that array to `_orderUids`, which hashes those already-validated orders. `_orderUids` no longer extracts the trades again or decodes their flags again. This also incorporates the fixed-array experiment below.

I would take it. The UID is computed from an order whose equality with the submitted trade was just checked. Preserve that ordering and the full equality check. The existing compiler accepts the changed function boundaries without a stack-depth failure. This is preferable to merely rebuilding the canonical orders inside `_orderUids`.

- `test_settlesWithShedOwnedOrders`. VERIFIED 1,123,065 → VERIFIED 1,120,719 gas; delta VERIFIED -2,346 gas.
- `test_makerCancellationAtomicallyRevokesOrderAndOffer`. VERIFIED 1,024,774 → VERIFIED 1,022,448 gas; delta VERIFIED -2,326 gas.

### Read active offer and taker together

Scratch variant `combined_getter`.

In `src/PrivateTradeWrapper.sol`, add `activeTrade() external view returns (bytes32, address)` returning the existing transient values. In `src/PrivateTradeOrder.sol`, `_requireActiveTrade` calls that getter once instead of calling `activeOfferId` and `activeTaker` separately. Keep both existing getters.

I would take it. The scratch handler uses a small local interface for the new getter; an implementation should declare it in the shared interface. The existing checks and their values remain in place. Wrapper and handler must be deployed together. Neither transient slot is removed or made persistent.

The small cancellation regression is measured too; it is not hidden by the settlement saving.

- `test_settlesWithShedOwnedOrders`. VERIFIED 1,123,065 → VERIFIED 1,121,969 gas; delta VERIFIED -1,096 gas.
- `test_makerCancellationAtomicallyRevokesOrderAndOffer`. VERIFIED 1,024,774 → VERIFIED 1,024,797 gas; delta VERIFIED +23 gas.

### Reuse extraction buffers

Scratch variant `reuse_order_buffer`.

In `src/PrivateTradeWrapper.sol`, move `GPv2Order.Data memory order` outside the loop in both `_validateSettlement` and `_orderUids`. Each iteration overwrites the same buffer. `_extractOrder` currently assigns every order field.

This is a measured, smaller alternative to returning validated orders. I would prefer the latter and would not add these savings to it. Buffer reuse depends on every field being overwritten before use and on retaining no reference from a prior iteration.

- `test_settlesWithShedOwnedOrders`. VERIFIED 1,123,065 → VERIFIED 1,122,335 gas; delta VERIFIED -730 gas.
- `test_makerCancellationAtomicallyRevokesOrderAndOffer`. VERIFIED 1,024,774 → VERIFIED 1,024,066 gas; delta VERIFIED -708 gas.

### Compare calldata against a constructed order

Scratch variant `calldata_compare`.

In `src/PrivateTradeOrder.sol`, `_requireOrderMatches` still constructs `_orderFor(...)`, but compares its fields directly with the calldata order rather than passing that calldata order to the memory-based `PrivateTradeLib.equal`.

This avoids one memory copy while retaining canonical order construction. It is a smaller alternative to direct term comparison, with a smaller saving. Both alternatives duplicate the field comparison. I would choose one, not stack them.

- `test_settlesWithShedOwnedOrders`. VERIFIED 1,123,065 → VERIFIED 1,122,651 gas; delta VERIFIED -414 gas.
- `test_makerCancellationAtomicallyRevokesOrderAndOffer`. VERIFIED 1,024,774 → VERIFIED 1,024,774 gas; delta VERIFIED +0 gas.

### Call settlement after last-wrapper validation

Scratch variant `direct_settlement`.

In `src/PrivateTradeWrapper.sol`, `_wrap` replaces `_next(settleData, remainingWrapperData)` with `_callWithBubbleRevert(address(SETTLEMENT), settleData)` after `_open` succeeds.

I would take it. `_wrap` already requires an empty remainder, and `_decodeSettleData` already validates the settlement selector. The inherited `_next` repeats that selector check and branches on the remainder. The change keeps the same low-level call helper and revert propagation, and leaves `src/vendor/CowWrapper.sol` untouched. The dependency on those earlier checks must remain clear.

- `test_settlesWithShedOwnedOrders`. VERIFIED 1,123,065 → VERIFIED 1,122,691 gas; delta VERIFIED -374 gas.
- `test_makerCancellationAtomicallyRevokesOrderAndOffer`. VERIFIED 1,024,774 → VERIFIED 1,024,768 gas; delta VERIFIED -6 gas.

### Use a fixed expected-order array

Scratch variant `fixed_expected`.

In `src/PrivateTradeWrapper.sol`, `_validateSettlement` replaces `GPv2Order.Data[] memory expected = new GPv2Order.Data[](2)` with `GPv2Order.Data[2] memory expected`.

I would take it as part of validated-order reuse. It accurately represents the fixed pair. The isolated result is included to separate the array change from eliminating duplicate extraction. It is not an additional saving on top of the reuse variant.

- `test_settlesWithShedOwnedOrders`. VERIFIED 1,123,065 → VERIFIED 1,122,930 gas; delta VERIFIED -135 gas.
- `test_makerCancellationAtomicallyRevokesOrderAndOffer`. VERIFIED 1,024,774 → VERIFIED 1,024,640 gas; delta VERIFIED -134 gas.

### Widen offer-state mapping values

Scratch variant `wide_state`.

In `src/PrivateTradeWrapper.sol`, store the private mapping values as `uint256`, cast back to `PrivateTradeOfferState` on reads, and cast the named enum values on writes. The external `offerState` return type stays the enum.

I would reject this tradeoff. The small settlement saving comes with a polling regression and weaker internal typing. `forge inspect PrivateTradeWrapper storage-layout` shows `_offerStates` is the only persistent storage declaration. Narrow enum values in separate mapping entries do not pack adjacent offers together. Narrowing token amounts or addresses in terms does not shrink persistent wrapper state because the wrapper does not store those terms.

- `test_settlesWithShedOwnedOrders`. VERIFIED 1,123,065 → VERIFIED 1,122,975 gas; delta VERIFIED -90 gas.
- `test_makerCancellationAtomicallyRevokesOrderAndOffer`. VERIFIED 1,024,774 → VERIFIED 1,024,751 gas; delta VERIFIED -23 gas.
- `test_getTradeableOrderReturnsTheOrderWhileAvailable`. VERIFIED 34,406 → VERIFIED 34,445 gas; delta VERIFIED +39 gas.

### Rebuild canonical orders for UIDs

Scratch variant `canonical_uids`.

In `src/PrivateTradeWrapper.sol`, `_orderUids` calls `PrivateTradeLib.makerOrder` or `takerOrder` instead of `_extractOrder`, retaining its existing loop and UID hashing.

Reject. The measured result costs more. It replaces one reconstruction with another; it does not reuse the objects built during validation.

- `test_settlesWithShedOwnedOrders`. VERIFIED 1,123,065 → VERIFIED 1,123,122 gas; delta VERIFIED +57 gas.
- `test_makerCancellationAtomicallyRevokesOrderAndOffer`. VERIFIED 1,024,774 → VERIFIED 1,024,789 gas; delta VERIFIED +15 gas.

### Encode the offer struct directly

Scratch variant `offer_encode_struct`.

In `src/libraries/PrivateTradeLib.sol`, `offerId` replaces the explicit field list with `keccak256(abi.encode(OFFER_TYPE_HASH, offer))`.

Reject. The offer is a static tuple, and the tests retain the same behavior, but the shorter source costs more in settlement, cancellation, and polling. This is a different experiment from the excluded order-equality hashing experiment.

- `test_settlesWithShedOwnedOrders`. VERIFIED 1,123,065 → VERIFIED 1,123,472 gas; delta VERIFIED +407 gas.
- `test_makerCancellationAtomicallyRevokesOrderAndOffer`. VERIFIED 1,024,774 → VERIFIED 1,025,204 gas; delta VERIFIED +430 gas.
- `test_getTradeableOrderReturnsTheOrderWhileAvailable`. VERIFIED 34,406 → VERIFIED 34,448 gas; delta VERIFIED +42 gas.

### Use checked multiplication and ceilDiv

Scratch variant `ceil_div`.

In `src/libraries/PrivateTradeLib.sol`, `isReciprocal` replaces each rounding-up `Math.mulDiv(amount, sellPrice, buyPrice, Math.Rounding.Up)` with `Math.ceilDiv(amount * sellPrice, buyPrice)` using checked multiplication.

Reject. It costs more on the supplied path and narrows the arithmetic domain because the intermediate product must fit in a machine word. The existing full-precision multiplication can handle products outside that range when the quotient fits. The gas result alone already rejects this change.

- `test_settlesWithShedOwnedOrders`. VERIFIED 1,123,065 → VERIFIED 1,123,095 gas; delta VERIFIED +30 gas.
- `test_makerCancellationAtomicallyRevokesOrderAndOffer`. VERIFIED 1,024,774 → VERIFIED 1,024,804 gas; delta VERIFIED +30 gas.

### Omit decoded terms from authorisation event

Scratch variant `compact_event`.

In `src/PrivateTradeAuthoriser.sol`, `createChecked` emits a compact event with Shed, owner, role, and offer ID instead of emitting `PrivateTradeOrderAuthorised` with the full decoded terms. The scratch event retains indexed Shed, owner, and offer ID.

Reject despite the saving. `test_authorisationEmitsTheDecodedTerms` fails because the event contents are part of the existing behavior. Consumers lose directly decoded terms. The saving is in the authorisation bundles before settlement, not in order verification. It also changes the pinned authoriser address.

- `test_settlesWithShedOwnedOrders`. VERIFIED 1,123,065 → VERIFIED 1,116,599 gas; delta VERIFIED -6,466 gas.
- `test_makerCancellationAtomicallyRevokesOrderAndOffer`. VERIFIED 1,024,774 → VERIFIED 1,018,308 gas; delta VERIFIED -6,466 gas.

### Check offer state before settlement decoding

Scratch variant `early_state`.

In `src/PrivateTradeWrapper.sol`, `_open` moves the existing offer-state read and consumed/cancelled checks immediately after `_validateProposal`, before settlement decoding, order validation, UID construction, and fill reads. It leaves the consumed-state write in its existing position.

I would take this for cheaper rejected submissions if the changed error precedence is acceptable. It does not reduce the successful settlement path.

The trace proves what the cancellation-test delta means. The rejected `wrappedSettle` call drops from VERIFIED 41,520 to VERIFIED 10,829 gas, a VERIFIED saving of 30,691 gas. The actual cancellation bundle remains VERIFIED 71,120 → VERIFIED 71,120 gas, delta VERIFIED 0 gas; `cancelOffer` remains VERIFIED 25,567 → VERIFIED 25,567 gas, delta VERIFIED 0 gas. Do not describe the whole-test reduction as cheaper cancellation execution.

- `test_settlesWithShedOwnedOrders`. VERIFIED 1,123,065 → VERIFIED 1,123,065 gas; delta VERIFIED +0 gas.
- `test_makerCancellationAtomicallyRevokesOrderAndOffer`. VERIFIED 1,024,774 → VERIFIED 994,083 gas; delta VERIFIED -30,691 gas.

### Hash cancellation params locally

Scratch variant `local_cancel_hash`.

In `src/libraries/ShedBundle.sol`, `cancellationCalls` replaces `ComposableCoW(composableCoW).hash(makerParams)` with `keccak256(abi.encode(makerParams))`. The vendored `ComposableCoW.hash` uses that exact expression.

I would take it for cheaper cancellation preparation. It removes a pure external call while building the bundle, not a call from the signed execution bundle. Keep the hash definition aligned with ComposableCoW.

The cancellation trace confirms unchanged execution. The cancellation `executeHooks` call is VERIFIED 71,120 → VERIFIED 71,120 gas, delta VERIFIED 0 gas. `cancelOffer` is VERIFIED 25,567 → VERIFIED 25,567 gas, delta VERIFIED 0 gas. A service computing this off-chain saves EVM simulation work, not transaction gas.

- `test_settlesWithShedOwnedOrders`. VERIFIED 1,123,065 → VERIFIED 1,123,065 gas; delta VERIFIED +0 gas.
- `test_makerCancellationAtomicallyRevokesOrderAndOffer`. VERIFIED 1,024,774 → VERIFIED 1,022,981 gas; delta VERIFIED -1,793 gas.

### Hash the bundle hash-array in place

Scratch variant `hash_array`.

In `src/libraries/ShedBundle.sol`, `structHash` hashes the contiguous contents of the existing `bytes32[] hashes` array in place instead of first allocating `abi.encodePacked(hashes)`.

The replacement is:

```solidity
bytes32 callsHash;
assembly ("memory-safe") {
    callsHash := keccak256(add(hashes, 0x20), mul(mload(hashes), 0x20))
}
return keccak256(abi.encode(EXECUTE_HOOKS_TYPE_HASH, callsHash, nonce, deadline));
```

Optional. This adds assembly and assumes the memory layout of a word array. It saves digest-construction work in scripts or EVM-based service computation. It does not change the Shed implementation that verifies and executes the signed bundle.

The requested Shed test uses its own `_executeHooksDigest` helper, so its unchanged result does not measure this library. The owner-flow and signature-check tests do call the library and show the saving. Their deltas include multiple helper invocations and are not per-digest prices.

- `test_eoaOwnedShedSettlesAndPaysItsOwner`. VERIFIED 1,108,123 → VERIFIED 1,107,473 gas; delta VERIFIED -650 gas.
- `test_bundleSignatureCheckHandlesBothOwnerKinds`. VERIFIED 409,182 → VERIFIED 405,292 gas; delta VERIFIED -3,890 gas.
- `test_settlesWithShedOwnedOrders`. VERIFIED 1,123,065 → VERIFIED 1,123,065 gas; delta VERIFIED +0 gas.
- `test_makerCancellationAtomicallyRevokesOrderAndOffer`. VERIFIED 1,024,774 → VERIFIED 1,024,774 gas; delta VERIFIED +0 gas.

### Avoid a duplicate digest for EOA verification

Scratch variant `eoa_digest`.

In `src/libraries/ShedBundle.sol`, `validSignature` moves `digest(bundle_, shedFactory)` inside the contract-owner branch. The EOA branch still calls `recover`, which computes the digest itself. This removes a redundant digest computation for that branch.

I would take it. The existing test checks both owner kinds, and the full baseline suite remains passing. This is a script/service preflight saving. The normal execution path through `PrivateTradeSubmitter` and `PrivateTradeSubmission.relayBundles` does not call `validSignature`. It is not a saving in the Shed's signature-verification implementation.

- `test_bundleSignatureCheckHandlesBothOwnerKinds`. VERIFIED 409,182 → VERIFIED 398,846 gas; delta VERIFIED -10,336 gas.
- `test_settlesWithShedOwnedOrders`. VERIFIED 1,123,065 → VERIFIED 1,123,065 gas; delta VERIFIED +0 gas.
- `test_makerCancellationAtomicallyRevokesOrderAndOffer`. VERIFIED 1,024,774 → VERIFIED 1,024,774 gas; delta VERIFIED +0 gas.

### Reuse the permit domain read

Scratch variant `permit_domain`.

In `src/libraries/TokenPermit.sol`, `build` reads `domainSeparator(token)` once, stores it in the permit, and supplies it to a private `_kind(token, separator)` helper. Public library helper `kind(token)` keeps its existing behavior by reading the separator and delegating to `_kind`.

I would take it. EIP-2612 and DAI-style permit tests both improve while the full suite remains passing. The savings are in permit discovery and construction. The token's submitted `permit` calldata and its execution are unchanged. Off-chain service computation does not turn this reduction into user-paid gas savings.

- `test_eip2612PermitGrantsTheShedAnAllowanceSubmittedByTheRelay`. VERIFIED 85,952 → VERIFIED 84,898 gas; delta VERIFIED -1,054 gas.
- `test_daiStylePermitGrantsTheShedAnAllowanceSubmittedByTheRelay`. VERIFIED 87,105 → VERIFIED 86,148 gas; delta VERIFIED -957 gas.
- `test_settlesWithShedOwnedOrders`. VERIFIED 1,123,065 → VERIFIED 1,123,065 gas; delta VERIFIED +0 gas.
- `test_makerCancellationAtomicallyRevokesOrderAndOffer`. VERIFIED 1,024,774 → VERIFIED 1,024,774 gas; delta VERIFIED +0 gas.

### Combined runtime changes

Scratch variant `combined_runtime`.

This combines direct term comparison, reuse of validated orders for UIDs, the combined active-context getter, and the direct settlement call. The fixed array is included within validated-order reuse, not as an additional optimisation. The combination excludes early state rejection, buffer reuse, wider state, compact events, and all preparation-only changes. It does not include the previously measured immutable domain separator.

I would use this as the measured implementation candidate, subject to the per-change maintainability costs above. It is an actual scratch build and run, not a sum assumed to compose.

The nested `wrappedSettle` trace falls from VERIFIED 313,153 to VERIFIED 306,688 gas, delta VERIFIED -6,465 gas. Funding-bundle calls remain VERIFIED 368,404 → VERIFIED 368,404 gas and VERIFIED 360,973 → VERIFIED 360,973 gas, both delta VERIFIED 0 gas.

Cancellation execution slightly regresses. Its `executeHooks` call changes from VERIFIED 71,120 to VERIFIED 71,143 gas, delta VERIFIED +23 gas. `cancelOffer` changes from VERIFIED 25,567 to VERIFIED 25,590 gas, delta VERIFIED +23 gas. The lower cancellation test total primarily reflects its later rejected settlement, not a cheaper cancellation bundle.

- `test_settlesWithShedOwnedOrders`. VERIFIED 1,123,065 → VERIFIED 1,116,600 gas; delta VERIFIED -6,465 gas.
- `test_makerCancellationAtomicallyRevokesOrderAndOffer`. VERIFIED 1,024,774 → VERIFIED 1,022,465 gas; delta VERIFIED -2,309 gas.
- `test_getTradeableOrderReturnsTheOrderWhileAvailable`. VERIFIED 34,406 → VERIFIED 34,406 gas; delta VERIFIED +0 gas.

### Maintenance-path coverage

The requested `forge test --match-path 'test/PrivateTradeShed.t.sol'` passed with VERIFIED 8 tests on the baseline. It contains cancellation and standing-allowance coverage but no withdrawal execution test. The passing-path results below come from those existing tests, with combined-build values also observed in the full suite.

| Existing test | Baseline gas | Combined runtime gas | Delta |
| --- | ---: | ---: | ---: |
| `test_settlesWithShedOwnedOrders` | VERIFIED 1,123,065 | VERIFIED 1,116,600 | VERIFIED -6,465 |
| `test_makerCancellationAtomicallyRevokesOrderAndOffer` | VERIFIED 1,024,774 | VERIFIED 1,022,465 | VERIFIED -2,309 |
| `test_standingAllowanceNeedsNoApproveInTheBundle` | VERIFIED 1,170,718 | VERIFIED 1,164,253 | VERIFIED -6,465 |

The standing-allowance test includes establishing the standing allowance in the same test. Its total cannot establish the marginal price of authorising a later trade with an allowance already in place.

### Correctness checks and deployment impact

Baseline `forge test` completed with VERIFIED 88 passing tests, VERIFIED 0 failing tests, and VERIFIED 2 skipped tests. All measured variants compiled after correcting a misplaced inherited documentation tag in the new getter experiment.

The local cancellation hash, in-place bundle hash, EOA digest, and permit-domain variants each retained VERIFIED 88 passing tests, VERIFIED 0 failing tests, and VERIFIED 2 skipped tests.

Every other isolated variant except the compact event had VERIFIED 87 passing tests, VERIFIED 1 failing test, and VERIFIED 2 skipped tests. The failure was `test_addressesArePinned`. The combined runtime build had that same result. Code changes alter deterministic deployment addresses; the tests were deliberately not repinned or disabled to hide this. Implementation requires reviewing the new deployment addresses and their consumers.

The compact event had VERIFIED 86 passing tests, VERIFIED 2 failing tests, and VERIFIED 2 skipped tests. It failed both the address pin and `test_authorisationEmitsTheDecodedTerms`. This is an explicit reason to reject it, not just deployment bookkeeping.

## Ideas I could not measure

No savings are assigned to these items, and none is recommended as a measured optimisation.

- A calldata-native settlement decoder. `_decodeSettleData` materialises tokens, prices, trades, signatures, and interaction arrays. Avoiding those copies would require carefully maintaining ABI bounds and the existing accepted input shapes. No complete candidate was implemented or measured.
- Withdrawal execution. `script/Withdraw.s.sol` constructs transfer calls, reads balances, prepares typed data, and relays signed hooks. No existing withdrawal test was found in the requested suites. Digest results above do not establish a withdrawal transaction saving.
- Custom-error or revert-string changes. The main successful paths already use custom errors. Polling uses the protocol's `PollNever(string)` response. No compatible rewrite was measured, so there is no claimed saving.
- Removing `_filled` calls, offer lifecycle state, or transient-window clearing. These enforce documented behavior. No behavior-preserving replacement was measured. The transient window was kept throughout; `docs/DESIGN.md` explains why a future missing clear must not persist into later transactions.
- Changes to typed-data JSON construction, withdrawal balance discovery, or the stateless submitter's memory forwarding. No before/after experiment was completed for those paths. The measured permit and digest changes are narrower preparation optimisations.

## What I could not establish

The suite does not establish live per-transaction cost, cold-state cost for an already deployed production system, L2 data charges, production token behavior, or deployment-cost amortisation. The skipped fork tests were not enabled. No fees in currency or estimated savings are reported.

Full tests provide bounded behavioral evidence, not exhaustive equivalence. In particular, direct term comparison duplicates canonical-order knowledge, and early state rejection changes which error occurs first when several inputs are invalid. Those need deliberate acceptance during implementation.

The prior immutable domain-separator experiment and whole-order equality-hash experiment were excluded as requested. Their supplied figures were not remeasured or relabeled VERIFIED here. One explanation in the prompt does not match this checkout: `GPv2Order.Data.kind`, `sellTokenBalance`, and `buyTokenBalance` are Solidity `bytes32` fields containing hashes, not dynamic Solidity strings. The EIP-712 type declares them as strings. This correction does not reverse the supplied rejection of the equality-hash rewrite.

The report is the only repository file created by this review. All code modifications and generated test/build artifacts for the experiments remained in the scratch directory. No implementation, deployment, repinning, or commit was performed.
