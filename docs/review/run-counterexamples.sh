#!/usr/bin/env bash
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
