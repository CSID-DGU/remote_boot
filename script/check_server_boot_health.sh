#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/remote_boot.local.env"
SERVER_ID_INPUT=""

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

show_help() {
  cat <<EOF
Usage: $0 [options] --server-id SERVER_ID

Options:
  --config PATH         config file path (default: ${CONFIG_FILE})
  --server-id SERVER_ID target server id, for example FARM1 or LAB1
  -h, --help            show this help
EOF
}

log_step() {
  printf '[%s] %s\n' "${SERVER_ID_INPUT}" "$*"
}

cleanup_test_container() {
  if [[ -n "${SERVER_ID_INPUT:-}" && -n "${test_container_name:-}" && -x "${DELETE_TEST_SCRIPT:-}" ]]; then
    bash "${DELETE_TEST_SCRIPT}" \
      --config "${CONFIG_FILE}" \
      --server-id "${SERVER_ID_INPUT}" \
      --container-name "${test_container_name}" >/dev/null 2>&1 || true
  fi
}

retry_remote_step() {
  local description="$1"
  local remote_command="$2"
  local timeout_seconds="$3"
  local poll_seconds="$4"
  local deadline=$((SECONDS + timeout_seconds))
  local attempt=1

  while true; do
    log_step "${description} (attempt ${attempt})"
    if run_remote_shell "${target_host}" "${remote_command}"; then
      return 0
    fi

    if (( SECONDS >= deadline )); then
      log_step "Timed out while waiting for: ${description}"
      return 1
    fi

    sleep "${poll_seconds}"
    attempt=$((attempt + 1))
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
    --server-id)
      if [[ $# -lt 2 ]]; then
        echo "Error: --server-id requires a value." >&2
        exit 1
      fi
      SERVER_ID_INPUT="$2"
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

load_remote_boot_runtime

CREATE_TEST_SCRIPT="${SCRIPT_DIR}/create_test_container.sh"
DELETE_TEST_SCRIPT="${SCRIPT_DIR}/delete_test_container.sh"

for required_file in "${CREATE_TEST_SCRIPT}" "${DELETE_TEST_SCRIPT}"; do
  if [[ ! -x "${required_file}" ]]; then
    echo "Error: required file not found: ${required_file}" >&2
    exit 1
  fi
done

REMOTE_BOOT_LAB_REQUIRED_MOUNT="${REMOTE_BOOT_LAB_REQUIRED_MOUNT:-100.100.100.100:/294t/dcloud/share}"
REMOTE_BOOT_FARM_REQUIRED_MOUNT="${REMOTE_BOOT_FARM_REQUIRED_MOUNT:-100.100.100.120:/volume1/share}"
REMOTE_BOOT_TEST_USERNAME="${REMOTE_BOOT_TEST_USERNAME:-boot_test}"
REMOTE_BOOT_TEST_CONTAINER_NAME_PREFIX="${REMOTE_BOOT_TEST_CONTAINER_NAME_PREFIX:-boot_test_probe}"
REMOTE_BOOT_TEST_POST_CREATE_TIMEOUT_SECONDS="${REMOTE_BOOT_TEST_POST_CREATE_TIMEOUT_SECONDS:-60}"
REMOTE_BOOT_TEST_POST_CREATE_POLL_SECONDS="${REMOTE_BOOT_TEST_POST_CREATE_POLL_SECONDS:-5}"

if ! [[ "${REMOTE_BOOT_TEST_POST_CREATE_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || ! [[ "${REMOTE_BOOT_TEST_POST_CREATE_POLL_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "Error: post-create retry settings must be numeric." >&2
  exit 1
fi

read domain_name server_number <<<"$(split_server_id "${SERVER_ID_INPUT}")" || exit 1
target_host="$(compose_ansible_host_alias "${domain_name}" "${server_number}")"

case "${domain_name}" in
  LAB)
    required_mount="${REMOTE_BOOT_LAB_REQUIRED_MOUNT}"
    ;;
  FARM)
    required_mount="${REMOTE_BOOT_FARM_REQUIRED_MOUNT}"
    ;;
  *)
    echo "Error: unsupported domain ${domain_name}" >&2
    exit 1
    ;;
esac

require_ansible_cli || exit 1
require_ansible_inventory || exit 1
ensure_ansible_host_exists "${target_host}" || exit 1

test_container_name="$(printf '%s_%s' "${REMOTE_BOOT_TEST_CONTAINER_NAME_PREFIX}" "${SERVER_ID_INPUT}" | tr '[:upper:]' '[:lower:]')"

trap cleanup_test_container EXIT TERM INT

log_step "Checking NFS mount via df -h: ${required_mount}"
run_remote_shell "${target_host}" "df -h | grep -F '${required_mount}'"

log_step "Checking host GPU access with nvidia-smi"
run_remote_shell "${target_host}" "nvidia-smi"

log_step "Cleaning up stale test container state for ${test_container_name}"
cleanup_test_container

log_step "Creating test container ${test_container_name}"
bash "${CREATE_TEST_SCRIPT}" \
  --config "${CONFIG_FILE}" \
  --server-id "${SERVER_ID_INPUT}" \
  --container-name "${test_container_name}" >/dev/null

log_step "Checking SSH service inside ${test_container_name}"
retry_remote_step \
  "SSH service inside ${test_container_name}" \
  "docker exec '${test_container_name}' bash -lc \"service ssh status >/dev/null 2>&1 || [ -x /etc/init.d/ssh ] && /etc/init.d/ssh status >/dev/null 2>&1 || ps -ef | grep '[s]shd' >/dev/null\"" \
  "${REMOTE_BOOT_TEST_POST_CREATE_TIMEOUT_SECONDS}" \
  "${REMOTE_BOOT_TEST_POST_CREATE_POLL_SECONDS}"

log_step "Checking GPU access inside ${test_container_name}"
retry_remote_step \
  "GPU access inside ${test_container_name}" \
  "docker exec '${test_container_name}' nvidia-smi" \
  "${REMOTE_BOOT_TEST_POST_CREATE_TIMEOUT_SECONDS}" \
  "${REMOTE_BOOT_TEST_POST_CREATE_POLL_SECONDS}"

log_step "All boot health checks passed"
