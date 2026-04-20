#!/usr/bin/env bash
set -euo pipefail

L2_RPC_URL="${L2_RPC_URL:-http://127.0.0.1:8547}"
FUNDER_KEY="${FUNDER_KEY:-0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659}"
FUND_AMOUNT="${FUND_AMOUNT:-3ether}"
NONCE_CACHE_FILE="${NONCE_CACHE_FILE:-/tmp/nitro_prepare_accounts_funder_nonce}"
OUT_ENV="${1:-./accounts.env}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }
}

need_cmd cast
need_cmd jq
need_cmd python3
need_cmd sed
need_cmd awk
need_cmd grep

trim() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
extract_address() { awk -F': ' '/Address/ {print $2}' | trim; }
extract_private_key() { awk -F': ' '/Private key/ {print $2}' | trim; }

validate_hex_address() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
validate_hex_privkey() { [[ "$1" =~ ^0x[0-9a-fA-F]{64}$ ]]; }

make_wallet() { cast wallet new 2>/dev/null; }

balance_to_wei() {
  local s="$1"
  if [[ "$s" =~ ^[0-9]+$ ]]; then echo "$s"; return; fi
  python3 - <<PY
from decimal import Decimal
s = """$s""".strip().replace(" ETH", "")
print(int(Decimal(s) * (10 ** 18)))
PY
}

wait_for_receipt_success() {
  local tx_hash="$1"
  local rpc_url="$2"
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

wait_for_min_balance() {
  local addr="$1" rpc_url="$2" min_eth="$3"
  local min_wei
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

rpc_get_nonce_by_tag() {
  local addr="$1" tag="$2" rpc_url="$3"
  local raw
  raw="$(cast rpc eth_getTransactionCount "$addr" "$tag" --rpc-url "$rpc_url" 2>/dev/null | tr -d '"[:space:]')" || true
  [[ "$raw" =~ ^0x[0-9a-fA-F]+$ ]] || { echo ""; return 1; }
  python3 - <<PY
print(int("$raw", 16))
PY
}

get_chain_nonce_max() {
  local addr="$1" rpc_url="$2"
  local latest pending
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
  local addr="$1" rpc_url="$2"
  local chain_nonce cached_next
  chain_nonce="$(get_chain_nonce_max "$addr" "$rpc_url")"
  cached_next="$(get_cached_nonce_plus_one)"
  [[ "$chain_nonce" =~ ^[0-9]+$ ]] || chain_nonce=0
  [[ "$cached_next" =~ ^[0-9]+$ ]] || cached_next=0
  (( cached_next > chain_nonce )) && echo "$cached_next" || echo "$chain_nonce"
}

record_used_nonce() { echo "$1" > "$NONCE_CACHE_FILE"; }
send_funding_tx() {
  local to_addr="$1" amount="$2" nonce="$3"
  cast send "$to_addr" --value "$amount" --private-key "$FUNDER_KEY" --rpc-url "$L2_RPC_URL" --nonce "$nonce" --json
}

FUNDER_ADDR="$(cast wallet address --private-key "$FUNDER_KEY" 2>/dev/null | tr -d '\r\n')"
if ! validate_hex_address "$FUNDER_ADDR"; then
  echo "[!] invalid FUNDER address derived from FUNDER_KEY: '$FUNDER_ADDR'" >&2
  exit 1
fi

touch "$NONCE_CACHE_FILE"

KEEP_INFO="$(make_wallet)"
KEEP_ADDR="$(echo "$KEEP_INFO" | extract_address)"
KEEP_KEY="$(echo "$KEEP_INFO" | extract_private_key)"
FAIL_INFO="$(make_wallet)"
FAIL_ADDR="$(echo "$FAIL_INFO" | extract_address)"
FAIL_KEY="$(echo "$FAIL_INFO" | extract_private_key)"

validate_hex_address "$KEEP_ADDR" || { echo "[!] invalid KEEP address: $KEEP_ADDR" >&2; echo "$KEEP_INFO" >&2; exit 1; }
validate_hex_address "$FAIL_ADDR" || { echo "[!] invalid FAIL address: $FAIL_ADDR" >&2; echo "$FAIL_INFO" >&2; exit 1; }
validate_hex_privkey "$KEEP_KEY" || { echo "[!] invalid KEEP private key: $KEEP_KEY" >&2; echo "$KEEP_INFO" >&2; exit 1; }
validate_hex_privkey "$FAIL_KEY" || { echo "[!] invalid FAIL private key: $FAIL_KEY" >&2; echo "$FAIL_INFO" >&2; exit 1; }

echo "[*] funder address: $FUNDER_ADDR"
echo "[*] funder balance before funding: $(cast balance "$FUNDER_ADDR" --rpc-url "$L2_RPC_URL" 2>/dev/null || echo 0)"

KEEP_NONCE="$(get_safe_next_nonce "$FUNDER_ADDR" "$L2_RPC_URL")"
KEEP_FUND_OUT="$(send_funding_tx "$KEEP_ADDR" "$FUND_AMOUNT" "$KEEP_NONCE" 2>&1)" || { echo "$KEEP_FUND_OUT" >&2; exit 1; }
KEEP_FUND_TX="$(jq -r '.transactionHash // empty' <<<"$KEEP_FUND_OUT" 2>/dev/null || true)"
[[ -n "$KEEP_FUND_TX" ]] || { echo "[!] failed to parse KEEP funding tx hash" >&2; echo "$KEEP_FUND_OUT" >&2; exit 1; }
record_used_nonce "$KEEP_NONCE"
wait_for_receipt_success "$KEEP_FUND_TX" "$L2_RPC_URL"

FAIL_NONCE="$(get_safe_next_nonce "$FUNDER_ADDR" "$L2_RPC_URL")"
FAIL_FUND_OUT="$(send_funding_tx "$FAIL_ADDR" "$FUND_AMOUNT" "$FAIL_NONCE" 2>&1)" || { echo "$FAIL_FUND_OUT" >&2; exit 1; }
FAIL_FUND_TX="$(jq -r '.transactionHash // empty' <<<"$FAIL_FUND_OUT" 2>/dev/null || true)"
[[ -n "$FAIL_FUND_TX" ]] || { echo "[!] failed to parse FAIL funding tx hash" >&2; echo "$FAIL_FUND_OUT" >&2; exit 1; }
record_used_nonce "$FAIL_NONCE"
wait_for_receipt_success "$FAIL_FUND_TX" "$L2_RPC_URL"

FUND_AMOUNT_NUM="$(echo "$FUND_AMOUNT" | sed 's/[[:space:]]*ether$//I')"
wait_for_min_balance "$KEEP_ADDR" "$L2_RPC_URL" "$FUND_AMOUNT_NUM"
wait_for_min_balance "$FAIL_ADDR" "$L2_RPC_URL" "$FUND_AMOUNT_NUM"

cat > "$OUT_ENV" <<EOF
export L2_RPC_URL="$L2_RPC_URL"
export FUNDER_KEY="$FUNDER_KEY"
export KEY_KEEP="$KEEP_KEY"
export ADDR_KEEP="$KEEP_ADDR"
export KEY_FAIL="$FAIL_KEY"
export ADDR_FAIL="$FAIL_ADDR"
export TO_KEEP="0x2222222222222222222222222222222222222222"
export TO_FAIL="0x1111111111111111111111111111111111111111"
EOF
chmod 600 "$OUT_ENV"

echo "[*] accounts prepared"
echo "[*] KEEP address: $KEEP_ADDR"
echo "[*] FAIL address: $FAIL_ADDR"
echo "[*] wrote env file: $OUT_ENV"
