# Non-standard ERC-20 behavior: does the design handle it?

Scope: whether `PrivateTradeWrapper` + the settlement + the shed funding path tolerate the four
well-known non-standard ERC-20 behaviors, and where the assumptions live. All line refs are to the
repo as of this analysis.

## The token path, end to end

For each party the sell token moves twice and the buy token moves once:

| Step | Call (who calls whom) | Allowance consumed | Where |
|------|----------------------|--------------------|-------|
| 1. Fund | `sellToken.transferFrom(ownerEOA → shed, sellAmount)` | `allowance[owner][shed]` | shed bundle, `LinkCompute._calls` call #1 (`allowFailure:false`) |
| 2. Approve | `sellToken.approve(vaultRelayer, sellAmount)` (by the Shed) | sets `allowance[shed][vaultRelayer]` | shed bundle, `LinkCompute._calls` call #2 (`allowFailure:false`) |
| 3. Sell leg | `sellToken.transferFrom(shed → vault, executedSellAmount)` via `vaultRelayer.transferFromAccounts` | `allowance[shed][vaultRelayer]` | `GPv2Settlement.settle` → `GPv2Transfer.transferFromAccounts` |
| 4. Buy leg | `buyToken.transfer(vault → beneficiary, executedBuyAmount)` via `vault.transferToAccounts` | none (vault holds it) | `GPv2Settlement.settle` → `GPv2Transfer.transferToAccounts` |

Fixed order facts (`PrivateTradeLib.makerOrder`/`takerOrder`, `src/libraries/PrivateTradeLib.sol:45-84`):
`feeAmount: 0`, `partiallyFillable: false` (fill-or-kill), `sellTokenBalance: BALANCE_ERC20`,
`buyTokenBalance: BALANCE_ERC20`. Because the fee is 0 and the order is FOK and the wrapper forces
`executedAmount == sellAmount` (`PrivateTradeWrapper._validateSettlement`), the sell leg moves
**exactly** the approved `sellAmount`, and the buy leg moves **exactly** the agreed `buyAmount`
(`isReciprocal` enforces the ceiling-division lands on the agreed number).

Two bookkeeping facts that matter below:
- `filledAmount[orderUid]` is written **before** any token moves — inside
  `computeTradeExecution` (`GPv2Settlement.sol:421`), which runs during `computeTradeExecutions`,
  i.e. before `vaultRelayer.transferFromAccounts`. It is derived from the *validated* order data
  (limit price, FOK, executed amount), not from the actual `transferFrom`/`transfer` results.
- `GPv2SafeERC20.safeTransfer/safeTransferFrom` (`lib/cow-contracts/src/contracts/libraries/GPv2SafeERC20.sol`)
  reverts if the `call` fails, and `getLastTransferResult` treats: **0-byte return → success**,
  **32-byte non-zero → success**, **32-byte zero (`false`) → revert "failed transfer(From)"**,
  **any other size → revert "malformed transfer result"**.

---

## Behavior 1 — callback re-entering the wrapper or settlement mid-`settle`

**Handled. Three independent layers, and the ordering works in the design's favor.**

The sell-token `transferFrom` and buy-token `transfer` callbacks execute *inside* `settle`,
after `computeTradeExecutions` (which already wrote `filledAmount` and already ran the order
handlers' `verify`) and before `settle` returns. A malicious token that wants to win has to
influence one of three things: the order handlers' `verify`, the `filledAmount` values, or the
wrapper's active window.

1. **Re-entering `settle` is impossible.** `settle` is `nonReentrant`
   (`GPv2Settlement.sol:126`, `ReentrancyGuard`). A token cannot call `settle` a second time from
   its callback.
2. **The wrapper window is transient and re-entry-guarded.** The window
   (`_activeOfferId`, `_activeTaker`) is `transient` (`PrivateTradeWrapper.sol:79-86`), set in
   `_open` and cleared in `_close`. `_wrap` reverts `PrivateTrade_Reentered` if
   `_activeOfferId != 0` at entry (`:145`). A token callback that tries to re-enter
   `wrappedSettle` finds the window already open and reverts. (It would also trip `NotASolver`,
   since a token is not an authenticated solver, but the transient guard is the one that matters.)
   Transient is per-transaction, which is exactly the guarantee wanted: the window cannot be
   observed or extended from any other transaction.
3. **The order handlers' `verify` is `view` and only callable by the settlement.**
   `PrivateTradeOrder.verify` requires `sender == SETTLEMENT` (`_requireSettlementCaller`,
   `PrivateTradeOrder.sol:111`). A token's callback has `msg.sender` = the token/vault/relayer, so
   it cannot invoke `verify` with `sender == SETTLEMENT`. And `verify` reads the window (a
   `view` read of transient) — it writes nothing, so even a direct read gives the token no lever.

Crucially, `verify` runs **before** the token callbacks (it is part of
`computeTradeExecutions`), so a token cannot observe the window *and then* act: by the time the
token's `transferFrom` runs, the orders have already been validated against the window that is
guaranteed (by 1 and 2) to stay put for the rest of the transaction.

A malicious token still controls its own `transferFrom`/`transfer` *result* — but that is
behaviors 3 and 4, not re-entry. If it reverts or misbehaves, the whole `settle` reverts and the
wrapper's `_close` fill-check never runs; nothing is recorded and the offer state write is rolled
back (atomic).

---

## Behavior 2 — buy token with an on-transfer fee (Binance-PEP / fee-on-transfer style)

**NOT handled. A fee-on-transfer *buy* token breaks the trade, and the break is on the seller's
side.** This is the one behavior with real teeth.

The settlement pays the buy leg out of the vault at the **exact** `executedBuyAmount`
(`GPv2Transfer.transferToAccounts` → `safeTransfer(receiver, executedBuyAmount)`), which
`isReciprocal` has pinned to the agreed `buyAmount`. If the buy token is fee-on-transfer, the
receiver gets `buyAmount * (1 - fee)` — the party is shorted by the fee on every fill.

What the design does *not* do:
- No fee/decimals/tax-rate inspection anywhere (`TokenPermit` probes `permit`/`DOMAIN_SEPARATOR`/
  `name`/`version` only).
- No post-settlement balance assertion. The wrapper's `_close` only re-reads `filledAmount`
  (`PrivateTradeWrapper.sol:216-231`), which is bookkeeping written *before* the transfers and
  never reflects what the receiver actually received. So the "did the trade happen" check is
  satisfied even though the party was underpaid.
- The GPv2 limit-price check is on the *order* amounts, not on delivery, so it does not catch this
  either.

Why the seller is the one hurt, not the buyer: the taker's *sell* token is the maker's *buy*
token. If that token is fee-on-transfer, the taker's proceeds (maker's buy leg) arrive short;
`filledAmount[takerUid]` still shows a full fill, the offer is consumed, and the taker was shorted
with no on-chain recourse.

Mitigations that exist: off-chain, `checksBeforeSigning` confirms the side holds enough sell
balance, but nothing checks delivery of the *buy* token. This is an accepted limitation unless a
token allowlist or a delivery assertion is added.

---

## Behavior 3 — transfer returns no value, or `false`

**Handled for the no-return case; correctly rejected for the `false` case.**

`GPv2SafeERC20.getLastTransferResult` is the whole story (`GPv2SafeERC20.sol:56-110`):
- **`transfer`/`transferFrom` returns nothing (0 bytes):** treated as success (as long as it is a
  contract). This is the standard handling for "non-standard" tokens like USDT, whose
  `transfer`/`transferFrom` return no value on success. **Works.**
- **Returns `false` (32 zero bytes):** `safeTransfer/safeTransferFrom` reverts with
  `GPv2: failed transfer(From)`. So a token that returns `false` on a legitimate transfer is
  **correctly rejected** — the settlement reverts rather than silently recording a phantom fill.
  This is the safe direction: a `false` means the token itself says the transfer did not happen,
  and the design refuses to treat it as a fill.
- **Malformed return (any other size):** reverts `malformed transfer result`. Also safe.

Because the settlement reverts on `false`, the wrapper's `filledAmount`-increased check in `_close`
is not the thing saving the design here — the `SafeERC20` wrapper is. The `filledAmount` check is
a second, independent guard against a bundle that *returns without delivering* (e.g. a settlement
that accepted the calldata but recorded nothing). Both are needed and both are present.

---

## Behavior 4 — USDT-style `approve` (reverts on non-zero → non-zero)

**Handled, but only structurally — there is no explicit "set allowance to zero first" guard.** The
safety is an invariant the design happens to maintain, and it is worth stating precisely because
it is the most fragile of the four.

The approve that matters is the Shed's `approve(vaultRelayer, sellAmount)`
(`LinkCompute._calls` call #2, `allowFailure:false`). USDT reverts that approve if
`allowance[shed][vaultRelayer]` is non-zero. The design keeps that allowance at **exactly zero at
the start of every approve** by three facts that must all hold:

1. **The Shed's only source of `allowance[shed][vaultRelayer]` is the bundle's own approve.** No
   other code path writes that pair. So at the first trade it is 0.
2. **Each settlement consumes the allowance completely.** The sell leg moves exactly `sellAmount`
   (`feeAmount:0` ⇒ `executedSellAmount == sellAmount`, FOK + `executedAmount == sellAmount`), and
   the spender is exactly `vaultRelayer`, the same address the approve set. A standard ERC-20
   `transferFrom` decrements the allowance by the moved amount, so after a full fill the allowance
   is back to 0.
3. **Trades are serialized per (Shed, token, spender).** Each settlement is its own transaction;
   by the time the next one's approve runs, the previous allowance is 0.

When the invariant holds, the USDT approve succeeds every time (it is always a 0 → non-zero
approve). If any one of the three facts breaks, the *next* settlement of that token reverts at the
approve (`allowFailure:false`), i.e. the trade fails cleanly rather than silently mis-approving:

- If `feeAmount` ever became non-zero, the sell leg would move `sellAmount + fee`, exceeding the
  approved `sellAmount` and reverting at `transferFrom` (insufficient allowance) — so fee 0 is load
  bearing, not incidental.
- If the order were partially fillable, a partial fill would leave a residual allowance, and the
  next USDT approve would revert. FOK is load bearing too.
- The funding path (permit/approve for `owner → shed`) writes a *different* allowance pair and
  never touches `allowance[shed][vaultRelayer]`, so it does not interfere.

Recommendation (low severity, hardening): this is currently an implicit invariant. If the project
wants USDT support to be *explicit* rather than *incidental*, the settle bundle could first
`approve(vaultRelayer, 0)` (allowFailure:true, harmless on standard tokens, USDT-safe) before the
real approve. As written, nothing does this, and nothing needs to — but the dependency on
`feeAmount:0` + FOK + single-spender is worth a comment and a test.

---

## Summary table

| # | Behavior | Handled? | Mechanism |
|---|----------|----------|-----------|
| 1 | Callback re-entry mid-`settle` | **Yes** | settlement `nonReentrant` + wrapper transient window re-entry guard + `verify` is `view` & settlement-only; `verify` runs before token callbacks |
| 2 | Fee-on-transfer buy token | **No** | no fee/decimals check, no delivery assertion; `filledAmount` is pre-transfer bookkeeping so the party is shorted with the offer still consumed |
| 3 | `transfer` returns nothing / `false` | **Yes** | `GPv2SafeERC20`: 0-byte ⇒ success, `false` ⇒ revert, malformed ⇒ revert (correctly refuses phantom fills) |
| 4 | USDT non-zero `approve` | **Yes (structurally)** | allowance is always 0 at approve time because of fee 0 + FOK + single spender; no explicit zero-approve guard — fragile invariant |

## Suggested next steps

- **Behavior 2 is the only genuine gap.** Decide whether fee-on-transfer buy tokens are in scope.
  If yes, add a delivery assertion in `_close` (receiver balance delta) or a token allowlist; if
  no, document it as a supported-token restriction.
- **Behavior 4:** add a regression test that settles the *same* Shed + token + spender twice
  (USDT mock) to pin the invariant, and a comment in `LinkCompute` marking `feeAmount:0`/FOK as
  load-bearing for the approve. Optionally emit an `approve(spender, 0)` first for explicitness.
- No non-standard-token mocks exist in `test/` today (only the standard `TestERC20`); a
  `NoReturnToken`, a `FalseToken`, a `FeeOnTransferToken`, and a `USDTApproveToken` would let all
  four behaviors be asserted in isolation.
