#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/remote_boot.local.env"
TARGET_SCOPE="all"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"
set_log_context "dry_run_remote_boot"

show_help() {
  cat <<EOF
Usage: $0 [options] MODE [TARGET_OR_SERVER_ID ...]

Modes:
  wake        dry-run Wake-on-LAN packet dispatch
  health      dry-run boot health checks for one or more servers
  containers  dry-run container restart and post-check flow
  full        dry-run the full boot orchestration

Options:
  --config PATH         config file path (default: ${CONFIG_FILE})
  --scope VALUE         one of: priority, all (default: all)
  -h, --help            show this help

Examples:
  $0 wake FARM1 LAB1
  $0 health FARM1
  $0 containers FARM1 LAB1
  $0 --scope priority full
EOF
}

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
    --scope)
      if [[ $# -lt 2 ]]; then
        echo "Error: --scope requires a value." >&2
        exit 1
      fi
      TARGET_SCOPE="$2"
      shift 2
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

if [[ $# -lt 1 ]]; then
  show_help
  exit 1
fi

MODE="$1"
shift

if [[ -f "${CONFIG_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
  set +a
fi

load_target_groups
REMOTE_BOOT_TARGETS="${REMOTE_BOOT_TARGETS:-all}"
REMOTE_BOOT_PRIORITY_TARGETS="${REMOTE_BOOT_PRIORITY_TARGETS:-FARM1 LAB1}"

case "${TARGET_SCOPE}" in
  priority)
    default_target_expression="${REMOTE_BOOT_PRIORITY_TARGETS}"
    ;;
  all)
    default_target_expression="${REMOTE_BOOT_TARGETS}"
    ;;
  *)
    echo "Error: --scope must be 'priority' or 'all'." >&2
    exit 1
    ;;
esac

if [[ $# -gt 0 ]]; then
  selected_tokens=("$@")
else
  parse_target_string "${default_target_expression}"
  selected_tokens=("${PARSED_TARGETS[@]}")
fi

expand_target_list "${selected_tokens[@]}"
resolved_targets=("${EXPANDED_TARGETS[@]}")

log_dry_run "mode=${MODE} scope=${TARGET_SCOPE} selected=\"${selected_tokens[*]}\" resolved=\"${resolved_targets[*]}\""

case "${MODE}" in
  wake)
    "${SCRIPT_DIR}/wake_targets.sh" --config "${CONFIG_FILE}" --dry-run "${resolved_targets[@]}"
    ;;
  health)
    for server_id in "${resolved_targets[@]}"; do
      "${SCRIPT_DIR}/check_server_boot_health.sh" --config "${CONFIG_FILE}" --server-id "${server_id}" --dry-run
    done
    ;;
  containers)
    "${SCRIPT_DIR}/restart_all_remote_containers.sh" --config "${CONFIG_FILE}" --dry-run "${resolved_targets[@]}"
    ;;
  full)
    "${SCRIPT_DIR}/run_remote_boot.sh" --config "${CONFIG_FILE}" --dry-run "${resolved_targets[@]}"
    ;;
  *)
    echo "Error: MODE must be one of wake, health, containers, full." >&2
    exit 1
    ;;
esac
