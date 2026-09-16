# Review of the last three commits (qwen3.8-27b-nvfp4, pve-ai)

Produced by a local 27B model, then independently reproduced by the parent session.
Driver it left behind: /tmp/bleu-race.mjs (uses docs/review/service-harness.mjs).

```
All three questions are now answered, with Q1's race reproduced deterministically against the real server code (via the existing `docs/review/service-harness.mjs`, driver in `/tmp/bleu-race.mjs`, no repo files touched).

## Q1 — lost-update / resurrected writes

**The pure lost-update is fixed** — `saveFresh`/`serialize` (770fcb6) work on their main path: two concurrent maker+taker `/signature` submissions both persist (Test 1 in the driver).

**But the broader "resurrected" race you suspected is real.** I reproduced the accept × cancel interleaving deterministically:

1. Both requests enter; each parks at its body read (the `await` the guards are named after).
2. The **cancel** runs to completion: relays `cancelOffer` on chain, removes the sub-solver feed file, writes `cancelledAt` → `200 {status:'cancelled', relay:'relayed'}`.
3. The **accept** — which entered *before* the cancel and never re-checks — then runs its block: relays both bundles, **republishes the feed file for the already-cancelled offer**, posts the order, and answers `202 {status:'settling', orderUid}`.

Record afterwards: `cancelledAt` **and** `phase:'settling'` **and** `orderUid` simultaneously; the dead offer is back in `out-json/sub-solver-offers/`.

**Fund safety holds:** the wrapper reverts `wrappedSettle` on a cancelled offer (`PrivateTrade_OfferCancelled`, covered by `test_makerWalletCanCancelAvailableOffer`), and `status()` re-reads the chain first (`if (wrapperState === 'cancelled') return ...`). So no money moves — but the service lies in its 202, publishes a stale feed entry the sub-solver will try, and leaves a self-contradictory record.

**Root cause:** accept validates once (pre-`accepting.add`), then its terminal writes (publish, `settling` save) execute a stale "offer is live" snapshot that clobbers cancel's terminal writes. Nothing re-reads chain or record state after the block's internal `await postOrder`.

## Q2 — two concurrent accepts

Guarded, and correctly so: `accepting` is checked and added in one synchronous stretch (409 otherwise), so two in-process accepts can't both relay; the wrapper's consumed flag is the cross-process backstop. No defect.

## Q3 — signature submitted during cancellation

Real but minor: the signature route's checks run before the cancel lands, its `saveFresh` after — so a maker who cancelled can still get `200 {signed:['taker']}` on the dead offer (the taker's prompt was spent on nothing settleable). No state corruption (the save re-reads, so `cancelledAt` survives); the chain is truth and the next action gets a proper 409. Same root cause: no re-validation between check and save across an await.

## Suggested fix (minimal, keeps "no network I/O under the lock")

1. **Accept:** after `await postOrder(...)`, route the terminal write through `saveFresh`'s re-read and refuse on `fresh.cancelledAt`: remove the just-published feed file, don't record `settling`, return 409 ("this offer was cancelled while its order was being posted").
2. **Both routes:** wrap the terminal write stretches (accept: feed publish + `settling` save; cancel: feed `rmSync` + `cancelledAt` save) in `serialize(offer.id, ...)` — they're synchronous, so the lock stays I/O-free, and each side's re-read then sees the other's write.
3. Optional: one `wrapperOfferState` re-check before the publish, which also covers the two-process case.

`/tmp/bleu-race.mjs` is drop-in ready as a regression test in `docs/review/` (it asserts today's broken behavior in Test 2; flip those assertions to the expected 409/no-feed-file after the fix). Want me to apply the fix?
```
