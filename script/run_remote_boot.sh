#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/remote_boot.local.env"
WAKE_SCRIPT="${SCRIPT_DIR}/wake_targets.sh"
RESTART_SCRIPT="${REMOTE_BOOT_RESTART_SCRIPT:-${SCRIPT_DIR}/restart_all_remote_containers.sh}"
TARGETS_OVERRIDE=""
PRE_DELAY_OVERRIDE=""
DRY_RUN=false

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"
set_log_context "run_remote_boot"

show_help() {
  cat <<EOF
Usage: $0 [options] [TARGET ...]

Options:
  --config PATH         config file path (default: ${CONFIG_FILE})
  --targets CSV         comma or space separated target list
  --delay-seconds N     sleep before sending packets
  --dry-run             print the orchestration flow without changing remote state
  --list-targets        print available targets
  -h, --help            show this help

If TARGET arguments are provided, they override REMOTE_BOOT_TARGETS.
Boot sequence:
  1. REMOTE_BOOT_PRIORITY_TARGETS
  2. Optional boot-health gate for priority targets
  3. Sleep REMOTE_BOOT_SECONDARY_DELAY_SECONDS
  4. Wake remaining selected targets
  5. Restart docker containers on all selected servers
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
    --delay-seconds)
      if [[ $# -lt 2 ]]; then
        echo "Error: --delay-seconds requires a value." >&2
        exit 1
      fi
      PRE_DELAY_OVERRIDE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --list-targets)
      if is_truthy "${DRY_RUN}"; then
        exec "${WAKE_SCRIPT}" --dry-run --list-targets
      fi
      exec "${WAKE_SCRIPT}" --list-targets
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

load_target_groups

REMOTE_BOOT_TARGETS="${REMOTE_BOOT_TARGETS:-all}"
REMOTE_BOOT_PRE_DELAY_SECONDS="${REMOTE_BOOT_PRE_DELAY_SECONDS:-0}"
REMOTE_BOOT_PRIORITY_TARGETS="${REMOTE_BOOT_PRIORITY_TARGETS:-FARM1 LAB1}"
REMOTE_BOOT_ENABLE_GATE="${REMOTE_BOOT_ENABLE_GATE:-true}"
REMOTE_BOOT_GATE_TIMEOUT_SECONDS="${REMOTE_BOOT_GATE_TIMEOUT_SECONDS:-360}"
REMOTE_BOOT_GATE_POLL_SECONDS="${REMOTE_BOOT_GATE_POLL_SECONDS:-20}"
REMOTE_BOOT_SECONDARY_DELAY_SECONDS="${REMOTE_BOOT_SECONDARY_DELAY_SECONDS:-0}"
REMOTE_BOOT_ENABLE_CONTAINER_RESTART="${REMOTE_BOOT_ENABLE_CONTAINER_RESTART:-true}"
REMOTE_BOOT_CONTAINER_RESTART_TIMEOUT_SECONDS="${REMOTE_BOOT_CONTAINER_RESTART_TIMEOUT_SECONDS:-600}"
REMOTE_BOOT_CONTAINER_RESTART_POLL_SECONDS="${REMOTE_BOOT_CONTAINER_RESTART_POLL_SECONDS:-20}"
GATE_SCRIPT="${REMOTE_BOOT_GATE_SCRIPT:-${SCRIPT_DIR}/wait_for_priority_servers.sh}"
RESTART_SCRIPT="${REMOTE_BOOT_RESTART_SCRIPT:-${SCRIPT_DIR}/restart_all_remote_containers.sh}"

if [[ "${GATE_SCRIPT}" != /* ]]; then
  GATE_SCRIPT="$(cd "${PROJECT_ROOT}" && cd "$(dirname "${GATE_SCRIPT}")" && pwd)/$(basename "${GATE_SCRIPT}")"
fi

if [[ "${RESTART_SCRIPT}" != /* ]]; then
  RESTART_SCRIPT="$(cd "${PROJECT_ROOT}" && cd "$(dirname "${RESTART_SCRIPT}")" && pwd)/$(basename "${RESTART_SCRIPT}")"
fi

if [[ -n "${PRE_DELAY_OVERRIDE}" ]]; then
  REMOTE_BOOT_PRE_DELAY_SECONDS="${PRE_DELAY_OVERRIDE}"
fi

if ! [[ "${REMOTE_BOOT_PRE_DELAY_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "Error: delay must be a non-negative integer." >&2
  exit 1
fi

if ! [[ "${REMOTE_BOOT_SECONDARY_DELAY_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "Error: secondary delay must be a non-negative integer." >&2
  exit 1
fi

if ! [[ "${REMOTE_BOOT_GATE_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || ! [[ "${REMOTE_BOOT_GATE_POLL_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "Error: gate timeout and poll interval must be non-negative integers." >&2
  exit 1
fi

if ! [[ "${REMOTE_BOOT_CONTAINER_RESTART_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || ! [[ "${REMOTE_BOOT_CONTAINER_RESTART_POLL_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "Error: container restart timeout and poll interval must be non-negative integers." >&2
  exit 1
fi

declare -a selected_targets=()

if [[ $# -gt 0 ]]; then
  selected_targets=("$@")
elif [[ -n "${TARGETS_OVERRIDE}" ]]; then
  parse_target_string "${TARGETS_OVERRIDE}"
  selected_targets=("${PARSED_TARGETS[@]}")
else
  parse_target_string "${REMOTE_BOOT_TARGETS}"
  selected_targets=("${PARSED_TARGETS[@]}")
fi

if [[ ${#selected_targets[@]} -eq 0 ]]; then
  echo "Error: no boot targets were configured." >&2
  exit 1
fi

expand_target_list "${selected_targets[@]}"
selected_targets=("${EXPANDED_TARGETS[@]}")

if [[ "${REMOTE_BOOT_PRE_DELAY_SECONDS}" -gt 0 ]]; then
  log_event "BOOT" "stage=pre_delay seconds=${REMOTE_BOOT_PRE_DELAY_SECONDS}"
  if dry_run_enabled; then
    log_dry_run "stage=pre_delay action=skip_sleep seconds=${REMOTE_BOOT_PRE_DELAY_SECONDS}"
  else
    sleep "${REMOTE_BOOT_PRE_DELAY_SECONDS}"
  fi
fi

log_event "BOOT" "stage=selected_targets targets=\"${selected_targets[*]}\""

declare -a priority_targets=()
declare -a remaining_targets=()

parse_target_string "${REMOTE_BOOT_PRIORITY_TARGETS}"
expand_target_list "${PARSED_TARGETS[@]}"

local_priority_target=""
for local_priority_target in "${EXPANDED_TARGETS[@]}"; do
  if target_in_list "${local_priority_target}" "${selected_targets[@]}"; then
    priority_targets+=("${local_priority_target}")
  fi
done

local_selected_target=""
for local_selected_target in "${selected_targets[@]}"; do
  if ! target_in_list "${local_selected_target}" "${priority_targets[@]}"; then
    remaining_targets+=("${local_selected_target}")
  fi
done

if [[ ${#priority_targets[@]} -gt 0 ]]; then
  log_event "BOOT" "stage=priority_targets targets=\"${priority_targets[*]}\""
  wake_args=()
  if dry_run_enabled; then
    wake_args+=(--dry-run)
  fi
  if ! "${WAKE_SCRIPT}" "${wake_args[@]}" "${priority_targets[@]}"; then
    notify_failure "stage=priority_wake reason=wake_failed targets=\"${priority_targets[*]}\""
    exit 1
  fi
fi

if [[ ${#remaining_targets[@]} -gt 0 ]]; then
  if is_truthy "${REMOTE_BOOT_ENABLE_GATE}" && [[ ${#priority_targets[@]} -gt 0 ]]; then
    log_event "GATE" "stage=start targets=\"${priority_targets[*]}\" timeout_seconds=${REMOTE_BOOT_GATE_TIMEOUT_SECONDS} poll_seconds=${REMOTE_BOOT_GATE_POLL_SECONDS}"
    gate_args=()
    if dry_run_enabled; then
      gate_args+=(--dry-run)
    fi
    if ! "${GATE_SCRIPT}" \
      "${gate_args[@]}" \
      --config "${CONFIG_FILE}" \
      --timeout-seconds "${REMOTE_BOOT_GATE_TIMEOUT_SECONDS}" \
      --poll-seconds "${REMOTE_BOOT_GATE_POLL_SECONDS}" \
      "${priority_targets[@]}"; then
      notify_failure "stage=priority_gate reason=health_check_failed targets=\"${priority_targets[*]}\""
      exit 1
    fi
    log_event "GATE" "stage=passed targets=\"${priority_targets[*]}\""
  fi

  if [[ ${#priority_targets[@]} -gt 0 && "${REMOTE_BOOT_SECONDARY_DELAY_SECONDS}" -gt 0 ]]; then
    log_event "BOOT" "stage=secondary_delay seconds=${REMOTE_BOOT_SECONDARY_DELAY_SECONDS}"
    if dry_run_enabled; then
      log_dry_run "stage=secondary_delay action=skip_sleep seconds=${REMOTE_BOOT_SECONDARY_DELAY_SECONDS}"
    else
      sleep "${REMOTE_BOOT_SECONDARY_DELAY_SECONDS}"
    fi
  fi

  log_event "BOOT" "stage=remaining_targets targets=\"${remaining_targets[*]}\""
  wake_args=()
  if dry_run_enabled; then
    wake_args+=(--dry-run)
  fi
  if ! "${WAKE_SCRIPT}" "${wake_args[@]}" "${remaining_targets[@]}"; then
    notify_failure "stage=remaining_wake reason=wake_failed targets=\"${remaining_targets[*]}\""
    exit 1
  fi
elif is_truthy "${REMOTE_BOOT_ENABLE_GATE}" && [[ ${#priority_targets[@]} -gt 0 ]]; then
  log_event "GATE" "stage=skipped reason=no_remaining_targets targets=\"${priority_targets[*]}\""
fi

if is_truthy "${REMOTE_BOOT_ENABLE_CONTAINER_RESTART}" && [[ ${#selected_targets[@]} -gt 0 ]]; then
  log_event "CONTAINER" "stage=restart_requested targets=\"${selected_targets[*]}\" timeout_seconds=${REMOTE_BOOT_CONTAINER_RESTART_TIMEOUT_SECONDS} poll_seconds=${REMOTE_BOOT_CONTAINER_RESTART_POLL_SECONDS}"
  restart_args=()
  if dry_run_enabled; then
    restart_args+=(--dry-run)
  fi
  if ! "${RESTART_SCRIPT}" \
    "${restart_args[@]}" \
    --config "${CONFIG_FILE}" \
    --timeout-seconds "${REMOTE_BOOT_CONTAINER_RESTART_TIMEOUT_SECONDS}" \
    --poll-seconds "${REMOTE_BOOT_CONTAINER_RESTART_POLL_SECONDS}" \
    "${selected_targets[@]}"; then
    notify_failure "stage=restart_all_remote_containers reason=restart_or_postcheck_failed targets=\"${selected_targets[*]}\""
    exit 1
  fi
  log_event "CONTAINER" "stage=restart_completed targets=\"${selected_targets[*]}\""
fi
