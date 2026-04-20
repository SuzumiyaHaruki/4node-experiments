#!/usr/bin/env bash
set -euo pipefail

MATRIX_JSON="${1:-./experiment_matrix.json}"
OUT_DIR="${2:-./accounts_pool}"
FUND_AMOUNT="${FUND_AMOUNT:-3ether}"
NONCE_CACHE_FILE="${NONCE_CACHE_FILE:-/tmp/nitro_prepare_accounts_funder_nonce}"
KEEP_NONCE_CACHE="${KEEP_NONCE_CACHE:-0}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }
}

need_cmd jq
need_cmd bash

mkdir -p "$OUT_DIR"

if [[ "$KEEP_NONCE_CACHE" != "1" ]]; then
  rm -f "$NONCE_CACHE_FILE"
fi

jq -r '.[].name' "$MATRIX_JSON" | while read -r case_name; do
  out_env="${OUT_DIR}/${case_name}.env"
  echo "[*] preparing account file for case=$case_name -> $out_env"
  FUND_AMOUNT="$FUND_AMOUNT" NONCE_CACHE_FILE="$NONCE_CACHE_FILE" ./prepare_accounts.sh "$out_env"
done

echo "[*] all case-specific accounts prepared in $OUT_DIR"
