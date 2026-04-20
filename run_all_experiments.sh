#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RESULTS_DIR="${RESULTS_DIR:-$ROOT_DIR/results}"
ACCOUNTS_DIR="${ACCOUNTS_DIR:-$ROOT_DIR/accounts_pool}"
NODE1_BOOTSTRAP_SCRIPT="${NODE1_BOOTSTRAP_SCRIPT:-/data/node1_redeploy.sh}"
NODE1_RPC_URL="${NODE1_RPC_URL:-http://127.0.0.1:8547}"
NODE2_SSH="${NODE2_SSH:-root@192.168.1.13}"
NODE3_SSH="${NODE3_SSH:-root@192.168.1.6}"
NODE4_SSH="${NODE4_SSH:-root@192.168.1.4}"
export ACCOUNTS_DIR NODE1_RPC_URL NODE2_SSH NODE3_SSH NODE4_SSH

THRESHOLD_2OF3_CMD="${THRESHOLD_2OF3_CMD:-DEFAULT_THRESHOLD=2 STRICT_THRESHOLD=3 bash ${NODE1_BOOTSTRAP_SCRIPT}}"
THRESHOLD_3OF3_CMD="${THRESHOLD_3OF3_CMD:-DEFAULT_THRESHOLD=3 STRICT_THRESHOLD=3 bash ${NODE1_BOOTSTRAP_SCRIPT}}"

mkdir -p "$RESULTS_DIR"

run_matrix_case() {
  local matrix_json="$1"
  local out_dir="$2"
  mkdir -p "$out_dir"
  "$ROOT_DIR/run_matrix.sh" "$matrix_json" "$out_dir"
}

run_threshold_case() {
  local matrix_json="$1"
  local case_name="$2"
  local case_env="$3"
  local out_dir="$4"
  local bootstrap_cmd="$5"

  NODE1_BOOTSTRAP_CMD="$bootstrap_cmd" \
    "$ROOT_DIR/run_case.sh" "$matrix_json" "$case_name" "$case_env" "$out_dir"
}

echo "[*] running correctness matrix"
run_matrix_case "$ROOT_DIR/matrix_correctness.json" "$RESULTS_DIR/correctness"

echo "[*] running performance matrix"
run_matrix_case "$ROOT_DIR/matrix_performance.json" "$RESULTS_DIR/performance"

echo "[*] running threshold cases"
for case_name in threshold_2of3_fail20 threshold_3of3_fail20 threshold_2of3_fail40 threshold_3of3_fail40; do
  case_env="$ACCOUNTS_DIR/$case_name.env"
  if [[ "$case_name" == threshold_2of3* ]]; then
    run_threshold_case \
      "$ROOT_DIR/matrix_threshold.json" \
      "$case_name" \
      "$case_env" \
      "$RESULTS_DIR/threshold" \
      "$THRESHOLD_2OF3_CMD"
  else
    run_threshold_case \
      "$ROOT_DIR/matrix_threshold.json" \
      "$case_name" \
      "$case_env" \
      "$RESULTS_DIR/threshold" \
      "$THRESHOLD_3OF3_CMD"
  fi
done

echo "[*] running fault matrix"
NODE2_SSH="$NODE2_SSH" NODE3_SSH="$NODE3_SSH" NODE4_SSH="$NODE4_SSH" \
  run_matrix_case "$ROOT_DIR/matrix_fault.json" "$RESULTS_DIR/fault"

echo "[*] all experiments finished, results in $RESULTS_DIR"
