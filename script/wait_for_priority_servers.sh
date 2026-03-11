#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/remote_boot.local.env"
TIMEOUT_OVERRIDE=""
POLL_OVERRIDE=""

show_help() {
  cat <<EOF
Usage: $0 [options] SERVER_ID [SERVER_ID ...]

Options:
  --config PATH           config file path (default: ${CONFIG_FILE})
  --timeout-seconds N     overall timeout for all checks
  --poll-seconds N        wait between retries
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

declare -a pending_servers=("$@")
declare -a passed_servers=()
deadline=$((SECONDS + REMOTE_BOOT_GATE_TIMEOUT_SECONDS))
attempt=1

while [[ ${#pending_servers[@]} -gt 0 ]]; do
  declare -a next_pending=()

  echo "Priority gate attempt ${attempt}: ${pending_servers[*]}"
  for server_id in "${pending_servers[@]}"; do
    remaining_time=$((deadline - SECONDS))
    if (( remaining_time <= 0 )); then
      echo "Timed out while waiting for priority servers: ${pending_servers[*]}" >&2
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
    echo "Priority servers passed boot health checks: ${passed_servers[*]}"
    exit 0
  fi

  pending_servers=("${next_pending[@]}")
  remaining_time=$((deadline - SECONDS))
  if (( remaining_time <= 0 )); then
    echo "Timed out while waiting for priority servers: ${pending_servers[*]}" >&2
    exit 1
  fi

  sleep_for="${REMOTE_BOOT_GATE_POLL_SECONDS}"
  if (( sleep_for > remaining_time )); then
    sleep_for="${remaining_time}"
  fi

  echo "Pending priority servers: ${pending_servers[*]} (retrying in ${sleep_for}s)"
  sleep "${sleep_for}"
  attempt=$((attempt + 1))
done
