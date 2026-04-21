#!/usr/bin/env bash
set -euo pipefail

OUT_ENV="${1:-./accounts_pool/fail_pool.env}"
POOL_SIZE="${2:-1}"
L2_RPC_URL="${L2_RPC_URL:-http://127.0.0.1:8547}"
FUNDER_KEY="${FUNDER_KEY:-0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659}"
FUND_AMOUNT="${FUND_AMOUNT:-0.02ether}"
NONCE_CACHE_FILE="${NONCE_CACHE_FILE:-/tmp/nitro_prepare_accounts_funder_nonce}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }
}

need_cmd cast
need_cmd jq
need_cmd awk
need_cmd sed
need_cmd python3

if ! [[ "$POOL_SIZE" =~ ^[0-9]+$ ]] || (( POOL_SIZE < 1 )); then
  echo "invalid pool size: $POOL_SIZE" >&2
  exit 1
fi

trim() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
extract_address() { awk -F': ' '/Address/ {print $2}' | trim; }
extract_private_key() { awk -F': ' '/Private key/ {print $2}' | trim; }
validate_hex_address() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
validate_hex_privkey() { [[ "$1" =~ ^0x[0-9a-fA-F]{64}$ ]]; }
validate_tx_hash() { [[ "$1" =~ ^0x[0-9a-fA-F]{64}$ ]]; }

hex_to_dec() {
  python3 - <<PY
print(int("$1", 16))
PY
}

rpc_get_nonce_by_tag() {
  local addr="$1" tag="$2" rpc_url="$3" raw
  raw="$(cast rpc eth_getTransactionCount "$addr" "$tag" --rpc-url "$rpc_url" 2>/dev/null | tr -d '"[:space:]')" || true
  [[ "$raw" =~ ^0x[0-9a-fA-F]+$ ]] || { echo ""; return 1; }
  hex_to_dec "$raw"
}

get_chain_nonce_max() {
  local addr="$1" rpc_url="$2" latest pending
  latest="$(rpc_get_nonce_by_tag "$addr" latest "$rpc_url" || true)"
  pending="$(rpc_get_nonce_by_tag "$addr" pending "$rpc_url" || true)"
  [[ "$latest" =~ ^[0-9]+$ ]] || latest=0
  [[ "$pending" =~ ^[0-9]+$ ]] || pending=0
  (( pending > latest )) && echo "$pending" || echo "$latest"
}

get_cached_nonce_plus_one() {
  if [[ -f "$NONCE_CACHE_FILE" ]]; then
    local cached
    cached="$(tr -d '[:space:]' < "$NONCE_CACHE_FILE" 2>/dev/null || true)"
    [[ "$cached" =~ ^[0-9]+$ ]] && { echo $((cached + 1)); return; }
  fi
  echo 0
}

get_safe_next_nonce() {
  local addr="$1" rpc_url="$2" chain_nonce cached_next
  chain_nonce="$(get_chain_nonce_max "$addr" "$rpc_url")"
  cached_next="$(get_cached_nonce_plus_one)"
  [[ "$chain_nonce" =~ ^[0-9]+$ ]] || chain_nonce=0
  [[ "$cached_next" =~ ^[0-9]+$ ]] || cached_next=0
  (( cached_next > chain_nonce )) && echo "$cached_next" || echo "$chain_nonce"
}

record_used_nonce() { echo "$1" > "$NONCE_CACHE_FILE"; }
make_wallet() { cast wallet new 2>/dev/null; }

wait_for_receipt_success() {
  local tx_hash="$1" rpc_url="$2"
  for _ in $(seq 1 90); do
    local receipt status
    receipt=$(cast receipt "$tx_hash" --rpc-url "$rpc_url" --json 2>/dev/null || true)
    if [[ -n "$receipt" && "$receipt" != "null" ]]; then
      status=$(jq -r '.status // ""' <<<"$receipt")
      [[ "$status" == "1" || "$status" == "0x1" ]] && return 0
      echo "[!] funding tx mined but failed: $tx_hash (status=$status)" >&2
      return 1
    fi
    sleep 1
  done
  echo "[!] timeout waiting for receipt: $tx_hash" >&2
  return 1
}

balance_to_wei() {
  local bal_str="$1"
  if [[ "$bal_str" =~ ^[0-9]+$ ]]; then
    echo "$bal_str"
  elif [[ "$bal_str" =~ ^([0-9]+)(\.[0-9]+)?[[:space:]]*ETH$ ]]; then
    python3 - <<PY
from decimal import Decimal
s = """$bal_str""".strip().replace(" ETH", "")
print(int(Decimal(s) * (10 ** 18)))
PY
  else
    echo "0"
  fi
}

wait_for_min_balance() {
  local addr="$1" rpc_url="$2" min_eth="$3" min_wei
  min_wei=$(python3 - <<PY
from decimal import Decimal
print(int(Decimal("$min_eth") * (10 ** 18)))
PY
)
  for _ in $(seq 1 90); do
    local bal_raw bal_wei
    bal_raw=$(cast balance "$addr" --rpc-url "$rpc_url" 2>/dev/null || echo "0")
    bal_wei=$(balance_to_wei "$bal_raw")
    if [[ "$bal_wei" =~ ^[0-9]+$ ]] && [[ "$bal_wei" -ge "$min_wei" ]]; then
      return 0
    fi
    sleep 1
  done
  echo "[!] timeout waiting for funded balance on account: $addr" >&2
  return 1
}

send_funding_tx() {
  local to_addr="$1" amount="$2" nonce="$3"
  cast send "$to_addr" --value "$amount" --private-key "$FUNDER_KEY" --rpc-url "$L2_RPC_URL" --nonce "$nonce" --json
}

FUNDER_ADDR="$(cast wallet address --private-key "$FUNDER_KEY" 2>/dev/null | tr -d '\r\n')"
validate_hex_address "$FUNDER_ADDR" || { echo "[!] invalid FUNDER address derived from FUNDER_KEY: '$FUNDER_ADDR'" >&2; exit 1; }

touch "$NONCE_CACHE_FILE"
mkdir -p "$(dirname "$OUT_ENV")"

{
  echo "export L2_RPC_URL=\"$L2_RPC_URL\""
  echo "export FUNDER_KEY=\"$FUNDER_KEY\""
  echo "export FAIL_POOL_SIZE=\"$POOL_SIZE\""
} > "$OUT_ENV"

FUND_AMOUNT_NUM="$(echo "$FUND_AMOUNT" | sed 's/[[:space:]]*ether$//I')"

for idx in $(seq 1 "$POOL_SIZE"); do
  echo "[*] creating FAIL pool account $idx/$POOL_SIZE"
  wallet_info="$(make_wallet)"
  addr="$(echo "$wallet_info" | extract_address)"
  key="$(echo "$wallet_info" | extract_private_key)"
  validate_hex_address "$addr" || { echo "[!] invalid FAIL pool address $idx" >&2; exit 1; }
  validate_hex_privkey "$key" || { echo "[!] invalid FAIL pool private key $idx" >&2; exit 1; }

  nonce="$(get_safe_next_nonce "$FUNDER_ADDR" "$L2_RPC_URL")"
  send_json="$(send_funding_tx "$addr" "$FUND_AMOUNT" "$nonce")"
  tx_hash="$(jq -r '.transactionHash // empty' <<<"$send_json")"
  validate_tx_hash "$tx_hash" || { echo "[!] failed to fund FAIL pool account $idx: $send_json" >&2; exit 1; }

  record_used_nonce "$nonce"
  wait_for_receipt_success "$tx_hash" "$L2_RPC_URL"
  wait_for_min_balance "$addr" "$L2_RPC_URL" "$FUND_AMOUNT_NUM"

  {
    echo "export FAIL_ADDR_${idx}=\"$addr\""
    echo "export FAIL_KEY_${idx}=\"$key\""
  } >> "$OUT_ENV"
done

chmod 600 "$OUT_ENV"
echo "[*] wrote FAIL pool env: $OUT_ENV"
