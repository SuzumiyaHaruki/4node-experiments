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
    echo "$i,$tx_type,$send_ts_ns,,,,\"$err\",send" >> "$OUT_CSV"
  else
    receipt_line=$(get_receipt "$tx_hash" "$send_ts_ns")
    echo "$i,$tx_type,$send_ts_ns,$tx_hash,$receipt_line" >> "$OUT_CSV"
  fi

  python3 - <<PY
import time
time.sleep(float("$interval"))
PY
done
