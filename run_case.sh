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
send_mode="$(jq -r '.send_mode // "sequential"' <<<"$case_json")"
batching_window_ms="$(jq -r '.batching_window_ms // empty' <<<"$case_json")"
endorsement_mode="$(jq -r '.mode // empty' <<<"$case_json")"
default_threshold="$(jq -r '.default_threshold // empty' <<<"$case_json")"
strict_threshold="$(jq -r '.strict_threshold // empty' <<<"$case_json")"
default_aggregation="$(jq -r '.default_aggregation // empty' <<<"$case_json")"
strict_aggregation="$(jq -r '.strict_aggregation // empty' <<<"$case_json")"
block_endorsement_timeout_ms="$(jq -r '.block_endorsement_timeout_ms // empty' <<<"$case_json")"
max_rebuild_rounds="$(jq -r '.max_rebuild_rounds // empty' <<<"$case_json")"

bootstrap_env=()
[[ -n "$batching_window_ms" ]] && bootstrap_env+=("BATCHING_WINDOW_MS=$batching_window_ms")
[[ -n "$endorsement_mode" ]] && bootstrap_env+=("ENDORSEMENT_MODE=$endorsement_mode")
[[ -n "$default_threshold" ]] && bootstrap_env+=("DEFAULT_THRESHOLD=$default_threshold")
[[ -n "$strict_threshold" ]] && bootstrap_env+=("STRICT_THRESHOLD=$strict_threshold")
[[ -n "$default_aggregation" ]] && bootstrap_env+=("DEFAULT_AGGREGATION=$default_aggregation")
[[ -n "$strict_aggregation" ]] && bootstrap_env+=("STRICT_AGGREGATION=$strict_aggregation")
[[ -n "$block_endorsement_timeout_ms" ]] && bootstrap_env+=("BLOCK_ENDORSEMENT_TIMEOUT_MS=$block_endorsement_timeout_ms")
[[ -n "$max_rebuild_rounds" ]] && bootstrap_env+=("MAX_REBUILD_ROUNDS=$max_rebuild_rounds")
bootstrap_prefix=""
if [[ ${#bootstrap_env[@]} -gt 0 ]]; then
  bootstrap_prefix="${bootstrap_env[*]} "
fi

if [[ -n "$NODE1_BOOTSTRAP_CMD" ]]; then
  echo "[*] bootstrapping node-1 for case=$CASE_NAME"
  bash -lc "${bootstrap_prefix}${NODE1_BOOTSTRAP_CMD}"
fi

if [[ "$fault" != "none" ]]; then
  ./fault_injector.sh apply "$fault" "$FAULT_STATUS_DIR"
fi

./send_workload.sh \
  --rpc "$NODE1_RPC_URL" \
  --tx-total "$tx_total" \
  --tps "$tps" \
  --fail-ratio "$fail_ratio" \
  --send-mode "$send_mode" \
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
