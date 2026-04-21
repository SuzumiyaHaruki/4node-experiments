#!/usr/bin/env bash
set -euo pipefail

MATRIX_JSON="${1:-}"
CASE_NAME="${2:-}"
CASE_ENV="${3:-}"
OUT_DIR="${4:-./exp_out}"

NODE1_RPC_URL="${NODE1_RPC_URL:-http://127.0.0.1:8547}"
NODE1_BOOTSTRAP_CMD="${NODE1_BOOTSTRAP_CMD:-}"
FAULT_STATUS_DIR="${FAULT_STATUS_DIR:-./.fault_status}"
NONCE_CACHE_FILE="${NONCE_CACHE_FILE:-/tmp/nitro_prepare_accounts_funder_nonce}"

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
concurrency="$(jq -r '.concurrency // empty' <<<"$case_json")"
use_account_pool="$(jq -r '.use_account_pool // false' <<<"$case_json")"
pool_fund_amount="$(jq -r '.pool_fund_amount // "0.02ether"' <<<"$case_json")"
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

keep_pool_env=""
fail_pool_env=""
if [[ "$use_account_pool" == "true" ]]; then
  fail_count="$(python3 - <<PY
total=int("$tx_total")
ratio=float("$fail_ratio")
print(int(total * ratio))
PY
)"
  keep_count=$((tx_total - fail_count))
  keep_pool_env="${CASE_ENV%.env}_keep_pool.env"
  fail_pool_env="${CASE_ENV%.env}_fail_pool.env"

  if (( keep_count > 0 )); then
    echo "[*] preparing keep pool for case=$CASE_NAME size=$keep_count"
    FUND_AMOUNT="$pool_fund_amount" NONCE_CACHE_FILE="$NONCE_CACHE_FILE" ./prepare_keep_pool.sh "$keep_pool_env" "$keep_count"
  fi
  if (( fail_count > 0 )); then
    echo "[*] preparing fail pool for case=$CASE_NAME size=$fail_count"
    FUND_AMOUNT="$pool_fund_amount" NONCE_CACHE_FILE="$NONCE_CACHE_FILE" ./prepare_fail_pool.sh "$fail_pool_env" "$fail_count"
  fi
fi

if [[ "$fault" != "none" ]]; then
  ./fault_injector.sh apply "$fault" "$FAULT_STATUS_DIR"
fi

send_args=(
  --rpc "$NODE1_RPC_URL"
  --tx-total "$tx_total"
  --tps "$tps"
  --fail-ratio "$fail_ratio"
  --send-mode "$send_mode"
  --out "$case_dir/tx_results.csv"
  --key-keep "$KEY_KEEP"
  --key-fail "$KEY_FAIL"
  --addr-keep "$ADDR_KEEP"
  --addr-fail "$ADDR_FAIL"
  --to-keep "$TO_KEEP"
  --to-fail "$TO_FAIL"
)
if [[ -n "$concurrency" ]]; then
  send_args+=(--concurrency "$concurrency")
fi
if [[ -n "$keep_pool_env" ]]; then
  send_args+=(--keep-pool-env "$keep_pool_env")
fi
if [[ -n "$fail_pool_env" ]]; then
  send_args+=(--fail-pool-env "$fail_pool_env")
fi

./send_workload.sh "${send_args[@]}"

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
