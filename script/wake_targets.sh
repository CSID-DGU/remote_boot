#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/remote_boot.local.env"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

show_help() {
  cat <<'EOF'
Usage: wake_targets.sh [--config PATH] [--list-targets] TARGET [TARGET ...]

Targets:
  FARM1 FARM2 FARM6 FARM7 FARM8 FARM9
  LAB1 LAB2 LAB3 LAB4 LAB5 LAB6 LAB7 LAB8 LAB9
  all-farm all-lab all

Examples:
  wake_targets.sh FARM1
  wake_targets.sh all-farm
  wake_targets.sh LAB1 LAB2

Broadcast IP defaults:
  FARM* -> 192.168.2.255
  LAB*  -> 192.168.1.255

Environment overrides:
  REMOTE_BOOT_FARM_BROADCAST_IP
  REMOTE_BOOT_LAB_BROADCAST_IP
  REMOTE_BOOT_MAC_<TARGET>
EOF
}

list_targets() {
  printf '%s\n' "${FARM_TARGETS[@]:-}"
  printf '%s\n' "${LAB_TARGETS[@]:-}"
  printf '%s\n' all-farm all-lab all
}

load_config() {
  if [[ -f "${CONFIG_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
    set +a
  fi
}

send_magic_packet() {
  local name="$1"
  local mac="$2"
  local broadcast_ip="$3"

  echo "Waking ${name} (${mac}) via ${broadcast_ip}"
  wakeonlan -i "${broadcast_ip}" "${mac}"
}

wake_named_targets() {
  local name

  for name in "$@"; do
    send_magic_packet "${name}" "$(lookup_mac "${name}")" "$(lookup_broadcast_ip "${name}")"
  done
}

wlookup_error() {
  local normalized_target="$1"

  echo "Error: unknown target '${normalized_target}'." >&2
  show_help >&2
  exit 1
}

lookup_mac() {
  local normalized_target="$1"
  local mac_var="REMOTE_BOOT_MAC_${normalized_target}"
  local mac_value="${!mac_var:-}"

  if [[ -z "${mac_value}" ]]; then
    echo "Error: MAC address is not configured for ${normalized_target} (${mac_var})." >&2
    exit 1
  fi

  printf '%s\n' "${mac_value}"
}

lookup_broadcast_ip() {
  local normalized_target="$1"

  case "${normalized_target}" in
    FARM*)
      printf '%s\n' "${REMOTE_BOOT_FARM_BROADCAST_IP}"
      ;;
    LAB*)
      printf '%s\n' "${REMOTE_BOOT_LAB_BROADCAST_IP}"
      ;;
    *)
      wlookup_error "${normalized_target}"
      ;;
  esac
}

wake_target() {
  local normalized_target="$1"

  case "${normalized_target}" in
    all-farm)
      wake_named_targets "${FARM_TARGETS[@]}"
      ;;
    all-lab)
      wake_named_targets "${LAB_TARGETS[@]}"
      ;;
    all)
      wake_named_targets "${ALL_TARGETS[@]}"
      ;;
    *)
      wake_named_targets "${normalized_target}"
      ;;
  esac
}

main() {
  local list_only=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        if [[ $# -lt 2 ]]; then
          echo "Error: --config requires a value." >&2
          exit 1
        fi
        CONFIG_FILE="$2"
        shift 2
        ;;
      --list-targets)
        list_only=true
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "Unknown option: $1" >&2
        exit 1
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        break
        ;;
    esac
  done

  require_command "wakeonlan" "Install it with: sudo apt install wakeonlan"
  load_config
  load_target_groups
  REMOTE_BOOT_FARM_BROADCAST_IP="${REMOTE_BOOT_FARM_BROADCAST_IP:-192.168.2.255}"
  REMOTE_BOOT_LAB_BROADCAST_IP="${REMOTE_BOOT_LAB_BROADCAST_IP:-192.168.1.255}"

  if [[ "${list_only}" == "true" ]]; then
    list_targets
    exit 0
  fi

  if [[ $# -eq 0 ]]; then
    show_help
    exit 1
  fi

  local raw_target normalized_target
  for raw_target in "$@"; do
    normalized_target="$(normalize_target "${raw_target}")"
    wake_target "${normalized_target}"
  done
}

main "$@"
