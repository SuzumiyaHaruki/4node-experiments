#!/usr/bin/env bash
set -euo pipefail

RPC_URL=""
TX_TOTAL=""
TPS=""
FAIL_RATIO=""
OUT_CSV=""
KEY_KEEP=""
KEY_FAIL=""
ADDR_KEEP=""
ADDR_FAIL=""
TO_KEEP=""
TO_FAIL=""
SEND_MODE="sequential"
CONCURRENCY="20"
KEEP_POOL_ENV=""
FAIL_POOL_ENV=""
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
    --addr-keep) ADDR_KEEP="$2"; shift 2 ;;
    --addr-fail) ADDR_FAIL="$2"; shift 2 ;;
    --to-keep) TO_KEEP="$2"; shift 2 ;;
    --to-fail) TO_FAIL="$2"; shift 2 ;;
    --send-mode) SEND_MODE="$2"; shift 2 ;;
    --concurrency) CONCURRENCY="$2"; shift 2 ;;
    --keep-pool-env) KEEP_POOL_ENV="$2"; shift 2 ;;
    --fail-pool-env) FAIL_POOL_ENV="$2"; shift 2 ;;
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

fetch_account_nonce() {
  local addr="$1"
  cast nonce "$addr" --rpc-url "$RPC_URL" 2>/dev/null | tr -d '[:space:]'
}

get_nonce_for_key() {
  local key="$1"
  local addr
  addr=$(cast wallet address --private-key "$key")
  fetch_account_nonce "$addr"
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

declare -a KEEP_POOL_KEYS KEEP_POOL_ADDRS KEEP_POOL_NONCES
declare -a FAIL_POOL_KEYS FAIL_POOL_ADDRS FAIL_POOL_NONCES
KEEP_BASE_NONCE=""
FAIL_BASE_NONCE=""

load_keep_pool() {
  local pool_env="$1"
  [[ -f "$pool_env" ]] || { echo "keep pool env not found: $pool_env" >&2; exit 1; }
  # shellcheck disable=SC1090
  source "$pool_env"

  local pool_size="${KEEP_POOL_SIZE:-0}"
  if ! [[ "$pool_size" =~ ^[0-9]+$ ]] || (( pool_size < 1 )); then
    echo "invalid KEEP_POOL_SIZE in $pool_env: $pool_size" >&2
    exit 1
  fi

  KEEP_POOL_KEYS=()
  KEEP_POOL_ADDRS=()
  KEEP_POOL_NONCES=()

  local idx key_var addr_var key addr nonce
  for idx in $(seq 1 "$pool_size"); do
    key_var="KEEP_KEY_${idx}"
    addr_var="KEEP_ADDR_${idx}"
    key="${!key_var:-}"
    addr="${!addr_var:-}"
    [[ -n "$key" && -n "$addr" ]] || { echo "missing $key_var or $addr_var in $pool_env" >&2; exit 1; }
    nonce=$(fetch_account_nonce "$addr")
    [[ "$nonce" =~ ^[0-9]+$ ]] || { echo "failed to fetch nonce for keep pool address: $addr" >&2; exit 1; }
    KEEP_POOL_KEYS+=("$key")
    KEEP_POOL_ADDRS+=("$addr")
    KEEP_POOL_NONCES+=("$nonce")
  done
}

load_fail_pool() {
  local pool_env="$1"
  [[ -f "$pool_env" ]] || { echo "fail pool env not found: $pool_env" >&2; exit 1; }
  # shellcheck disable=SC1090
  source "$pool_env"

  local pool_size="${FAIL_POOL_SIZE:-0}"
  if ! [[ "$pool_size" =~ ^[0-9]+$ ]] || (( pool_size < 1 )); then
    echo "invalid FAIL_POOL_SIZE in $pool_env: $pool_size" >&2
    exit 1
  fi

  FAIL_POOL_KEYS=()
  FAIL_POOL_ADDRS=()
  FAIL_POOL_NONCES=()

  local idx key_var addr_var key addr nonce
  for idx in $(seq 1 "$pool_size"); do
    key_var="FAIL_KEY_${idx}"
    addr_var="FAIL_ADDR_${idx}"
    key="${!key_var:-}"
    addr="${!addr_var:-}"
    [[ -n "$key" && -n "$addr" ]] || { echo "missing $key_var or $addr_var in $pool_env" >&2; exit 1; }
    nonce=$(fetch_account_nonce "$addr")
    [[ "$nonce" =~ ^[0-9]+$ ]] || { echo "failed to fetch nonce for fail pool address: $addr" >&2; exit 1; }
    FAIL_POOL_KEYS+=("$key")
    FAIL_POOL_ADDRS+=("$addr")
    FAIL_POOL_NONCES+=("$nonce")
  done
}

init_sender_state() {
  if [[ -n "$KEEP_POOL_ENV" ]]; then
    load_keep_pool "$KEEP_POOL_ENV"
  elif [[ -n "$KEY_KEEP" ]]; then
    KEEP_BASE_NONCE=$(get_nonce_for_key "$KEY_KEEP")
  fi

  if [[ -n "$FAIL_POOL_ENV" ]]; then
    load_fail_pool "$FAIL_POOL_ENV"
  elif [[ -n "$KEY_FAIL" ]]; then
    FAIL_BASE_NONCE=$(get_nonce_for_key "$KEY_FAIL")
  fi
}

resolve_sender() {
  local tx_type="$1"
  local type_index="$2"
  local zero_index=$((type_index - 1))
  local key addr to nonce

  if [[ "$tx_type" == "fail" ]]; then
    to="$TO_FAIL"
    if [[ -n "$FAIL_POOL_ENV" ]]; then
      (( zero_index < ${#FAIL_POOL_KEYS[@]} )) || { echo "not enough fail pool accounts: have ${#FAIL_POOL_KEYS[@]}, need $type_index" >&2; exit 1; }
      key="${FAIL_POOL_KEYS[$zero_index]}"
      addr="${FAIL_POOL_ADDRS[$zero_index]}"
      nonce="${FAIL_POOL_NONCES[$zero_index]}"
    else
      key="$KEY_FAIL"
      addr="$ADDR_FAIL"
      nonce=$((FAIL_BASE_NONCE + zero_index))
    fi
  else
    to="$TO_KEEP"
    if [[ -n "$KEEP_POOL_ENV" ]]; then
      (( zero_index < ${#KEEP_POOL_KEYS[@]} )) || { echo "not enough keep pool accounts: have ${#KEEP_POOL_KEYS[@]}, need $type_index" >&2; exit 1; }
      key="${KEEP_POOL_KEYS[$zero_index]}"
      addr="${KEEP_POOL_ADDRS[$zero_index]}"
      nonce="${KEEP_POOL_NONCES[$zero_index]}"
    else
      key="$KEY_KEEP"
      addr="$ADDR_KEEP"
      nonce=$((KEEP_BASE_NONCE + zero_index))
    fi
  fi

  printf '%s|%s|%s|%s\n' "$key" "$addr" "$to" "$nonce"
}

run_legacy_mode() {
  local fail_count
  fail_count=$(python3 - <<PY
total=int("$TX_TOTAL")
ratio=float("$FAIL_RATIO")
print(int(total * ratio))
PY
)

  local keep_seen=0 fail_seen=0
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
    local tx_type sender_info key addr to nonce send_ts_ns send_out tx_hash err receipt_line receipt_status block_number latency_ms err_stage
    tx_type="$(pick_tx_type_for_position "$i" "$TX_TOTAL" "$fail_count")"
    if [[ "$tx_type" == "fail" ]]; then
      fail_seen=$((fail_seen + 1))
      sender_info="$(resolve_sender "fail" "$fail_seen")"
    else
      tx_type="keep"
      keep_seen=$((keep_seen + 1))
      sender_info="$(resolve_sender "keep" "$keep_seen")"
    fi
    IFS='|' read -r key addr to nonce <<<"$sender_info"

    send_ts_ns=$(date +%s%N)
    send_out=$(cast send "$to" --value 0.001ether --private-key "$key" --rpc-url "$RPC_URL" --nonce "$nonce" --json 2>&1 || true)
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

  SEND_WORKDIR=$(mktemp -d /tmp/nitro_send_workload.XXXXXX)
  local send_dir
  send_dir="$SEND_WORKDIR/send"
  mkdir -p "$send_dir"
  trap 'rm -rf "$SEND_WORKDIR"' EXIT

  local keep_seen=0 fail_seen=0

  for i in $(seq 1 "$TX_TOTAL"); do
    local tx_type sender_info key addr to nonce
    tx_type="$(pick_tx_type_for_position "$i" "$TX_TOTAL" "$fail_count")"
    if [[ "$tx_type" == "fail" ]]; then
      fail_seen=$((fail_seen + 1))
      sender_info="$(resolve_sender "fail" "$fail_seen")"
    else
      tx_type="keep"
      keep_seen=$((keep_seen + 1))
      sender_info="$(resolve_sender "keep" "$keep_seen")"
    fi
    IFS='|' read -r key addr to nonce <<<"$sender_info"

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

init_sender_state

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
