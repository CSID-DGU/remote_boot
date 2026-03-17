#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/remote_boot.local.env"
SERVER_ID_INPUT=""
LOG_FILE_OVERRIDE=""
DRY_RUN=false

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"
set_log_context "check_server_boot_health"

show_help() {
  cat <<EOF
Usage: $0 [options] --server-id SERVER_ID

Options:
  --config PATH         config file path (default: ${CONFIG_FILE})
  --server-id SERVER_ID target server id, for example FARM1 or LAB1
  --log-file PATH       append output to PATH while keeping terminal output
  --dry-run             print the health-check plan without changing remote state
  -h, --help            show this help
EOF
}

log_step() {
  log_event "HEALTH" "server=${SERVER_ID_INPUT} $*"
}

cleanup_test_container() {
  if [[ -n "${SERVER_ID_INPUT:-}" && -n "${test_container_name:-}" && -x "${DELETE_TEST_SCRIPT:-}" ]]; then
    bash "${DELETE_TEST_SCRIPT}" \
      --config "${CONFIG_FILE}" \
      --server-id "${SERVER_ID_INPUT}" \
      --container-name "${test_container_name}" >/dev/null 2>&1 || true
  fi
}

render_server_template() {
  local template="$1"
  local number="$2"

  printf '%s' "${template}" | sed "s/%s/${number}/g"
}

build_mount_recovery_command() {
  local mount_path="$1"

  cat <<EOF
sudo -n mount '${mount_path}' >/dev/null 2>&1 || sudo -n mount -a >/dev/null 2>&1
EOF
}

build_host_gpu_recovery_command() {
  cat <<'EOF'
sudo -n modprobe nvidia >/dev/null 2>&1 || true
sudo -n modprobe nvidia_uvm >/dev/null 2>&1 || true
sudo -n systemctl restart nvidia-persistenced >/dev/null 2>&1 || sudo -n service nvidia-persistenced restart >/dev/null 2>&1 || true
EOF
}

build_docker_recovery_command() {
  cat <<'EOF'
sudo -n systemctl restart docker >/dev/null 2>&1 || sudo -n service docker restart >/dev/null 2>&1
EOF
}

build_container_ssh_recovery_command() {
  local container_name="$1"

  cat <<EOF
docker exec '${container_name}' sh -lc "service ssh start >/dev/null 2>&1 || { [ -x /etc/init.d/ssh ] && /etc/init.d/ssh start >/dev/null 2>&1; } || true" >/dev/null 2>&1 || true
EOF
}

build_container_gpu_recovery_command() {
  local container_name="$1"

  cat <<EOF
docker restart '${container_name}' >/dev/null 2>&1 || true
EOF
}

run_step_with_single_recovery() {
  local stage_name="$1"
  local check_command="$2"
  local recovery_command="$3"
  local recovery_action="$4"

  if run_remote_shell "${target_host}" "${check_command}"; then
    return 0
  fi

  log_step "stage=${stage_name} recovery_action=${recovery_action}"
  run_remote_shell "${target_host}" "${recovery_command}" || true

  if run_remote_shell "${target_host}" "${check_command}"; then
    log_step "stage=${stage_name} recovery_status=passed"
    return 0
  fi

  return 1
}

fail_with_notification() {
  local stage_name="$1"
  local reason="$2"

  log_error "server=${SERVER_ID_INPUT} stage=${stage_name} reason=${reason}"
  notify_failure_stub "server=${SERVER_ID_INPUT} stage=${stage_name} reason=${reason}"
  exit 1
}

dry_run_health_check() {
  local mount_check_command host_gpu_check_command container_ssh_command container_gpu_command
  local mount_recovery_command host_gpu_recovery_command container_ssh_recovery_command container_gpu_recovery_command

  mount_check_command="df -h | grep -F '${required_mount}'"
  host_gpu_check_command="nvidia-smi"
  mount_recovery_command="$(flatten_command "$(build_mount_recovery_command "${host_mount_path}")")"
  host_gpu_recovery_command="$(flatten_command "$(build_host_gpu_recovery_command)")"
  container_ssh_command="docker exec '${test_container_name}' sh -lc \"service ssh status >/dev/null 2>&1 || { [ -x /etc/init.d/ssh ] && /etc/init.d/ssh status >/dev/null 2>&1; } || ps -ef | grep '[s]shd' >/dev/null\""
  container_gpu_command="docker exec '${test_container_name}' nvidia-smi"
  container_ssh_recovery_command="$(flatten_command "$(build_container_ssh_recovery_command "${test_container_name}")")"
  container_gpu_recovery_command="$(flatten_command "$(build_container_gpu_recovery_command "${test_container_name}")")"

  log_dry_run "server=${SERVER_ID_INPUT} action=health_check_plan host=${target_host} timeout_seconds=${REMOTE_BOOT_TEST_POST_CREATE_TIMEOUT_SECONDS} poll_seconds=${REMOTE_BOOT_TEST_POST_CREATE_POLL_SECONDS}"
  log_step "stage=mount_check dry_run_command=\"${mount_check_command}\" recovery_action=remount_nfs recovery_command=\"${mount_recovery_command}\""
  log_step "stage=host_gpu_check dry_run_command=\"${host_gpu_check_command}\" recovery_action=reload_gpu_modules recovery_command=\"${host_gpu_recovery_command}\""
  log_step "stage=cleanup_stale_container container=${test_container_name}"
  bash "${DELETE_TEST_SCRIPT}" \
    --config "${CONFIG_FILE}" \
    --server-id "${SERVER_ID_INPUT}" \
    --container-name "${test_container_name}" \
    --dry-run >/dev/null
  bash "${CREATE_TEST_SCRIPT}" \
    --config "${CONFIG_FILE}" \
    --server-id "${SERVER_ID_INPUT}" \
    --container-name "${test_container_name}" \
    --dry-run >/dev/null
  log_step "stage=container_ssh_check container=${test_container_name} dry_run_command=\"${container_ssh_command}\" recovery_action=restart_container_ssh recovery_command=\"${container_ssh_recovery_command}\" timeout_seconds=${REMOTE_BOOT_TEST_POST_CREATE_TIMEOUT_SECONDS} poll_seconds=${REMOTE_BOOT_TEST_POST_CREATE_POLL_SECONDS}"
  log_step "stage=container_gpu_check container=${test_container_name} dry_run_command=\"${container_gpu_command}\" recovery_action=restart_container recovery_command=\"${container_gpu_recovery_command}\" timeout_seconds=${REMOTE_BOOT_TEST_POST_CREATE_TIMEOUT_SECONDS} poll_seconds=${REMOTE_BOOT_TEST_POST_CREATE_POLL_SECONDS} recovery_mode=once"
  bash "${DELETE_TEST_SCRIPT}" \
    --config "${CONFIG_FILE}" \
    --server-id "${SERVER_ID_INPUT}" \
    --container-name "${test_container_name}" \
    --dry-run >/dev/null
  log_step "status=dry_run_completed"
}

retry_remote_step() {
  local description="$1"
  local remote_command="$2"
  local recovery_description="${3:-}"
  local recovery_command="${4:-}"
  local timeout_seconds="$5"
  local poll_seconds="$6"
  local recovery_mode="${7:-always}"
  local deadline=$((SECONDS + timeout_seconds))
  local attempt=1
  local recovery_performed=false

  while true; do
    log_step "${description} attempt=${attempt}"
    if run_remote_shell "${target_host}" "${remote_command}"; then
      return 0
    fi

    if [[ -n "${recovery_command}" && ( "${recovery_mode}" != "once" || "${recovery_performed}" == "false" ) ]]; then
      log_step "${description} recovery_action=${recovery_description} attempt=${attempt}"
      run_remote_shell "${target_host}" "${recovery_command}" || true
      recovery_performed=true
    fi

    if (( SECONDS >= deadline )); then
      log_step "status=timeout ${description}"
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
    --log-file)
      if [[ $# -lt 2 ]]; then
        echo "Error: --log-file requires a value." >&2
        exit 1
      fi
      LOG_FILE_OVERRIDE="$2"
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

REMOTE_BOOT_HEALTH_LOG_DIR="${REMOTE_BOOT_HEALTH_LOG_DIR:-${PROJECT_ROOT}/logs/health}"
REMOTE_BOOT_ENABLE_HEALTH_LOGGING="${REMOTE_BOOT_ENABLE_HEALTH_LOGGING:-true}"

if [[ -n "${LOG_FILE_OVERRIDE}" ]]; then
  HEALTH_LOG_FILE="${LOG_FILE_OVERRIDE}"
elif is_truthy "${REMOTE_BOOT_ENABLE_HEALTH_LOGGING}"; then
  HEALTH_LOG_FILE="${REMOTE_BOOT_HEALTH_LOG_DIR}/$(date +%Y%m%d_%H%M%S)_$(printf '%s' "${SERVER_ID_INPUT}" | tr '[:upper:]' '[:lower:]').log"
else
  HEALTH_LOG_FILE=""
fi

enable_script_logging "${HEALTH_LOG_FILE}"
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
REMOTE_BOOT_TEST_POST_CREATE_TIMEOUT_SECONDS="${REMOTE_BOOT_TEST_POST_CREATE_TIMEOUT_SECONDS:-120}"
REMOTE_BOOT_TEST_POST_CREATE_POLL_SECONDS="${REMOTE_BOOT_TEST_POST_CREATE_POLL_SECONDS:-5}"
REMOTE_BOOT_HOST_SHARE_MOUNT_TEMPLATE="${REMOTE_BOOT_HOST_SHARE_MOUNT_TEMPLATE:-/home/tako%s/share}"

if ! [[ "${REMOTE_BOOT_TEST_POST_CREATE_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || ! [[ "${REMOTE_BOOT_TEST_POST_CREATE_POLL_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "Error: post-create retry settings must be numeric." >&2
  exit 1
fi

read domain_name server_number <<<"$(split_server_id "${SERVER_ID_INPUT}")" || exit 1
target_host="$(compose_ansible_host_alias "${domain_name}" "${server_number}")"
host_mount_path="$(render_server_template "${REMOTE_BOOT_HOST_SHARE_MOUNT_TEMPLATE}" "${server_number}")"

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

if dry_run_enabled; then
  dry_run_health_check
  exit 0
fi

trap cleanup_test_container EXIT TERM INT

if [[ -n "${HEALTH_LOG_FILE}" ]]; then
  log_step "log_file=${HEALTH_LOG_FILE}"
fi

log_step "stage=mount_check required_mount=${required_mount}"
run_step_with_single_recovery \
  "mount_check" \
  "df -h | grep -F '${required_mount}'" \
  "$(build_mount_recovery_command "${host_mount_path}")" \
  "remount_nfs" || fail_with_notification "mount_check" "mount_unavailable"

log_step "stage=host_gpu_check"
run_step_with_single_recovery \
  "host_gpu_check" \
  "nvidia-smi" \
  "$(build_host_gpu_recovery_command)" \
  "reload_gpu_modules" || fail_with_notification "host_gpu_check" "host_gpu_unavailable"

log_step "stage=cleanup_stale_container container=${test_container_name}"
cleanup_test_container

log_step "stage=create_test_container container=${test_container_name}"
if ! bash "${CREATE_TEST_SCRIPT}" \
  --config "${CONFIG_FILE}" \
  --server-id "${SERVER_ID_INPUT}" \
  --container-name "${test_container_name}" >/dev/null; then
  log_step "stage=create_test_container recovery_action=restart_docker"
  run_remote_shell "${target_host}" "$(build_docker_recovery_command)" || true
  cleanup_test_container

  if ! bash "${CREATE_TEST_SCRIPT}" \
    --config "${CONFIG_FILE}" \
    --server-id "${SERVER_ID_INPUT}" \
    --container-name "${test_container_name}" >/dev/null; then
    fail_with_notification "create_test_container" "docker_container_create_failed"
  fi
fi

log_step "stage=container_ssh_check_start container=${test_container_name}"
retry_remote_step \
  "stage=container_ssh_check container=${test_container_name}" \
  "docker exec '${test_container_name}' sh -lc \"service ssh status >/dev/null 2>&1 || { [ -x /etc/init.d/ssh ] && /etc/init.d/ssh status >/dev/null 2>&1; } || ps -ef | grep '[s]shd' >/dev/null\"" \
  "restart_container_ssh" \
  "$(build_container_ssh_recovery_command "${test_container_name}")" \
  "${REMOTE_BOOT_TEST_POST_CREATE_TIMEOUT_SECONDS}" \
  "${REMOTE_BOOT_TEST_POST_CREATE_POLL_SECONDS}" || fail_with_notification "container_ssh_check" "new_container_ssh_unavailable"

log_step "stage=container_gpu_check_start container=${test_container_name}"
retry_remote_step \
  "stage=container_gpu_check container=${test_container_name}" \
  "docker exec '${test_container_name}' nvidia-smi" \
  "restart_container" \
  "$(build_container_gpu_recovery_command "${test_container_name}")" \
  "${REMOTE_BOOT_TEST_POST_CREATE_TIMEOUT_SECONDS}" \
  "${REMOTE_BOOT_TEST_POST_CREATE_POLL_SECONDS}" \
  "once" || fail_with_notification "container_gpu_check" "new_container_gpu_unavailable"

log_step "status=passed"
