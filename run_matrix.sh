#!/usr/bin/env bash
set -euo pipefail

MATRIX_JSON="${1:-./experiment_matrix.json}"
OUT_DIR="${2:-./exp_out}"
ACCOUNTS_DIR="${ACCOUNTS_DIR:-./accounts_pool}"
NODE1_BOOTSTRAP_CMD="${NODE1_BOOTSTRAP_CMD:-}"

mkdir -p "$OUT_DIR"
./prepare_accounts_pool.sh "$MATRIX_JSON" "$ACCOUNTS_DIR"

jq -r '.[].name' "$MATRIX_JSON" | while read -r case_name; do
  echo "[*] running case: $case_name"
  ./run_case.sh "$MATRIX_JSON" "$case_name" "$ACCOUNTS_DIR/$case_name.env" "$OUT_DIR"
done

echo "[*] all cases finished, output in $OUT_DIR"
