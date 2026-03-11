#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/remote_boot.local.env"
WAKE_SCRIPT="${SCRIPT_DIR}/wake_targets.sh"
RESTART_SCRIPT="${REMOTE_BOOT_RESTART_SCRIPT:-${SCRIPT_DIR}/restart_all_remote_containers.sh}"
declare -ar FARM_TARGETS=(FARM1 FARM2 FARM6 FARM7 FARM8 FARM9)
declare -ar LAB_TARGETS=(LAB1 LAB2 LAB3 LAB4 LAB5 LAB6 LAB7 LAB8 LAB9)
declare -ar ALL_TARGETS=("${FARM_TARGETS[@]}" "${LAB_TARGETS[@]}")
TARGETS_OVERRIDE=""
PRE_DELAY_OVERRIDE=""

show_help() {
  cat <<EOF
Usage: $0 [options] [TARGET ...]

Options:
  --config PATH         config file path (default: ${CONFIG_FILE})
  --targets CSV         comma or space separated target list
  --delay-seconds N     sleep before sending packets
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

parse_target_string() {
  local raw_targets="$1"
  local normalized="${raw_targets//,/ }"

  read -r -a PARSED_TARGETS <<< "${normalized}"
}

normalize_target() {
  local raw_target="$1"

  case "${raw_target}" in
    all | all-farm | all-lab)
      printf '%s\n' "${raw_target}"
      ;;
    *)
      printf '%s\n' "$(printf '%s' "${raw_target}" | tr '[:lower:]' '[:upper:]')"
      ;;
  esac
}

is_valid_concrete_target() {
  local target="$1"
  local known_target

  for known_target in "${ALL_TARGETS[@]}"; do
    if [[ "${known_target}" == "${target}" ]]; then
      return 0
    fi
  done

  return 1
}

append_unique_target() {
  local target="$1"
  local existing

  for existing in "${EXPANDED_TARGETS[@]:-}"; do
    if [[ "${existing}" == "${target}" ]]; then
      return 0
    fi
  done

  EXPANDED_TARGETS+=("${target}")
}

expand_target_token() {
  local normalized_target
  local target

  normalized_target="$(normalize_target "$1")"

  case "${normalized_target}" in
    all-farm)
      for target in "${FARM_TARGETS[@]}"; do
        append_unique_target "${target}"
      done
      ;;
    all-lab)
      for target in "${LAB_TARGETS[@]}"; do
        append_unique_target "${target}"
      done
      ;;
    all)
      for target in "${ALL_TARGETS[@]}"; do
        append_unique_target "${target}"
      done
      ;;
    *)
      if ! is_valid_concrete_target "${normalized_target}"; then
        echo "Error: unknown target '${normalized_target}'." >&2
        exit 1
      fi
      append_unique_target "${normalized_target}"
      ;;
  esac
}

expand_target_list() {
  EXPANDED_TARGETS=()

  local token
  for token in "$@"; do
    expand_target_token "${token}"
  done
}

target_in_list() {
  local needle="$1"
  shift

  local target
  for target in "$@"; do
    if [[ "${target}" == "${needle}" ]]; then
      return 0
    fi
  done

  return 1
}

is_truthy() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
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
    --list-targets)
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
  echo "Sleeping ${REMOTE_BOOT_PRE_DELAY_SECONDS}s before sending Wake-on-LAN packets"
  sleep "${REMOTE_BOOT_PRE_DELAY_SECONDS}"
fi

echo "Remote boot targets: ${selected_targets[*]}"

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
  echo "Priority boot targets: ${priority_targets[*]}"
  "${WAKE_SCRIPT}" "${priority_targets[@]}"
fi

if [[ ${#remaining_targets[@]} -gt 0 ]]; then
  if is_truthy "${REMOTE_BOOT_ENABLE_GATE}" && [[ ${#priority_targets[@]} -gt 0 ]]; then
    echo "Running priority boot-health gate for: ${priority_targets[*]}"
    "${GATE_SCRIPT}" \
      --config "${CONFIG_FILE}" \
      --timeout-seconds "${REMOTE_BOOT_GATE_TIMEOUT_SECONDS}" \
      --poll-seconds "${REMOTE_BOOT_GATE_POLL_SECONDS}" \
      "${priority_targets[@]}"
  fi

  if [[ ${#priority_targets[@]} -gt 0 && "${REMOTE_BOOT_SECONDARY_DELAY_SECONDS}" -gt 0 ]]; then
    echo "Sleeping ${REMOTE_BOOT_SECONDARY_DELAY_SECONDS}s before waking remaining targets"
    sleep "${REMOTE_BOOT_SECONDARY_DELAY_SECONDS}"
  fi

  echo "Remaining boot targets: ${remaining_targets[*]}"
  "${WAKE_SCRIPT}" "${remaining_targets[@]}"
fi

if is_truthy "${REMOTE_BOOT_ENABLE_CONTAINER_RESTART}" && [[ ${#selected_targets[@]} -gt 0 ]]; then
  echo "Restarting docker containers on selected servers: ${selected_targets[*]}"
  "${RESTART_SCRIPT}" \
    --config "${CONFIG_FILE}" \
    --timeout-seconds "${REMOTE_BOOT_CONTAINER_RESTART_TIMEOUT_SECONDS}" \
    --poll-seconds "${REMOTE_BOOT_CONTAINER_RESTART_POLL_SECONDS}" \
    "${selected_targets[@]}"
fi
