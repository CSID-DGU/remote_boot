#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/remote_boot.local.env"
TIMEOUT_OVERRIDE=""
POLL_OVERRIDE=""

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

show_help() {
  cat <<EOF
Usage: $0 [options] SERVER_ID [SERVER_ID ...]

Options:
  --config PATH           config file path (default: ${CONFIG_FILE})
  --timeout-seconds N     overall timeout for restart completion
  --poll-seconds N        retry interval between attempts
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

REMOTE_BOOT_CONTAINER_RESTART_TIMEOUT_SECONDS="${REMOTE_BOOT_CONTAINER_RESTART_TIMEOUT_SECONDS:-600}"
REMOTE_BOOT_CONTAINER_RESTART_POLL_SECONDS="${REMOTE_BOOT_CONTAINER_RESTART_POLL_SECONDS:-20}"

if [[ -n "${TIMEOUT_OVERRIDE}" ]]; then
  REMOTE_BOOT_CONTAINER_RESTART_TIMEOUT_SECONDS="${TIMEOUT_OVERRIDE}"
fi

if [[ -n "${POLL_OVERRIDE}" ]]; then
  REMOTE_BOOT_CONTAINER_RESTART_POLL_SECONDS="${POLL_OVERRIDE}"
fi

if ! [[ "${REMOTE_BOOT_CONTAINER_RESTART_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || ! [[ "${REMOTE_BOOT_CONTAINER_RESTART_POLL_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "Error: restart timeout and poll interval must be numeric." >&2
  exit 1
fi

load_remote_boot_runtime

require_ansible_cli || exit 1
require_ansible_inventory || exit 1

restart_remote_containers() {
  local host_alias="$1"
  local remote_command='container_ids=$(docker ps -aq); if [ -n "$container_ids" ]; then docker restart $container_ids; else echo "No containers to restart"; fi'

  run_remote_shell "${host_alias}" "${remote_command}"
}

declare -a pending_servers=("$@")
declare -a restarted_servers=()
deadline=$((SECONDS + REMOTE_BOOT_CONTAINER_RESTART_TIMEOUT_SECONDS))
attempt=1

while [[ ${#pending_servers[@]} -gt 0 ]]; do
  declare -a next_pending=()

  echo "Container restart attempt ${attempt}: ${pending_servers[*]}"
  for server_id in "${pending_servers[@]}"; do
    read domain_name server_number <<<"$(split_server_id "${server_id}")" || exit 1
    server_number="$(validate_server_number "${server_number}")" || exit 1
    host_alias="$(compose_ansible_host_alias "${domain_name}" "${server_number}")"
    ensure_ansible_host_exists "${host_alias}" || exit 1

    if restart_remote_containers "${host_alias}"; then
      restarted_servers+=("${server_id}")
    else
      next_pending+=("${server_id}")
    fi
  done

  if [[ ${#next_pending[@]} -eq 0 ]]; then
    echo "Docker containers restarted on: ${restarted_servers[*]}"
    exit 0
  fi

  pending_servers=("${next_pending[@]}")
  remaining_time=$((deadline - SECONDS))
  if (( remaining_time <= 0 )); then
    echo "Timed out while restarting containers on: ${pending_servers[*]}" >&2
    exit 1
  fi

  sleep_for="${REMOTE_BOOT_CONTAINER_RESTART_POLL_SECONDS}"
  if (( sleep_for > remaining_time )); then
    sleep_for="${remaining_time}"
  fi

  echo "Pending container restarts: ${pending_servers[*]} (retrying in ${sleep_for}s)"
  sleep "${sleep_for}"
  attempt=$((attempt + 1))
done
