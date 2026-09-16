#!/usr/bin/env bash
# Bring up the CoW stack the demo settles through, and nothing else.
#
# Only the services a private trade needs: the chain, the orderbook, and the autopilot/driver/baseline
# trio that turns an order into a settlement. The frontend, explorer, grafana and prometheus services
# are skipped — they cost seconds to start and answer nothing this demo asks.
#
#   ./scripts/demo/stack-up.sh
#
# Two things this script cannot do for you, both of which fail in ways that look like our code is
# broken rather than the environment:
#
#   * `host.docker.internal` is provided by Colima and Docker Desktop, and by nothing on a plain Linux
#     engine. The driver reaches the sub-solver through it (see `config/offline/driver.toml`), so on
#     Linux the driver service needs `extra_hosts: ["host.docker.internal:host-gateway"]`. Without it
#     the stack comes up healthy and settles nothing.
#   * the sub-solver's port. 9100 is node_exporter's well-known port; a host that runs it refuses the
#     bind and the sub-solver exits. Set SUBSOLVER_PORT and keep `endpoint` in driver.toml in step.
#
# Env: OFFLINE_DIR (default ../../offline-mode), RPC, ORDERBOOK_URL for the readiness checks.
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OFFLINE_DIR="${OFFLINE_DIR:-$(cd "${ROOT}/../../offline-mode" 2>/dev/null && pwd || echo "")}"
RPC="${RPC:-http://localhost:8545}"
ORDERBOOK_URL="${ORDERBOOK_URL:-http://localhost:8080}"

[ -n "${OFFLINE_DIR}" ] || { echo "set OFFLINE_DIR to the offline stack checkout" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

log "starting the CoW stack in ${OFFLINE_DIR}"
cd "${OFFLINE_DIR}"
docker compose up -d chain-deployer chain db db-migrations coingecko-mock orderbook autopilot driver baseline

log "waiting for the chain"
for _ in $(seq 1 30); do
  if curl -fsS -m 3 -X POST "${RPC}" -H 'content-type: application/json' \
      -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' >/dev/null 2>&1; then break; fi
  sleep 5
done
printf '   chain id %s\n' "$(curl -fsS -m 3 -X POST "${RPC}" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' | python3 -c 'import sys,json;print(int(json.load(sys.stdin)["result"],16))')"

log "waiting for the orderbook"
for _ in $(seq 1 30); do
  if curl -fsS -m 3 "${ORDERBOOK_URL}/api/v1/version" >/dev/null 2>&1; then break; fi
  sleep 5
done
curl -fsS -m 3 -o /dev/null -w '   orderbook %{http_code}\n' "${ORDERBOOK_URL}/api/v1/version"
