#!/usr/bin/env bash
# Start the demo faucet, so a visitor can fund the address they will trade from.
#
# A visitor arrives holding nothing on the fork: their signature is valid but the permit has no balance
# behind it, so the relay's transfer reverts and the trade dies at the first step saying something about
# allowance. This is the fix for that, and without it a self-serve demo is not self-serve.
#
#   ./scripts/demo/faucet-up.sh
#
# Env: OFFLINE_DIR (for the token addresses), RPC, FAUCET_PORT, AMOUNT_DAI, AMOUNT_USDC, FUNDER_KEY.
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OFFLINE_DIR="${OFFLINE_DIR:-$(cd "${ROOT}/../../offline-mode" 2>/dev/null && pwd || echo "")}"
RPC="${RPC:-http://localhost:8545}"
FAUCET_PORT="${FAUCET_PORT:-9300}"

[ -n "${OFFLINE_DIR}" ] || { echo "set OFFLINE_DIR to the offline stack checkout" >&2; exit 1; }
set -a; source "${OFFLINE_DIR}/.env"; set +a

printf '\n==> starting the demo faucet on %s, DAI %s, USDC %s\n' "${FAUCET_PORT}" "${DAI_ADDRESS}" "${USDC_ADDRESS}"
pkill -f "[d]emo-faucet" 2>/dev/null || true
sleep 1
cd "${ROOT}"
RPC="${RPC}" DAI="${DAI_ADDRESS}" USDC="${USDC_ADDRESS}" PORT="${FAUCET_PORT}" \
  AMOUNT_DAI="${AMOUNT_DAI:-10000}" AMOUNT_USDC="${AMOUNT_USDC:-10000}" \
  setsid nohup node scripts/demo-faucet.mjs >>/tmp/faucet.out 2>&1 < /dev/null &
sleep 2
tail -1 /tmp/faucet.out
