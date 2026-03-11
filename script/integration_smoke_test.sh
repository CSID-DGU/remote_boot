#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/remote_boot.local.env"
RUN_FULL_FLOW=false
TARGET_SCOPE="priority"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

declare -ar FARM_TARGETS=(FARM1 FARM2 FARM6 FARM7 FARM8 FARM9)
declare -ar LAB_TARGETS=(LAB1 LAB2 LAB3 LAB4 LAB5 LAB6 LAB7 LAB8 LAB9 LAB10)
declare -ar ALL_TARGETS=("${FARM_TARGETS[@]}" "${LAB_TARGETS[@]}")

show_help() {
  cat <<EOF
Usage: $0 [options]

Options:
  --config PATH      config file path (default: ${CONFIG_FILE})
  --scope VALUE      one of: priority, all
  --full-flow        also run run_remote_boot.sh for the selected scope
  -h, --help         show this help

This script does not send Wake-on-LAN packets unless --full-flow is used.
EOF
}

parse_target_string() {
  local raw_targets="$1"
  local normalized="${raw_targets//,/ }"

  read -r -a PARSED_TARGETS <<< "${normalized}"
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

append_unique_target() {
  local target="$1"
  local existing

  for existing in "${EXPANDED_TARGETS[@]:-}"; do
    if [[ "${existing}" == "${target}" ]]; then
      return 0
    fi
  done

  EXPANDED_TARGETS+=("${target}")
}

expand_target_token() {
  local normalized_target
  local target

  normalized_target="$(normalize_target "$1")"

  case "${normalized_target}" in
    all-farm)
      for target in "${FARM_TARGETS[@]}"; do
        append_unique_target "${target}"
      done
      ;;
    all-lab)
      for target in "${LAB_TARGETS[@]}"; do
        append_unique_target "${target}"
      done
      ;;
    all)
      for target in "${ALL_TARGETS[@]}"; do
        append_unique_target "${target}"
      done
      ;;
    *)
      append_unique_target "${normalized_target}"
      ;;
  esac
}

expand_target_list() {
  EXPANDED_TARGETS=()

  local token
  for token in "$@"; do
    expand_target_token "${token}"
  done
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
    --full-flow)
      RUN_FULL_FLOW=true
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      show_help
      exit 1
      ;;
  esac
done

if [[ -f "${CONFIG_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
  set +a
fi

load_remote_boot_runtime
require_ansible_cli || exit 1
require_ansible_inventory || exit 1

REMOTE_BOOT_TARGETS="${REMOTE_BOOT_TARGETS:-all}"
REMOTE_BOOT_PRIORITY_TARGETS="${REMOTE_BOOT_PRIORITY_TARGETS:-FARM1 LAB1}"

case "${TARGET_SCOPE}" in
  priority)
    target_list="${REMOTE_BOOT_PRIORITY_TARGETS}"
    ;;
  all)
    target_list="${REMOTE_BOOT_TARGETS}"
    ;;
  *)
    echo "Error: --scope must be 'priority' or 'all'." >&2
    exit 1
    ;;
esac

parse_target_string "${target_list}"
expand_target_list "${PARSED_TARGETS[@]}"
selected_server_ids=("${EXPANDED_TARGETS[@]}")
selected_hosts=()

for server_id in "${selected_server_ids[@]}"; do
  read domain_name server_number <<<"$(split_server_id "${server_id}")" || exit 1
  selected_hosts+=("$(compose_ansible_host_alias "${domain_name}" "${server_number}")")
done

echo "Selected scope: ${TARGET_SCOPE}"
echo "Targets: ${selected_server_ids[*]}"
echo
echo "1. Direct ansible connectivity"
for host_alias in "${selected_hosts[@]}"; do
  run_ansible "${host_alias}" -m ping
done
echo
echo "2. Host docker availability"
for host_alias in "${selected_hosts[@]}"; do
  run_ansible "${host_alias}" -m shell -a "docker version --format '{{.Server.Version}}'"
done
echo
echo "3. Host GPU availability"
for host_alias in "${selected_hosts[@]}"; do
  run_ansible "${host_alias}" -m shell -a "nvidia-smi --query-gpu=name,driver_version --format=csv,noheader"
done
echo
echo "4. Boot health checks"
"${SCRIPT_DIR}/wait_for_priority_servers.sh" --config "${CONFIG_FILE}" "${selected_server_ids[@]}"

if [[ "${RUN_FULL_FLOW}" == "true" ]]; then
  echo
  echo "5. Full remote boot flow"
  "${SCRIPT_DIR}/run_remote_boot.sh" --config "${CONFIG_FILE}" "${selected_server_ids[@]}"
fi
