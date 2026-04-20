#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
FAULT="${2:-none}"
STATUS_DIR="${3:-./.fault_status}"

NODE2_SSH="${NODE2_SSH:-root@192.168.1.13}"
NODE3_SSH="${NODE3_SSH:-root@192.168.1.6}"
NODE4_SSH="${NODE4_SSH:-root@192.168.1.4}"
SSH_PASSWORD="${SSH_PASSWORD:-}"

NODE2_START_CMD="${NODE2_START_CMD:-bash /data/node2_start.sh}"
NODE3_START_CMD="${NODE3_START_CMD:-bash /data/node3_start.sh}"
NODE4_START_CMD="${NODE4_START_CMD:-bash /data/node4_start.sh}"
FAULT_NETDEV="${FAULT_NETDEV:-}"

mkdir -p "$STATUS_DIR"

safe_fault_name() { echo "$1" | sed 's#[/:, ]#_#g'; }
FAULT_KEY="$(safe_fault_name "$FAULT")"
STATUS_FILE="$STATUS_DIR/${FAULT_KEY}.status"

ssh_node() {
  local target="$1"
  shift
  local ssh_cmd=(ssh -o StrictHostKeyChecking=no -n)
  if [[ -n "$SSH_PASSWORD" ]]; then
    if ! command -v sshpass >/dev/null 2>&1; then
      echo "sshpass is required when SSH_PASSWORD is set" >&2
      exit 1
    fi
    sshpass -p "$SSH_PASSWORD" "${ssh_cmd[@]}" "$target" "$@"
  else
    "${ssh_cmd[@]}" "$target" "$@"
  fi
}

ssh_node_with_stdin() {
  local target="$1"
  shift
  if [[ -n "$SSH_PASSWORD" ]]; then
    if ! command -v sshpass >/dev/null 2>&1; then
      echo "sshpass is required when SSH_PASSWORD is set" >&2
      exit 1
    fi
    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no "$target" "$@"
  else
    ssh -o StrictHostKeyChecking=no "$target" "$@"
  fi
}

node_ssh() {
  case "$1" in
    node-2) echo "$NODE2_SSH" ;;
    node-3) echo "$NODE3_SSH" ;;
    node-4) echo "$NODE4_SSH" ;;
    *) return 1 ;;
  esac
}

node_restart_cmd() {
  case "$1" in
    node-2) echo "$NODE2_START_CMD" ;;
    node-3) echo "$NODE3_START_CMD" ;;
    node-4) echo "$NODE4_START_CMD" ;;
    *) return 1 ;;
  esac
}

detect_netdev() {
  local host="$1"
  local dev=""
  if [[ -n "$FAULT_NETDEV" ]]; then
    echo "$FAULT_NETDEV"
    return 0
  fi

  dev=$(
    ssh_node_with_stdin "$host" sh -s 2>/dev/null <<'EOF' || true
if ip -o route show default >/dev/null 2>&1; then
  ip -o route show default | awk 'NR==1{print $5; exit}'
else
  ip -o -4 route get 1.1.1.1 | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}'
fi
EOF
  )

  if [[ -z "$dev" ]]; then
    echo "eth0"
  else
    echo "$dev"
  fi
}

write_status() {
  local status="$1"
  local msg="${2:-}"
  cat > "$STATUS_FILE" <<EOF
status=$status
fault=$FAULT
message=$msg
timestamp=$(date +%s)
EOF
}

if [[ "$FAULT" == "none" ]]; then
  write_status "noop" "no fault requested"
  exit 0
fi

if [[ "$ACTION" == "apply" ]]; then
  rm -f "$STATUS_FILE"

  if [[ "$FAULT" =~ ^delay:([^:]+):([^:]+)$ ]]; then
    node="${BASH_REMATCH[1]}"
    delay="${BASH_REMATCH[2]}"
    target="$(node_ssh "$node")"
    ms="${delay%ms}"
    netdev="$(detect_netdev "$target")"
    ssh_node "$target" "tc qdisc del dev '$netdev' root 2>/dev/null || true; tc qdisc add dev '$netdev' root netem delay ${ms}ms"
    write_status "applied" "delay ${ms}ms applied to ${node}"
    echo "[*] applied delay fault: ${node} ${ms}ms on ${netdev}"
    exit 0
  fi

  if [[ "$FAULT" =~ ^down:(.+)$ ]]; then
    IFS=',' read -ra ARR <<< "${BASH_REMATCH[1]}"
    for node in "${ARR[@]}"; do
      target="$(node_ssh "$node")"
      ssh_node "$target" "pkill -f '/data/endorsement/bin/endorser' || true; pkill -f '/data/endorsement/bin/nitro-val' || true"
    done
    write_status "applied" "nodes stopped: ${BASH_REMATCH[1]}"
    echo "[*] applied down fault: ${BASH_REMATCH[1]}"
    exit 0
  fi

  echo "unsupported apply fault: $FAULT" >&2
  write_status "failed" "unsupported apply fault syntax"
  exit 2
fi

if [[ "$ACTION" == "clear" ]]; then
  if [[ "$FAULT" =~ ^delay:([^:]+):([^:]+)$ ]]; then
    node="${BASH_REMATCH[1]}"
    target="$(node_ssh "$node")"
    netdev="$(detect_netdev "$target")"
    ssh_node "$target" "tc qdisc del dev '$netdev' root 2>/dev/null || true"
    write_status "cleared" "delay cleared for ${node}"
    echo "[*] cleared delay fault for ${node} on ${netdev}"
    exit 0
  fi

  if [[ "$FAULT" =~ ^down:(.+)$ ]]; then
    IFS=',' read -ra ARR <<< "${BASH_REMATCH[1]}"
    for node in "${ARR[@]}"; do
      target="$(node_ssh "$node")"
      restart_cmd="$(node_restart_cmd "$node")"
      ssh_node "$target" "$restart_cmd"
    done
    write_status "cleared" "nodes restarted: ${BASH_REMATCH[1]}"
    echo "[*] cleared down fault for ${BASH_REMATCH[1]}"
    exit 0
  fi

  echo "unsupported clear fault: $FAULT" >&2
  write_status "failed" "unsupported clear fault syntax"
  exit 2
fi

echo "unsupported action/fault: $ACTION $FAULT" >&2
write_status "failed" "unsupported action ${ACTION}"
exit 2
