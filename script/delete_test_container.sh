#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/remote_boot.local.env"
SERVER_ID_INPUT=""
CONTAINER_NAME_OVERRIDE=""
DRY_RUN=false

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"
set_log_context "delete_test_container"

show_help() {
  cat <<EOF
Usage: $0 [options] --server-id SERVER_ID

Options:
  --config PATH           config file path (default: ${CONFIG_FILE})
  --server-id SERVER_ID   target server id, for example FARM1 or LAB1
  --container-name NAME   override test container name
  --dry-run               print the delete command without running it
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
    --server-id)
      if [[ $# -lt 2 ]]; then
        echo "Error: --server-id requires a value." >&2
        exit 1
      fi
      SERVER_ID_INPUT="$2"
      shift 2
      ;;
    --container-name)
      if [[ $# -lt 2 ]]; then
        echo "Error: --container-name requires a value." >&2
        exit 1
      fi
      CONTAINER_NAME_OVERRIDE="$2"
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
      echo "Unknown option: $1" >&2
      show_help
      exit 1
      ;;
  esac
done

if [[ -z "${SERVER_ID_INPUT}" ]]; then
  echo "Error: --server-id is required." >&2
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

load_remote_boot_runtime

REMOTE_BOOT_TEST_CONTAINER_NAME_PREFIX="${REMOTE_BOOT_TEST_CONTAINER_NAME_PREFIX:-boot_test_probe}"

require_ansible_cli || exit 1
require_ansible_inventory || exit 1

read domain_name server_number <<<"$(split_server_id "${SERVER_ID_INPUT}")" || exit 1
server_number="$(validate_server_number "${server_number}")" || exit 1
target_host="$(compose_ansible_host_alias "${domain_name}" "${server_number}")"
ensure_ansible_host_exists "${target_host}" || exit 1

container_name="${CONTAINER_NAME_OVERRIDE:-$(printf '%s_%s' "${REMOTE_BOOT_TEST_CONTAINER_NAME_PREFIX}" "${SERVER_ID_INPUT}" | tr '[:upper:]' '[:lower:]')}"
log_event_stderr "CONTAINER" "server=${SERVER_ID_INPUT} action=delete_start host=${target_host} container=${container_name}"

if dry_run_enabled; then
  log_dry_run "server=${SERVER_ID_INPUT} action=delete_plan host=${target_host} container=${container_name} command=\"docker rm -f '${container_name}' >/dev/null 2>&1 || true\""
  exit 0
fi

run_remote_shell "${target_host}" "docker rm -f '${container_name}' >/dev/null 2>&1 || true" >/dev/null
log_event_stderr "CONTAINER" "server=${SERVER_ID_INPUT} action=delete_complete host=${target_host} container=${container_name}"
