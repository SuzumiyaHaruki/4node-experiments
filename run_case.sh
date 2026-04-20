#!/usr/bin/env bash
set -euo pipefail

MATRIX_JSON="${1:-}"
CASE_NAME="${2:-}"
CASE_ENV="${3:-}"
OUT_DIR="${4:-./exp_out}"

NODE1_RPC_URL="${NODE1_RPC_URL:-http://127.0.0.1:8547}"
NODE1_BOOTSTRAP_CMD="${NODE1_BOOTSTRAP_CMD:-}"
FAULT_STATUS_DIR="${FAULT_STATUS_DIR:-./.fault_status}"

if [[ -z "$MATRIX_JSON" || -z "$CASE_NAME" || -z "$CASE_ENV" ]]; then
  echo "usage: $0 <matrix.json> <case_name> <case.env> [out_dir]" >&2
  exit 1
fi

mkdir -p "$OUT_DIR" "$FAULT_STATUS_DIR"

case_json="$(jq -c --arg name "$CASE_NAME" '.[] | select(.name == $name)' "$MATRIX_JSON")"
if [[ -z "$case_json" ]]; then
  echo "case not found: $CASE_NAME" >&2
  exit 1
fi

case_dir="$OUT_DIR/$CASE_NAME"
mkdir -p "$case_dir"

if [[ ! -f "$CASE_ENV" ]]; then
  echo "missing case env file: $CASE_ENV" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CASE_ENV"

tx_total="$(jq -r '.tx_total' <<<"$case_json")"
tps="$(jq -r '.tps' <<<"$case_json")"
fail_ratio="$(jq -r '.fail_ratio' <<<"$case_json")"
fault="$(jq -r '.fault' <<<"$case_json")"

if [[ -n "$NODE1_BOOTSTRAP_CMD" ]]; then
  echo "[*] bootstrapping node-1 for case=$CASE_NAME"
  bash -lc "$NODE1_BOOTSTRAP_CMD"
fi

if [[ "$fault" != "none" ]]; then
  ./fault_injector.sh apply "$fault" "$FAULT_STATUS_DIR"
fi

./send_workload.sh \
  --rpc "$NODE1_RPC_URL" \
  --tx-total "$tx_total" \
  --tps "$tps" \
  --fail-ratio "$fail_ratio" \
  --out "$case_dir/tx_results.csv" \
  --key-keep "$KEY_KEEP" \
  --key-fail "$KEY_FAIL" \
  --to-keep "$TO_KEEP" \
  --to-fail "$TO_FAIL"

if [[ "$fault" != "none" ]]; then
  ./fault_injector.sh clear "$fault" "$FAULT_STATUS_DIR" || true
fi

python3 ./extract_metrics.py \
  --case-name "$CASE_NAME" \
  --tx-csv "$case_dir/tx_results.csv" \
  --sequencer-log /data/nitro-logs/nitro.log \
  --endorser-log /data/nitro-logs/endorser.log \
  --endorser-log /data/nitro-logs/endorser.log \
  --endorser-log /data/nitro-logs/endorser.log \
  --fault-status "${FAULT_STATUS_DIR}/$(echo "$fault" | sed 's#[/:, ]#_#g').status" \
  --out-json "$case_dir/summary.json" \
  --out-tsv "$case_dir/summary.tsv"

echo "[*] case finished: $CASE_NAME"
