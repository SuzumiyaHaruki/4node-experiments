#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RESULTS_DIR="${RESULTS_DIR:-$ROOT_DIR/results}"
ACCOUNTS_DIR="${ACCOUNTS_DIR:-$ROOT_DIR/accounts_pool}"
NODE1_BOOTSTRAP_SCRIPT="${NODE1_BOOTSTRAP_SCRIPT:-/data/node1_redeploy.sh}"
NODE1_RPC_URL="${NODE1_RPC_URL:-http://127.0.0.1:8547}"
FUND_AMOUNT="${FUND_AMOUNT:-3ether}"
NONCE_CACHE_FILE="${NONCE_CACHE_FILE:-/tmp/nitro_prepare_accounts_funder_nonce}"
PERF_BATCHING_WINDOW_MS="${PERF_BATCHING_WINDOW_MS:-1200}"
PERF_BOOTSTRAP_CMD="${PERF_BOOTSTRAP_CMD:-RESET_CHAIN=1 BATCHING_WINDOW_MS=${PERF_BATCHING_WINDOW_MS} ENDORSEMENT_MODE=remote DEFAULT_THRESHOLD=2 STRICT_THRESHOLD=3 DEFAULT_AGGREGATION=bls STRICT_AGGREGATION=bls BLOCK_ENDORSEMENT_TIMEOUT_MS=2000 MAX_REBUILD_ROUNDS=3 bash ${NODE1_BOOTSTRAP_SCRIPT}}"
FAULT_TX_TOTAL="${FAULT_TX_TOTAL:-60}"
FAULT_TPS="${FAULT_TPS:-4}"
FAULT_SEND_MODE="${FAULT_SEND_MODE:-concurrent}"
FAULT_CONCURRENCY="${FAULT_CONCURRENCY:-4}"
FAULT_FAIL_RATIO="${FAULT_FAIL_RATIO:-0.1}"
FAULT_BATCHING_WINDOW_MS="${FAULT_BATCHING_WINDOW_MS:-2000}"
FAULT_BLOCK_ENDORSEMENT_TIMEOUT_MS="${FAULT_BLOCK_ENDORSEMENT_TIMEOUT_MS:-5000}"
FAULT_MAX_REBUILD_ROUNDS="${FAULT_MAX_REBUILD_ROUNDS:-5}"
NODE1_STOP_CMD="${NODE1_STOP_CMD:-pkill -x nitro >/dev/null 2>&1 || true}"
FAULT_BOOTSTRAP_CMD="${FAULT_BOOTSTRAP_CMD:-RESET_CHAIN=1 BATCHING_WINDOW_MS=${FAULT_BATCHING_WINDOW_MS} ENDORSEMENT_MODE=remote DEFAULT_THRESHOLD=2 STRICT_THRESHOLD=3 DEFAULT_AGGREGATION=bls STRICT_AGGREGATION=bls BLOCK_ENDORSEMENT_TIMEOUT_MS=${FAULT_BLOCK_ENDORSEMENT_TIMEOUT_MS} MAX_REBUILD_ROUNDS=${FAULT_MAX_REBUILD_ROUNDS} bash ${NODE1_BOOTSTRAP_SCRIPT}}"
NODE2_SSH="${NODE2_SSH:-root@192.168.1.13}"
NODE3_SSH="${NODE3_SSH:-root@192.168.1.6}"
NODE4_SSH="${NODE4_SSH:-root@192.168.1.4}"
NODE2_START_CMD="${NODE2_START_CMD:-bash /data/node2_start.sh}"
NODE3_START_CMD="${NODE3_START_CMD:-bash /data/node3_start.sh}"
NODE4_START_CMD="${NODE4_START_CMD:-bash /data/node4_start.sh}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
export ACCOUNTS_DIR NODE1_RPC_URL FUND_AMOUNT NONCE_CACHE_FILE NODE1_STOP_CMD NODE2_SSH NODE3_SSH NODE4_SSH
export SSH_PASSWORD

mkdir -p "$RESULTS_DIR"

ssh_node() {
  local target="$1"
  shift
  local ssh_cmd=(ssh -o StrictHostKeyChecking=no -n)
  if [[ -n "$SSH_PASSWORD" ]]; then
    if ! command -v sshpass >/dev/null 2>&1; then
      echo "sshpass is required when SSH_PASSWORD is set" >&2
      exit 1
    fi
    sshpass -p "$SSH_PASSWORD" "${ssh_cmd[@]}" "$target" "$@"
  else
    "${ssh_cmd[@]}" "$target" "$@"
  fi
}

reset_endorsers_to_default() {
  echo "[*] resetting endorsers to default reject configuration"
  ssh_node "$NODE2_SSH" "$NODE2_START_CMD"
  ssh_node "$NODE3_SSH" "$NODE3_START_CMD"
  ssh_node "$NODE4_SSH" "$NODE4_START_CMD"
}

run_matrix_case() {
  local matrix_json="$1"
  local out_dir="$2"
  mkdir -p "$out_dir"
  "$ROOT_DIR/run_matrix.sh" "$matrix_json" "$out_dir"
}

echo "[*] running correctness matrix"
reset_endorsers_to_default
NODE1_BOOTSTRAP_CMD="RESET_CHAIN=1 bash ${NODE1_BOOTSTRAP_SCRIPT}" \
  run_matrix_case "$ROOT_DIR/matrix_correctness.json" "$RESULTS_DIR/correctness"

echo "[*] running performance matrix"
reset_endorsers_to_default
NODE1_BOOTSTRAP_CMD="RESET_CHAIN=1 bash ${NODE1_BOOTSTRAP_SCRIPT}" \
  run_matrix_case "$ROOT_DIR/matrix_performance.json" "$RESULTS_DIR/performance"

echo "[*] running threshold matrix"
reset_endorsers_to_default
NODE1_BOOTSTRAP_CMD="RESET_CHAIN=1 bash ${NODE1_BOOTSTRAP_SCRIPT}" \
  run_matrix_case "$ROOT_DIR/matrix_threshold.json" "$RESULTS_DIR/threshold"

echo "[*] running fault matrix"
FAULT_MATRIX_FILE="$(mktemp /tmp/nitro_fault_matrix.XXXXXX.json)"
trap 'rm -f "$FAULT_MATRIX_FILE"' EXIT
jq \
  --argjson tx_total "$FAULT_TX_TOTAL" \
  --argjson tps "$FAULT_TPS" \
  --arg send_mode "$FAULT_SEND_MODE" \
  --argjson concurrency "$FAULT_CONCURRENCY" \
  --argjson fail_ratio "$FAULT_FAIL_RATIO" \
  --argjson batching_window_ms "$FAULT_BATCHING_WINDOW_MS" \
  --argjson block_endorsement_timeout_ms "$FAULT_BLOCK_ENDORSEMENT_TIMEOUT_MS" \
  --argjson max_rebuild_rounds "$FAULT_MAX_REBUILD_ROUNDS" \
  '
    map(
      if (.name | startswith("fault_")) then
        .tx_total = (.tx_total // $tx_total)
        | .tps = (.tps // $tps)
        | .send_mode = (.send_mode // $send_mode)
        | .concurrency = (.concurrency // $concurrency)
        | .fail_ratio = (.fail_ratio // $fail_ratio)
        | .batching_window_ms = (.batching_window_ms // $batching_window_ms)
        | .block_endorsement_timeout_ms = (.block_endorsement_timeout_ms // $block_endorsement_timeout_ms)
        | .max_rebuild_rounds = (.max_rebuild_rounds // $max_rebuild_rounds)
      else
        .
      end
    )
  ' \
  "$ROOT_DIR/matrix_fault.json" > "$FAULT_MATRIX_FILE"

echo "[*] fault defaults: tx_total=$FAULT_TX_TOTAL tps=$FAULT_TPS send_mode=$FAULT_SEND_MODE concurrency=$FAULT_CONCURRENCY fail_ratio=$FAULT_FAIL_RATIO batching_window_ms=$FAULT_BATCHING_WINDOW_MS timeout_ms=$FAULT_BLOCK_ENDORSEMENT_TIMEOUT_MS max_rebuild_rounds=$FAULT_MAX_REBUILD_ROUNDS"
reset_endorsers_to_default
echo "[*] stopping existing node-1 before fault matrix"
bash -lc "$NODE1_STOP_CMD"
sleep 3
echo "[*] bootstrapping node-1 for fault matrix"
bash -lc "$FAULT_BOOTSTRAP_CMD"
NODE2_SSH="$NODE2_SSH" NODE3_SSH="$NODE3_SSH" NODE4_SSH="$NODE4_SSH" SSH_PASSWORD="$SSH_PASSWORD" \
  run_matrix_case "$FAULT_MATRIX_FILE" "$RESULTS_DIR/fault"

echo "[*] all experiments finished, results in $RESULTS_DIR"
