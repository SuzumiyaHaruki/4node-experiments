#!/usr/bin/env bash
set -euo pipefail

RPC_URL=""
TX_TOTAL=""
TPS=""
FAIL_RATIO=""
OUT_CSV=""
KEY_KEEP=""
KEY_FAIL=""
TO_KEEP=""
TO_FAIL=""
SEND_MODE="sequential"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rpc) RPC_URL="$2"; shift 2 ;;
    --tx-total) TX_TOTAL="$2"; shift 2 ;;
    --tps) TPS="$2"; shift 2 ;;
    --fail-ratio) FAIL_RATIO="$2"; shift 2 ;;
    --out) OUT_CSV="$2"; shift 2 ;;
    --key-keep) KEY_KEEP="$2"; shift 2 ;;
    --key-fail) KEY_FAIL="$2"; shift 2 ;;
    --to-keep) TO_KEEP="$2"; shift 2 ;;
    --to-fail) TO_FAIL="$2"; shift 2 ;;
    --send-mode) SEND_MODE="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$RPC_URL" || -z "$TX_TOTAL" || -z "$TPS" || -z "$FAIL_RATIO" || -z "$OUT_CSV" ]]; then
  echo "missing args"
  exit 1
fi

interval=$(python3 - <<PY
tps=float("$TPS")
print(1.0/tps if tps > 0 else 0.0)
PY
)

echo "seq,tx_type,send_ts_ns,tx_hash,receipt_status,block_number,latency_ms,error,error_stage" > "$OUT_CSV"

get_receipt() {
  local tx_hash="$1"
  local start_ns="$2"
  for _ in $(seq 1 120); do
    local receipt
    receipt=$(cast receipt "$tx_hash" --rpc-url "$RPC_URL" --json 2>/dev/null || true)
    if [[ -n "$receipt" && "$receipt" != "null" ]]; then
      local end_ns latency_ms status block_number
      end_ns=$(date +%s%N)
      latency_ms=$(python3 - <<PY
print(round(($end_ns - $start_ns)/1e6, 3))
PY
)
      status=$(jq -r '.status // ""' <<<"$receipt")
      block_number=$(jq -r '.blockNumber // ""' <<<"$receipt")
      echo "$status,$block_number,$latency_ms,,"
      return 0
    fi
    sleep 0.5
  done
  echo ",,,receipt_timeout,receipt"
  return 1
}

fail_count=$(python3 - <<PY
total=int("$TX_TOTAL")
ratio=float("$FAIL_RATIO")
print(int(total * ratio))
PY
)

declare -a row_seq row_tx_type row_send_ts row_tx_hash row_receipt_status row_block_number row_latency_ms row_error row_error_stage row_tx_kind
pending_indices=()

append_row() {
  local idx="$1"
  row_seq[idx]="$2"
  row_tx_type[idx]="$3"
  row_send_ts[idx]="$4"
  row_tx_hash[idx]="$5"
  row_receipt_status[idx]="$6"
  row_block_number[idx]="$7"
  row_latency_ms[idx]="$8"
  row_error[idx]="$9"
  row_error_stage[idx]="${10}"
}

for i in $(seq 1 "$TX_TOTAL"); do
  if [[ "$i" -le "$fail_count" ]]; then
    tx_type="fail"
    key="$KEY_FAIL"
    to="$TO_FAIL"
  else
    tx_type="keep"
    key="$KEY_KEEP"
    to="$TO_KEEP"
  fi

  send_ts_ns=$(date +%s%N)
  send_out=$(cast send "$to" --value 0.001ether --private-key "$key" --rpc-url "$RPC_URL" --json 2>&1 || true)
  tx_hash=$(jq -r '.transactionHash // empty' <<<"$send_out" 2>/dev/null || true)

  if [[ -z "$tx_hash" ]]; then
    err=$(echo "$send_out" | tr '\n' ' ' | sed 's/,/;/g')
    append_row "$((i-1))" "$i" "$tx_type" "$send_ts_ns" "" "" "" "" "$err" "send"
  else
    append_row "$((i-1))" "$i" "$tx_type" "$send_ts_ns" "$tx_hash" "" "" "" "" ""
    pending_indices+=("$((i-1))")
    if [[ "$SEND_MODE" == "sequential" ]]; then
      receipt_line=$(get_receipt "$tx_hash" "$send_ts_ns") || true
      IFS=',' read -r receipt_status block_number latency_ms err err_stage <<<"$receipt_line"
      append_row "$((i-1))" "$i" "$tx_type" "$send_ts_ns" "$tx_hash" "$receipt_status" "$block_number" "$latency_ms" "$err" "$err_stage"
    fi
  fi

  python3 - <<PY
import time
time.sleep(float("$interval"))
PY
done

if [[ "$SEND_MODE" == "deferred" ]]; then
  for idx in "${pending_indices[@]}"; do
    tx_hash="${row_tx_hash[idx]}"
    send_ts_ns="${row_send_ts[idx]}"
    receipt_line=$(get_receipt "$tx_hash" "$send_ts_ns") || true
    IFS=',' read -r receipt_status block_number latency_ms err err_stage <<<"$receipt_line"
    append_row "$idx" "${row_seq[idx]}" "${row_tx_type[idx]}" "$send_ts_ns" "$tx_hash" "$receipt_status" "$block_number" "$latency_ms" "$err" "$err_stage"
  done
fi

for i in $(seq 0 $((TX_TOTAL - 1))); do
  echo "${row_seq[i]},${row_tx_type[i]},${row_send_ts[i]},${row_tx_hash[i]},${row_receipt_status[i]},${row_block_number[i]},${row_latency_ms[i]},${row_error[i]},${row_error_stage[i]}" >> "$OUT_CSV"
done
