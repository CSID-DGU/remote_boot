#!/bin/bash

set -euo pipefail

declare -ar FARM_TARGETS=(FARM1 FARM2 FARM6 FARM7 FARM8 FARM9)
declare -ar LAB_TARGETS=(LAB1 LAB2 LAB3 LAB4 LAB5 LAB6 LAB7 LAB8 LAB9)
declare -ar ALL_TARGETS=("${FARM_TARGETS[@]}" "${LAB_TARGETS[@]}")

show_help() {
  cat <<'EOF'
Usage: wake_targets.sh [--list-targets] TARGET [TARGET ...]

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
EOF
}

list_targets() {
  printf '%s\n' "${FARM_TARGETS[@]}"
  printf '%s\n' "${LAB_TARGETS[@]}"
  printf '%s\n' all-farm all-lab all
}

normalize_target() {
  local raw_target="$1"

  case "${raw_target}" in
    all | all-farm | all-lab)
      printf '%s\n' "${raw_target}"
      ;;
    *)
      printf '%s\n' "$(printf '%s' "${raw_target}" | tr '[:lower:]' '[:upper:]')"
      ;;
  esac
}

require_command() {
  local cmd="$1"
  local hint="$2"

  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Error: '${cmd}' command not found. ${hint}" >&2
    exit 1
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

  case "${normalized_target}" in
    FARM1) printf '%s\n' "18:C0:4D:4C:B3:13" ;;
    FARM2) printf '%s\n' "18:C0:4D:4C:B3:D5" ;;
    FARM6) printf '%s\n' "3C:EC:EF:9E:03:FF" ;;
    FARM7) printf '%s\n' "3C:EC:EF:92:2E:29" ;;
    FARM8) printf '%s\n' "A0:36:BC:C8:44:6E" ;;
    FARM9) printf '%s\n' "74:56:3C:4C:93:7C" ;;
    LAB1) printf '%s\n' "50:EB:F6:51:E6:9C" ;;
    LAB2) printf '%s\n' "A0:42:3F:3D:05:EB" ;;
    LAB3) printf '%s\n' "A0:42:3F:3D:07:13" ;;
    LAB4) printf '%s\n' "A0:42:3F:3A:4D:B9" ;;
    LAB5) printf '%s\n' "7C:C2:55:6B:45:98" ;;
    LAB6) printf '%s\n' "A0:42:3F:3D:06:D3" ;;
    LAB7) printf '%s\n' "B4:2E:99:A2:30:FE" ;;
    LAB8) printf '%s\n' "A0:42:3F:3D:99:23" ;;
    LAB9) printf '%s\n' "74:56:3C:B4:3B:C4" ;;
    *)
      wlookup_error "${normalized_target}"
      ;;
  esac
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
  if [[ $# -eq 0 ]]; then
    show_help
    exit 1
  fi

  if [[ "$1" == "--list-targets" ]]; then
    list_targets
    exit 0
  fi

  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
    exit 0
  fi

  require_command "wakeonlan" "Install it with: sudo apt install wakeonlan"
  REMOTE_BOOT_FARM_BROADCAST_IP="${REMOTE_BOOT_FARM_BROADCAST_IP:-192.168.2.255}"
  REMOTE_BOOT_LAB_BROADCAST_IP="${REMOTE_BOOT_LAB_BROADCAST_IP:-192.168.1.255}"

  local raw_target normalized_target
  for raw_target in "$@"; do
    normalized_target="$(normalize_target "${raw_target}")"
    wake_target "${normalized_target}"
  done
}

main "$@"
