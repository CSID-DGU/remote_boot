#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/remote_boot.local.env"
RESET_ALL=false
SERVER_ID=""
STAGE_NAME=""
REASON_NAME=""
MATCH_TEXT=""

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"
set_log_context "reset_remote_boot_alert_state"

show_help() {
  cat <<EOF
Usage: $0 [options]

Options:
  --config PATH       config file path (default: ${CONFIG_FILE})
  --all               clear every stored alert state
  --server-id ID      clear alerts for a specific server
  --stage NAME        clear alerts for a specific stage
  --reason NAME       clear alerts for a specific reason
  --match TEXT        clear alerts whose stored message contains TEXT
  -h, --help          show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --all)
      RESET_ALL=true
      shift
      ;;
    --server-id)
      SERVER_ID="$2"
      shift 2
      ;;
    --stage)
      STAGE_NAME="$2"
      shift 2
      ;;
    --reason)
      REASON_NAME="$2"
      shift 2
      ;;
    --match)
      MATCH_TEXT="$2"
      shift 2
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

state_dir="$(alert_state_dir)"
mkdir -p "${state_dir}"

if is_truthy "${RESET_ALL}"; then
  find "${state_dir}" -type f -name '*.state' -delete
  log_event "ALERT" "reset=true scope=all state_dir=${state_dir}"
  exit 0
fi

declare -a match_filters=()

if [[ -n "${SERVER_ID}" ]]; then
  match_filters+=("server=${SERVER_ID}")
fi

if [[ -n "${STAGE_NAME}" ]]; then
  match_filters+=("stage=${STAGE_NAME}")
fi

if [[ -n "${REASON_NAME}" ]]; then
  match_filters+=("reason=${REASON_NAME}")
fi

if [[ -n "${MATCH_TEXT}" ]]; then
  match_filters+=("${MATCH_TEXT}")
fi

if [[ ${#match_filters[@]} -eq 0 ]]; then
  echo "Error: provide --all or at least one filter option." >&2
  exit 1
fi

shopt -s nullglob
state_files=("${state_dir}"/*.state)
shopt -u nullglob

cleared_count=0
for state_file in "${state_files[@]}"; do
  stored_message="$(sed -n 's/^message=//p' "${state_file}" | head -n 1)"
  [[ -n "${stored_message}" ]] || continue

  matches_all=true
  for filter_text in "${match_filters[@]}"; do
    if [[ "${stored_message}" != *"${filter_text}"* ]]; then
      matches_all=false
      break
    fi
  done

  if is_truthy "${matches_all}"; then
    rm -f "${state_file}"
    cleared_count=$((cleared_count + 1))
  fi
done

log_event "ALERT" "reset=true cleared=${cleared_count} filters=\"${match_filters[*]}\" state_dir=${state_dir}"
