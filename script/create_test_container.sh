#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/remote_boot.local.env"
SERVER_ID_INPUT=""
CONTAINER_NAME_OVERRIDE=""

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

show_help() {
  cat <<EOF
Usage: $0 [options] --server-id SERVER_ID

Options:
  --config PATH           config file path (default: ${CONFIG_FILE})
  --server-id SERVER_ID   target server id, for example FARM1 or LAB1
  --container-name NAME   override test container name
  -h, --help              show this help
EOF
}

validate_simple_value() {
  local label="$1"
  local value="$2"
  local pattern="$3"

  if ! [[ "${value}" =~ ${pattern} ]]; then
    echo "Error: invalid ${label}: ${value}" >&2
    exit 1
  fi
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

REMOTE_BOOT_TEST_CONTAINER_NAME_PREFIX="${REMOTE_BOOT_TEST_CONTAINER_NAME_PREFIX:-boot_test_probe}"
REMOTE_BOOT_TEST_IMAGE_REPOSITORY="${REMOTE_BOOT_TEST_IMAGE_REPOSITORY:-dguailab}"
REMOTE_BOOT_TEST_IMAGE="${REMOTE_BOOT_TEST_IMAGE:-pytorch}"
REMOTE_BOOT_TEST_VERSION="${REMOTE_BOOT_TEST_VERSION:-latest}"
REMOTE_BOOT_TEST_USERNAME="${REMOTE_BOOT_TEST_USERNAME:-boot_test}"
REMOTE_BOOT_TEST_GROUP="${REMOTE_BOOT_TEST_GROUP:-boot_test}"
REMOTE_BOOT_TEST_UID="${REMOTE_BOOT_TEST_UID:-10000}"
REMOTE_BOOT_TEST_GID="${REMOTE_BOOT_TEST_GID:-10000}"
REMOTE_BOOT_TEST_PASSWORD="${REMOTE_BOOT_TEST_PASSWORD:-ailab2260}"
REMOTE_BOOT_TEST_MEMORY="${REMOTE_BOOT_TEST_MEMORY:-192g}"
REMOTE_BOOT_TEST_SHARE_SOURCE_BASE="${REMOTE_BOOT_TEST_SHARE_SOURCE_BASE:-/home/tako}"
REMOTE_BOOT_TEST_SHARE_SOURCE_SUFFIX="${REMOTE_BOOT_TEST_SHARE_SOURCE_SUFFIX:-/share/user-share/}"
REMOTE_BOOT_TEST_SHARE_TARGET="${REMOTE_BOOT_TEST_SHARE_TARGET:-/home/}"

validate_simple_value "container name prefix" "${REMOTE_BOOT_TEST_CONTAINER_NAME_PREFIX}" '^[A-Za-z0-9_.-]+$'
validate_simple_value "image repository" "${REMOTE_BOOT_TEST_IMAGE_REPOSITORY}" '^[A-Za-z0-9_.-]+$'
validate_simple_value "image" "${REMOTE_BOOT_TEST_IMAGE}" '^[A-Za-z0-9_.-]+$'
validate_simple_value "version" "${REMOTE_BOOT_TEST_VERSION}" '^[A-Za-z0-9_.:-]+$'
validate_simple_value "username" "${REMOTE_BOOT_TEST_USERNAME}" '^[A-Za-z0-9_.-]+$'
validate_simple_value "group" "${REMOTE_BOOT_TEST_GROUP}" '^[A-Za-z0-9_.-]+$'
validate_simple_value "uid" "${REMOTE_BOOT_TEST_UID}" '^[0-9]+$'
validate_simple_value "gid" "${REMOTE_BOOT_TEST_GID}" '^[0-9]+$'

require_ansible_cli || exit 1
require_ansible_inventory || exit 1

read domain_name server_number <<<"$(split_server_id "${SERVER_ID_INPUT}")" || exit 1
server_number="$(validate_server_number "${server_number}")" || exit 1
target_host="$(compose_ansible_host_alias "${domain_name}" "${server_number}")"
ensure_ansible_host_exists "${target_host}" || exit 1

container_name="${CONTAINER_NAME_OVERRIDE:-$(printf '%s_%s' "${REMOTE_BOOT_TEST_CONTAINER_NAME_PREFIX}" "${SERVER_ID_INPUT}" | tr '[:upper:]' '[:lower:]')}"
validate_simple_value "container name" "${container_name}" '^[A-Za-z0-9_.-]+$'

image_ref="${REMOTE_BOOT_TEST_IMAGE_REPOSITORY}/${REMOTE_BOOT_TEST_IMAGE}:${REMOTE_BOOT_TEST_VERSION}"
share_source="${REMOTE_BOOT_TEST_SHARE_SOURCE_BASE}${server_number}${REMOTE_BOOT_TEST_SHARE_SOURCE_SUFFIX}"

run_remote_shell "${target_host}" "docker rm -f '${container_name}' >/dev/null 2>&1 || true" >/dev/null
run_remote_shell "${target_host}" "docker pull '${image_ref}'" >/dev/null

remote_run_command="docker run -dit --gpus device=all --memory=${REMOTE_BOOT_TEST_MEMORY} --memory-swap=${REMOTE_BOOT_TEST_MEMORY} --runtime=nvidia --cap-add=SYS_ADMIN --ipc=host --mount type=bind,source='${share_source}',target='${REMOTE_BOOT_TEST_SHARE_TARGET}' --name '${container_name}' -e USER_ID='${REMOTE_BOOT_TEST_USERNAME}' -e GID='${REMOTE_BOOT_TEST_GID}' -e USER_PW='${REMOTE_BOOT_TEST_PASSWORD}' -e USER_GROUP='${REMOTE_BOOT_TEST_GROUP}' -e UID='${REMOTE_BOOT_TEST_UID}' '${image_ref}'"
container_output="$(run_remote_shell_capture "${target_host}" "${remote_run_command}")" || {
  run_remote_shell "${target_host}" "docker rm -f '${container_name}' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  exit 1
}

container_id="$(printf '%s\n' "${container_output}" | tail -n1 | tr -d '\r')"
if [[ -z "${container_id}" || ! "${container_id}" =~ ^[0-9a-f]{12,64}$ ]]; then
  echo "Error: unexpected container id returned from ${target_host}: ${container_id}" >&2
  run_remote_shell "${target_host}" "docker rm -f '${container_name}' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  exit 1
fi

run_remote_shell "${target_host}" "docker inspect '${container_name}' >/dev/null 2>&1" >/dev/null

printf '%s\n' "${container_name}"
