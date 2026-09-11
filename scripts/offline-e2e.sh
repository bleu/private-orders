#!/usr/bin/env bash
# Runs the offline end-to-end check against a live `bleu/cow-offline-mode` stack.
#
#   ./scripts/offline-e2e.sh [rpc-url]
#
# Requires the stack to be up. See docs/OFFLINE.md for the startup sequence.
set -euo pipefail

RPC="${1:-http://localhost:8545}"
ORDERBOOK="${ORDERBOOK_URL:-http://localhost:8080}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> waiting for anvil at ${RPC}"
for _ in $(seq 1 60); do
  if cast block-number --rpc-url "${RPC}" >/dev/null 2>&1; then break; fi
  sleep 2
done
block=$(cast block-number --rpc-url "${RPC}")
echo "    block ${block}"

echo "==> checking settlement is deployed at the canonical address"
code=$(cast code 0x9008D19f58AAbD9eD0D60971565AA8510560ab41 --rpc-url "${RPC}")
if [ "${#code}" -lt 3 ]; then
  echo "    GPv2Settlement has no code at 0x9008...ab41" >&2
  exit 1
fi

if curl -fsS "${ORDERBOOK}/api/v1/version" >/dev/null 2>&1; then
  echo "==> orderbook API is up"
else
  echo "!! orderbook API not reachable at ${ORDERBOOK} (fine for the settlement check)"
fi

echo "==> running the offline private trade test"
cd "${ROOT}"
OFFLINE_RPC="${RPC}" forge test --match-path 'test/offline/*' -vv
