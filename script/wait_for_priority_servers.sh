#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/remote_boot.local.env"
TIMEOUT_OVERRIDE=""
POLL_OVERRIDE=""
DRY_RUN=false

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"
set_log_context "wait_for_priority_servers"

show_help() {
  cat <<EOF
Usage: $0 [options] SERVER_ID [SERVER_ID ...]

Options:
  --config PATH           config file path (default: ${CONFIG_FILE})
  --timeout-seconds N     overall timeout for all checks
  --poll-seconds N        wait between retries
  --dry-run               print the gate flow without executing health checks
  -h, --help              show this help
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
    --timeout-seconds)
      if [[ $# -lt 2 ]]; then
        echo "Error: --timeout-seconds requires a value." >&2
        exit 1
      fi
      TIMEOUT_OVERRIDE="$2"
      shift 2
      ;;
    --poll-seconds)
      if [[ $# -lt 2 ]]; then
        echo "Error: --poll-seconds requires a value." >&2
        exit 1
      fi
      POLL_OVERRIDE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
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

if [[ $# -eq 0 ]]; then
  echo "Error: at least one SERVER_ID is required." >&2
  exit 1
fi

if [[ -f "${CONFIG_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
  set +a
fi

if is_truthy "${DRY_RUN}"; then
  export REMOTE_BOOT_DRY_RUN=true
fi

REMOTE_BOOT_GATE_TIMEOUT_SECONDS="${REMOTE_BOOT_GATE_TIMEOUT_SECONDS:-360}"
REMOTE_BOOT_GATE_POLL_SECONDS="${REMOTE_BOOT_GATE_POLL_SECONDS:-20}"
CHECK_SCRIPT="${REMOTE_BOOT_HEALTH_CHECK_SCRIPT:-${SCRIPT_DIR}/check_server_boot_health.sh}"

if [[ -n "${TIMEOUT_OVERRIDE}" ]]; then
  REMOTE_BOOT_GATE_TIMEOUT_SECONDS="${TIMEOUT_OVERRIDE}"
fi

if [[ -n "${POLL_OVERRIDE}" ]]; then
  REMOTE_BOOT_GATE_POLL_SECONDS="${POLL_OVERRIDE}"
fi

if ! [[ "${REMOTE_BOOT_GATE_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || ! [[ "${REMOTE_BOOT_GATE_POLL_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "Error: gate timeout and poll values must be numeric." >&2
  exit 1
fi

if [[ "${CHECK_SCRIPT}" != /* ]]; then
  CHECK_SCRIPT="$(cd "${PROJECT_ROOT}" && cd "$(dirname "${CHECK_SCRIPT}")" && pwd)/$(basename "${CHECK_SCRIPT}")"
fi

if dry_run_enabled; then
  log_dry_run "action=gate_plan targets=\"$*\" timeout_seconds=${REMOTE_BOOT_GATE_TIMEOUT_SECONDS} poll_seconds=${REMOTE_BOOT_GATE_POLL_SECONDS}"
  for server_id in "$@"; do
    "${CHECK_SCRIPT}" --config "${CONFIG_FILE}" --server-id "${server_id}" --dry-run
  done
  log_event "GATE" "status=dry_run_completed servers=\"$*\""
  exit 0
fi

declare -a pending_servers=("$@")
declare -a passed_servers=()
deadline=$((SECONDS + REMOTE_BOOT_GATE_TIMEOUT_SECONDS))
attempt=1

while [[ ${#pending_servers[@]} -gt 0 ]]; do
  declare -a next_pending=()

  log_event "GATE" "attempt=${attempt} pending=\"${pending_servers[*]}\""
  for server_id in "${pending_servers[@]}"; do
    remaining_time=$((deadline - SECONDS))
    if (( remaining_time <= 0 )); then
      log_error "gate_timeout pending=\"${pending_servers[*]}\""
      exit 1
    fi

    if command -v timeout >/dev/null 2>&1; then
      if timeout "${remaining_time}" "${CHECK_SCRIPT}" --config "${CONFIG_FILE}" --server-id "${server_id}"; then
        check_status=0
      else
        check_status=$?
      fi
    else
      if "${CHECK_SCRIPT}" --config "${CONFIG_FILE}" --server-id "${server_id}"; then
        check_status=0
      else
        check_status=$?
      fi
    fi

    if [[ ${check_status} -eq 0 ]]; then
      passed_servers+=("${server_id}")
    else
      next_pending+=("${server_id}")
    fi
  done

  if [[ ${#next_pending[@]} -eq 0 ]]; then
    log_event "GATE" "status=passed servers=\"${passed_servers[*]}\""
    exit 0
  fi

  pending_servers=("${next_pending[@]}")
  remaining_time=$((deadline - SECONDS))
  if (( remaining_time <= 0 )); then
    log_error "gate_timeout pending=\"${pending_servers[*]}\""
    exit 1
  fi

  sleep_for="${REMOTE_BOOT_GATE_POLL_SECONDS}"
  if (( sleep_for > remaining_time )); then
    sleep_for="${remaining_time}"
  fi

  log_event "GATE" "status=pending servers=\"${pending_servers[*]}\" retry_in_seconds=${sleep_for}"
  sleep "${sleep_for}"
  attempt=$((attempt + 1))
done
