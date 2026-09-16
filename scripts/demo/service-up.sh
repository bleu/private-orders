#!/usr/bin/env bash
# Start the link service against the demo stack, reachable at PUBLIC_URL.
#
# PUBLIC_URL is the part that matters for a demo: the page builds share links from it, so a service
# started with the default prints `http://localhost:9200/o/…` and nobody outside this machine can open
# it. Set it to the address the audience will use.
#
#   PUBLIC_URL=https://demo.example.ts.net ./scripts/demo/service-up.sh
#
# Env: OFFLINE_DIR, RPC, ORDERBOOK_URL, PUBLIC_URL, SERVICE_PORT, SUBSOLVER_PORT, SUBSOLVER_OFFERS_DIR.
# Reads the deployed private-trade addresses from out-json/private-trade-deployed.json, so run the
# deployment first (scripts/demo/reset-and-run.sh does that as part of its smoke test).
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OFFLINE_DIR="${OFFLINE_DIR:-$(cd "${ROOT}/../../offline-mode" 2>/dev/null && pwd || echo "")}"
RPC="${RPC:-http://localhost:8545}"
ORDERBOOK_URL="${ORDERBOOK_URL:-http://localhost:8080}"
PUBLIC_URL="${PUBLIC_URL:-http://localhost:9200}"
SERVICE_PORT="${SERVICE_PORT:-9200}"
SUBSOLVER_OFFERS_DIR="${SUBSOLVER_OFFERS_DIR:-${ROOT}/out-json/sub-solver-offers}"

DEPLOYED="${ROOT}/out-json/private-trade-deployed.json"
[ -f "${DEPLOYED}" ] || { echo "no deployment at ${DEPLOYED} — run scripts/demo/reset-and-run.sh first" >&2; exit 1; }
[ -n "${OFFLINE_DIR}" ] || { echo "set OFFLINE_DIR to the offline stack checkout" >&2; exit 1; }

set -a; source "${OFFLINE_DIR}/.env"; set +a
json() { python3 -c "import json;print(json.load(open('${DEPLOYED}'))['$1'])"; }
log() { printf '\n==> %s\n' "$*"; }

# The sub-solver is started by reset-and-run.sh; a service without one relays and never settles.
if ! pgrep -f "[p]rivate-trade-solver" >/dev/null; then
  echo "note: no sub-solver is running — nothing will settle until one is (scripts/demo/reset-and-run.sh starts it)" >&2
fi

log "starting the link service on ${SERVICE_PORT}, links will point at ${PUBLIC_URL}"
pkill -f "[l]ink-service/server.mjs" 2>/dev/null || true
sleep 1
cd "${ROOT}"
PORT="${SERVICE_PORT}" PUBLIC_URL="${PUBLIC_URL}" PRIVATE_TRADE_ROOT="${ROOT}" RPC="${RPC}" \
  ORDERBOOK_URL="${ORDERBOOK_URL}" \
  PRIVATE_TRADE_WRAPPER="$(json wrapper)" PRIVATE_TRADE_HANDLER="$(json handler)" \
  PRIVATE_TRADE_AUTHORISER="$(json authoriser)" \
  COWSHED_COMPOSABLE_COW_FACTORY_ADDRESS="${COWSHED_COMPOSABLE_COW_FACTORY_ADDRESS}" \
  COMPOSABLE_COW_ADDRESS="${COMPOSABLE_COW_ADDRESS}" VAULT_RELAYER_ADDRESS="${VAULT_RELAYER_ADDRESS}" \
  RELAYER_PRIVATE_KEY="${ANVIL_KEY_0:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}" \
  SUBSOLVER_OFFERS_DIR="${SUBSOLVER_OFFERS_DIR}" \
  setsid nohup node link-service/server.mjs >>/tmp/link-service.out 2>&1 < /dev/null &
sleep 3
curl -fsS "http://localhost:${SERVICE_PORT}/health" >/dev/null && printf '   local health ok\n'
curl -fsS "${PUBLIC_URL}/health" >/dev/null && printf '   %s health ok\n' "${PUBLIC_URL}"
