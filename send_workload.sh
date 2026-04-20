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
CONCURRENCY="20"
SEND_WORKDIR=""

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
    --concurrency) CONCURRENCY="$2"; shift 2 ;;
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

sanitize_csv_field() {
  local value="$1"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  value="${value//|/;}"
  value="${value//,/;}"
  printf '%s' "$value"
}

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

write_send_file() {
  local path="$1"
  shift
  printf '%s|%s|%s|%s|%s|%s\n' "$@" > "$path"
}

write_final_file() {
  local path="$1"
  shift
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$@" > "$path"
}

submit_tx() {
  local seq="$1"
  local tx_type="$2"
  local key="$3"
  local to="$4"
  local nonce="$5"
  local out_path="$6"

  local send_ts_ns send_out tx_hash err
  send_ts_ns=$(date +%s%N)
  send_out=$(cast send "$to" \
    --value 0.001ether \
    --private-key "$key" \
    --rpc-url "$RPC_URL" \
    --nonce "$nonce" \
    --json 2>&1 || true)
  tx_hash=$(jq -r '.transactionHash // empty' <<<"$send_out" 2>/dev/null || true)
  if [[ -z "$tx_hash" ]]; then
    err=$(sanitize_csv_field "$(echo "$send_out" | tr '\n' ' ')")
    write_send_file "$out_path" "$seq" "$tx_type" "$send_ts_ns" "" "$err" "send"
    return 0
  fi

  write_send_file "$out_path" "$seq" "$tx_type" "$send_ts_ns" "$tx_hash" "" ""
}

poll_tx_receipt() {
  local send_path="$1"
  local receipt_path="$2"

  local seq tx_type send_ts_ns tx_hash send_error send_error_stage
  IFS='|' read -r seq tx_type send_ts_ns tx_hash send_error send_error_stage < "$send_path"
  if [[ -z "$tx_hash" ]]; then
    write_final_file "$receipt_path" "$seq" "$tx_type" "$send_ts_ns" "" "" "" "" "$send_error" "$send_error_stage"
    return 0
  fi

  local receipt_line receipt_status block_number latency_ms err err_stage
  receipt_line=$(get_receipt "$tx_hash" "$send_ts_ns") || true
  IFS=',' read -r receipt_status block_number latency_ms err err_stage <<<"$receipt_line"
  write_final_file "$receipt_path" "$seq" "$tx_type" "$send_ts_ns" "$tx_hash" "$receipt_status" "$block_number" "$latency_ms" "$err" "$err_stage"
}

throttle_jobs() {
  local limit="$1"
  if [[ "$limit" -le 0 ]]; then
    return 0
  fi
  while (( $(jobs -pr | wc -l) >= limit )); do
    wait -n || true
  done
}

get_nonce_for_key() {
  local key="$1"
  local addr
  addr=$(cast wallet address --private-key "$key")
  local nonce
  nonce=$(cast nonce "$addr" --rpc-url "$RPC_URL")
  echo "$nonce"
}

pick_tx_type_for_position() {
  local pos="$1"
  local total="$2"
  local fail_total="$3"
  local prev_cutoff current_cutoff
  prev_cutoff=$(( (pos - 1) * fail_total / total ))
  current_cutoff=$(( pos * fail_total / total ))
  if [[ "$current_cutoff" -gt "$prev_cutoff" ]]; then
    echo "fail"
  else
    echo "keep"
  fi
}

run_legacy_mode() {
  local fail_count
  fail_count=$(python3 - <<PY
total=int("$TX_TOTAL")
ratio=float("$FAIL_RATIO")
print(int(total * ratio))
PY
)

  declare -a row_seq row_tx_type row_send_ts row_tx_hash row_receipt_status row_block_number row_latency_ms row_error row_error_stage
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
      err=$(sanitize_csv_field "$(echo "$send_out" | tr '\n' ' ')")
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
}

run_concurrent_mode() {
  local fail_count
  fail_count=$(python3 - <<PY
total=int("$TX_TOTAL")
ratio=float("$FAIL_RATIO")
print(int(total * ratio))
PY
)

  local concurrency_limit="$CONCURRENCY"
  if [[ -z "$concurrency_limit" || "$concurrency_limit" -le 0 ]]; then
    concurrency_limit="$TX_TOTAL"
  fi

  local keep_nonce fail_nonce
  keep_nonce=$(get_nonce_for_key "$KEY_KEEP")
  fail_nonce=$(get_nonce_for_key "$KEY_FAIL")

  SEND_WORKDIR=$(mktemp -d /tmp/nitro_send_workload.XXXXXX)
  local send_dir
  send_dir="$SEND_WORKDIR/send"
  mkdir -p "$send_dir"
  trap 'rm -rf "$SEND_WORKDIR"' EXIT

  local keep_next_nonce fail_next_nonce
  keep_next_nonce=$((keep_nonce))
  fail_next_nonce=$((fail_nonce))

  for i in $(seq 1 "$TX_TOTAL"); do
    tx_type="$(pick_tx_type_for_position "$i" "$TX_TOTAL" "$fail_count")"
    if [[ "$tx_type" == "fail" ]]; then
      key="$KEY_FAIL"
      to="$TO_FAIL"
      nonce="$fail_next_nonce"
      fail_next_nonce=$((fail_next_nonce + 1))
    else
      tx_type="keep"
      key="$KEY_KEEP"
      to="$TO_KEEP"
      nonce="$keep_next_nonce"
      keep_next_nonce=$((keep_next_nonce + 1))
    fi

    submit_tx "$i" "$tx_type" "$key" "$to" "$nonce" "$send_dir/$i" &
    throttle_jobs "$concurrency_limit"
  done
  wait

  for i in $(seq 1 "$TX_TOTAL"); do
    if IFS='|' read -r seq tx_type send_ts_ns tx_hash send_error send_error_stage < "$send_dir/$i"; then
      if [[ -z "$tx_hash" ]]; then
        echo "$seq,$tx_type,$send_ts_ns,$tx_hash,,,${send_error},${send_error_stage}" >> "$OUT_CSV"
      else
        receipt_line=$(get_receipt "$tx_hash" "$send_ts_ns") || true
        IFS=',' read -r receipt_status block_number latency_ms err err_stage <<<"$receipt_line"
        echo "$seq,$tx_type,$send_ts_ns,$tx_hash,$receipt_status,$block_number,$latency_ms,$err,$err_stage" >> "$OUT_CSV"
      fi
    else
      echo "missing send result for seq $i" >&2
      exit 1
    fi
  done
}

case "$SEND_MODE" in
  sequential|deferred)
    run_legacy_mode
    ;;
  concurrent|burst)
    run_concurrent_mode
    ;;
  *)
    echo "unknown send mode: $SEND_MODE" >&2
    exit 1
    ;;
esac
