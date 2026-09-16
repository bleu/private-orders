#!/usr/bin/env bash
# Reset the demo's orderbook, then run the whole flow once as a smoke test.
#
# The orderbook keeps orders across runs. A stale order is still a valid order, so the auction serves it
# and the sub-solver skips ours with "acceptance not in this auction" — the appData differs because the
# terms carry a fresh `validTo` each run. Clearing the table first is what makes a run reproducible.
#
#   ./scripts/demo/reset-and-run.sh
#
# Env: OFFLINE_DIR, RPC, ORDERBOOK_URL, SUBSOLVER_PORT (see scripts/demo/stack-up.sh for why the port
# matters), POSTGRES_USER.
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OFFLINE_DIR="${OFFLINE_DIR:-$(cd "${ROOT}/../../offline-mode" 2>/dev/null && pwd || echo "")}"
[ -n "${OFFLINE_DIR}" ] || { echo "set OFFLINE_DIR to the offline stack checkout" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

log "clearing the orderbook's orders"
cd "${OFFLINE_DIR}"
docker compose exec -T db psql -U "${POSTGRES_USER:-postgres}" -d postgres -c "delete from orders;" 2>&1 | tail -2

log "running the flow"
cd "${ROOT}"
pkill -f "[p]rivate-trade-solver" 2>/dev/null || true
pkill -f "[l]ink-service/server.mjs" 2>/dev/null || true
sleep 1
bash scripts/link-service-e2e.sh
