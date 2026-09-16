#!/usr/bin/env bash
# Every counterexample from the viability review, plus the checks that replaced the defects it found.
# Each one fails loudly if the behaviour it pins comes back, so this is the release regression gate.
#
#   bash docs/review/run-counterexamples.sh
#
# The contract cases run real local GPv2 code in a temporary copy of src/test. The service and page
# cases run the real service over HTTP against a fake `forge`/`cast` and a fixture orderbook, and the
# page cases drive the real page in headless Chrome. Nothing here broadcasts a transaction or needs a
# chain; the browser checks are skipped only when no Chrome is installed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# The page builds a program inside a template literal, so an unescaped backtick in a comment breaks
# the page and nothing else. This is the cheapest possible way to catch that, so it runs first.
node "$ROOT/scripts/check-page.mjs"

REVIEW_DIR="$(mktemp -d "${TMPDIR:-/tmp}/private-trade-review.XXXXXX")"
trap 'rm -rf "$REVIEW_DIR"' EXIT
# `script` too: a library the tests use lives there, and a missing source is a compile error rather
# than a skipped test.
cp -R "$ROOT/src" "$ROOT/test" "$ROOT/script" "$REVIEW_DIR/"
cp "$ROOT/foundry.toml" "$REVIEW_DIR/foundry.toml"
ln -s "$ROOT/lib" "$REVIEW_DIR/lib"
cp "$ROOT/docs/review/ReviewCounterexamples.t.sol" "$REVIEW_DIR/test/ReviewCounterexamples.t.sol"
forge test --root "$REVIEW_DIR" --match-contract ReviewCounterexamples -vv
node "$ROOT/docs/review/service-counterexamples.mjs"
node "$ROOT/docs/review/service-lifecycle.mjs"
# Two requests in flight at once, which `fetch` cannot produce.
node "$ROOT/docs/review/service-concurrency.mjs"
# Refusals whose value is the sentence, not the status.
node "$ROOT/docs/review/service-guards.mjs"
# The maker cancelling while an acceptance is in flight, in two different windows.
node "$ROOT/docs/review/service-cancellation-race.mjs"
node "$ROOT/docs/review/page-safety.mjs"
