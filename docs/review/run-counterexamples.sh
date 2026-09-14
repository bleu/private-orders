#!/usr/bin/env bash
# Every counterexample from the viability review, plus the lifecycle tests that replaced the two
# service defects it found. Each check fails loudly if the behaviour it pins comes back.
#
#   bash docs/review/run-counterexamples.sh
#
# The contract cases run real local GPv2 code in a temporary copy of src/test. The service cases run
# the real service over HTTP against a fake `forge`/`cast` and a fixture orderbook, so they need no
# chain and no offline stack.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REVIEW_DIR="$(mktemp -d "${TMPDIR:-/tmp}/private-trade-review.XXXXXX")"
trap 'rm -rf "$REVIEW_DIR"' EXIT
cp -R "$ROOT/src" "$ROOT/test" "$REVIEW_DIR/"
cp "$ROOT/foundry.toml" "$REVIEW_DIR/foundry.toml"
ln -s "$ROOT/lib" "$REVIEW_DIR/lib"
cp "$ROOT/docs/review/ReviewCounterexamples.t.sol" "$REVIEW_DIR/test/ReviewCounterexamples.t.sol"
forge test --root "$REVIEW_DIR" --match-contract ReviewCounterexamples -vv
node "$ROOT/docs/review/service-counterexamples.mjs"
node "$ROOT/docs/review/service-lifecycle.mjs"
