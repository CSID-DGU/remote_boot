#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/remote_boot.local.env"
TARGETS_OVERRIDE=""
DRY_RUN=false
DISABLE_HOST_HEALTH=false
DISABLE_CONTAINER_CHECK=false

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"
set_log_context "run_remote_boot_monitor"

show_help() {
  cat <<EOF
Usage: $0 [options] [TARGET ...]

Options:
  --config PATH          config file path (default: ${CONFIG_FILE})
  --targets CSV          comma or space separated target list
  --skip-host-health     skip host health checks
  --skip-container-check skip periodic container health checks
  --dry-run              print the monitor flow without changing remote state
  -h, --help             show this help

If TARGET arguments are provided, they override REMOTE_BOOT_MONITOR_TARGETS.
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
    --targets)
      if [[ $# -lt 2 ]]; then
        echo "Error: --targets requires a value." >&2
        exit 1
      fi
      TARGETS_OVERRIDE="$2"
      shift 2
      ;;
    --skip-host-health)
      DISABLE_HOST_HEALTH=true
      shift
      ;;
    --skip-container-check)
      DISABLE_CONTAINER_CHECK=true
      shift
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
load_target_groups

REMOTE_BOOT_MONITOR_TARGETS="${REMOTE_BOOT_MONITOR_TARGETS:-all}"
REMOTE_BOOT_MONITOR_ENABLE_HOST_HEALTH_CHECK="${REMOTE_BOOT_MONITOR_ENABLE_HOST_HEALTH_CHECK:-true}"
REMOTE_BOOT_MONITOR_ENABLE_CONTAINER_CHECK="${REMOTE_BOOT_MONITOR_ENABLE_CONTAINER_CHECK:-true}"
REMOTE_BOOT_MONITOR_LOG_FILE="${REMOTE_BOOT_MONITOR_LOG_FILE:-/var/log/remote-boot-monitor.log}"
export REMOTE_BOOT_CURRENT_LOG_FILE="${REMOTE_BOOT_MONITOR_LOG_FILE}"

CHECK_SCRIPT="${REMOTE_BOOT_HEALTH_CHECK_SCRIPT:-${SCRIPT_DIR}/check_server_boot_health.sh}"
CONTAINER_SCRIPT="${REMOTE_BOOT_RESTART_SCRIPT:-${SCRIPT_DIR}/restart_all_remote_containers.sh}"

if [[ "${CHECK_SCRIPT}" != /* ]]; then
  CHECK_SCRIPT="$(cd "${PROJECT_ROOT}" && cd "$(dirname "${CHECK_SCRIPT}")" && pwd)/$(basename "${CHECK_SCRIPT}")"
fi

if [[ "${CONTAINER_SCRIPT}" != /* ]]; then
  CONTAINER_SCRIPT="$(cd "${PROJECT_ROOT}" && cd "$(dirname "${CONTAINER_SCRIPT}")" && pwd)/$(basename "${CONTAINER_SCRIPT}")"
fi

if is_truthy "${DISABLE_HOST_HEALTH}"; then
  REMOTE_BOOT_MONITOR_ENABLE_HOST_HEALTH_CHECK=false
fi

if is_truthy "${DISABLE_CONTAINER_CHECK}"; then
  REMOTE_BOOT_MONITOR_ENABLE_CONTAINER_CHECK=false
fi

if ! is_truthy "${REMOTE_BOOT_MONITOR_ENABLE_HOST_HEALTH_CHECK}" && ! is_truthy "${REMOTE_BOOT_MONITOR_ENABLE_CONTAINER_CHECK}"; then
  echo "Error: both host health checks and container checks are disabled." >&2
  exit 1
fi

declare -a selected_targets=()

if [[ $# -gt 0 ]]; then
  selected_targets=("$@")
elif [[ -n "${TARGETS_OVERRIDE}" ]]; then
  parse_target_string "${TARGETS_OVERRIDE}"
  selected_targets=("${PARSED_TARGETS[@]}")
else
  parse_target_string "${REMOTE_BOOT_MONITOR_TARGETS}"
  selected_targets=("${PARSED_TARGETS[@]}")
fi

if [[ ${#selected_targets[@]} -eq 0 ]]; then
  echo "Error: no monitor targets were configured." >&2
  exit 1
fi

expand_target_list "${selected_targets[@]}"
selected_targets=("${EXPANDED_TARGETS[@]}")

declare -a host_failed_servers=()
declare -a container_failed_servers=()
declare -a fully_passed_servers=()

log_event "MONITOR" "stage=start targets=\"${selected_targets[*]}\" host_health_enabled=${REMOTE_BOOT_MONITOR_ENABLE_HOST_HEALTH_CHECK} container_check_enabled=${REMOTE_BOOT_MONITOR_ENABLE_CONTAINER_CHECK} mode=limited_recovery"

for server_id in "${selected_targets[@]}"; do
  host_check_passed=true
  container_check_passed=true

  log_event "MONITOR" "stage=server_start server=${server_id}"

  if is_truthy "${REMOTE_BOOT_MONITOR_ENABLE_HOST_HEALTH_CHECK}"; then
    if "${CHECK_SCRIPT}" --config "${CONFIG_FILE}" ${REMOTE_BOOT_DRY_RUN:+--dry-run} --monitor-mode --server-id "${server_id}"; then
      log_event "MONITOR" "stage=host_health_passed server=${server_id}"
    else
      host_failed_servers+=("${server_id}")
      host_check_passed=false
      log_warn "stage=host_health_failed server=${server_id}"
    fi
  else
    log_event "MONITOR" "stage=host_health_skipped server=${server_id}"
  fi

  if is_truthy "${REMOTE_BOOT_MONITOR_ENABLE_CONTAINER_CHECK}"; then
    if [[ "${host_check_passed}" == "false" ]] && is_truthy "${REMOTE_BOOT_MONITOR_ENABLE_HOST_HEALTH_CHECK}"; then
      container_check_passed=false
      log_event "MONITOR" "stage=container_check_skipped server=${server_id} reason=host_health_failed"
    elif "${CONTAINER_SCRIPT}" --config "${CONFIG_FILE}" ${REMOTE_BOOT_DRY_RUN:+--dry-run} --monitor-mode "${server_id}"; then
      log_event "MONITOR" "stage=container_check_passed server=${server_id}"
    else
      container_failed_servers+=("${server_id}")
      container_check_passed=false
      log_warn "stage=container_check_failed server=${server_id}"
    fi
  else
    log_event "MONITOR" "stage=container_check_skipped server=${server_id} reason=disabled"
  fi

  if [[ "${host_check_passed}" == "true" && "${container_check_passed}" == "true" ]]; then
    fully_passed_servers+=("${server_id}")
  fi
done

if dry_run_enabled; then
  log_event "MONITOR" "status=dry_run_completed targets=\"${selected_targets[*]}\""
  exit 0
fi

if [[ ${#host_failed_servers[@]} -gt 0 || ${#container_failed_servers[@]} -gt 0 ]]; then
  log_error "status=failed host_failed=\"${host_failed_servers[*]:-}\" container_failed=\"${container_failed_servers[*]:-}\""
  exit 1
fi

log_event "MONITOR" "status=passed servers=\"${fully_passed_servers[*]}\""
