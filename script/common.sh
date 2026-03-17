#!/bin/bash

require_command() {
  local command_name="$1"
  local install_hint="${2:-}"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Error: required command not found: ${command_name}" >&2
    if [[ -n "${install_hint}" ]]; then
      echo "Hint: ${install_hint}" >&2
    fi
    return 1
  fi
}

log_timestamp() {
  date +"%Y-%m-%dT%H:%M:%S%z"
}

set_log_context() {
  REMOTE_BOOT_LOG_CONTEXT="$1"
  export REMOTE_BOOT_LOG_CONTEXT
}

log_event() {
  local tag="$1"
  shift
  local message="$*"

  if [[ -n "${REMOTE_BOOT_LOG_CONTEXT:-}" ]]; then
    message="context=${REMOTE_BOOT_LOG_CONTEXT} ${message}"
  fi

  printf '%s [%s] %s\n' "$(log_timestamp)" "${tag}" "${message}"
}

log_event_stderr() {
  local tag="$1"
  shift
  local message="$*"

  if [[ -n "${REMOTE_BOOT_LOG_CONTEXT:-}" ]]; then
    message="context=${REMOTE_BOOT_LOG_CONTEXT} ${message}"
  fi

  printf '%s [%s] %s\n' "$(log_timestamp)" "${tag}" "${message}" >&2
}

log_warn() {
  log_event "WARN" "$*"
}

log_dry_run() {
  log_event "DRYRUN" "$*"
}

log_error() {
  local message="$*"

  if [[ -n "${REMOTE_BOOT_LOG_CONTEXT:-}" ]]; then
    message="context=${REMOTE_BOOT_LOG_CONTEXT} ${message}"
  fi

  printf '%s [%s] %s\n' "$(log_timestamp)" "ERROR" "${message}" >&2
}

notify_failure_stub() {
  local message="$*"
  local alert_log_file="${REMOTE_BOOT_ALERT_STUB_LOG_FILE:-${PROJECT_ROOT:-.}/logs/alerts/remote_boot_alert_stub.log}"

  mkdir -p "$(dirname "${alert_log_file}")" 2>/dev/null || true
  printf '%s [%s] %s\n' "$(log_timestamp)" "ALERT" "${message}" >>"${alert_log_file}" 2>/dev/null || true
  log_event "ALERT" "stub=true ${message}"
}

load_remote_boot_runtime() {
  REMOTE_BOOT_ANSIBLE_INVENTORY="${REMOTE_BOOT_ANSIBLE_INVENTORY:-${ANSIBLE_INVENTORY:-}}"
  ANSIBLE_INVENTORY="${REMOTE_BOOT_ANSIBLE_INVENTORY}"
}

dry_run_enabled() {
  is_truthy "${REMOTE_BOOT_DRY_RUN:-false}"
}

flatten_command() {
  printf '%s' "$1" | tr '\n' ' ' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'
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

load_target_groups() {
  REMOTE_BOOT_FARM_TARGETS="${REMOTE_BOOT_FARM_TARGETS:-FARM1 FARM2 FARM6 FARM7 FARM8 FARM9}"
  REMOTE_BOOT_LAB_TARGETS="${REMOTE_BOOT_LAB_TARGETS:-LAB1 LAB2 LAB3 LAB4 LAB5 LAB6 LAB7 LAB8 LAB9}"

  parse_target_string "${REMOTE_BOOT_FARM_TARGETS}"
  FARM_TARGETS=("${PARSED_TARGETS[@]}")

  parse_target_string "${REMOTE_BOOT_LAB_TARGETS}"
  LAB_TARGETS=("${PARSED_TARGETS[@]}")

  ALL_TARGETS=("${FARM_TARGETS[@]}" "${LAB_TARGETS[@]}")
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

is_valid_concrete_target() {
  local target="$1"
  local known_target

  for known_target in "${ALL_TARGETS[@]:-}"; do
    if [[ "${known_target}" == "${target}" ]]; then
      return 0
    fi
  done

  return 1
}

expand_target_token() {
  local normalized_target
  local target

  normalized_target="$(normalize_target "$1")"

  case "${normalized_target}" in
    all-farm)
      for target in "${FARM_TARGETS[@]:-}"; do
        append_unique_target "${target}"
      done
      ;;
    all-lab)
      for target in "${LAB_TARGETS[@]:-}"; do
        append_unique_target "${target}"
      done
      ;;
    all)
      for target in "${ALL_TARGETS[@]:-}"; do
        append_unique_target "${target}"
      done
      ;;
    *)
      if ! is_valid_concrete_target "${normalized_target}"; then
        echo "Error: unknown target '${normalized_target}'." >&2
        return 1
      fi
      append_unique_target "${normalized_target}"
      ;;
  esac
}

expand_target_list() {
  EXPANDED_TARGETS=()

  local token
  for token in "$@"; do
    expand_target_token "${token}" || return 1
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

normalize_domain_name() {
  local raw_domain="$1"
  local normalized

  normalized="$(printf '%s' "${raw_domain}" | tr '[:lower:]' '[:upper:]')"

  case "${normalized}" in
    LAB|FARM)
      printf '%s\n' "${normalized}"
      ;;
    *)
      echo "Error: domain name must be LAB or FARM" >&2
      return 1
      ;;
  esac
}

split_server_id() {
  local raw_server_id="$1"
  local parsed_domain parsed_number

  parsed_domain="$(printf '%s' "${raw_server_id}" | grep -o '^[A-Za-z]\+')"
  parsed_number="$(printf '%s' "${raw_server_id}" | grep -o '[0-9]\+$')"

  if [[ -z "${parsed_domain}" || -z "${parsed_number}" ]]; then
    echo "Error: server id must be in format [DOMAIN][NUMBER] (e.g., LAB1, FARM3)" >&2
    return 1
  fi

  printf '%s %s\n' "$(normalize_domain_name "${parsed_domain}")" "${parsed_number}"
}

validate_server_number() {
  local raw_number="$1"

  if ! [[ "${raw_number}" =~ ^[0-9]+$ ]]; then
    echo "Error: server number must be numeric." >&2
    return 1
  fi

  printf '%s\n' "${raw_number}"
}

compose_server_id() {
  local domain_name="$1"
  local server_number="$2"

  printf '%s%s\n' "${domain_name}" "${server_number}"
}

compose_ansible_host_alias() {
  local domain_name="$1"
  local server_number="$2"
  local prefix

  prefix="$(printf '%s' "${domain_name}" | tr '[:upper:]' '[:lower:]')"
  printf '%s%s\n' "${prefix}" "${server_number}"
}

require_ansible_cli() {
  require_command "ansible" "Install Ansible on the management server."
}

require_ansible_inventory() {
  if [[ -n "${ANSIBLE_INVENTORY:-}" && ! -f "${ANSIBLE_INVENTORY}" ]]; then
    echo "Error: ansible inventory file not found: ${ANSIBLE_INVENTORY}" >&2
    return 1
  fi
}

ensure_ansible_host_exists() {
  local host_alias="$1"
  local output

  output="$(run_ansible "${host_alias}" --list-hosts 2>/dev/null || true)"
  if printf '%s' "${output}" | grep -q "hosts (0):"; then
    echo "Error: target host '${host_alias}' is not defined in the Ansible inventory" >&2
    return 1
  fi

  if printf '%s' "${output}" | grep -Eq "(^|[[:space:]])${host_alias}([[:space:]]|$)"; then
    return 0
  fi

  if [[ -n "${ANSIBLE_INVENTORY:-}" ]] && grep -Eq "^[[:space:]]*${host_alias}([[:space:]]|$)" "${ANSIBLE_INVENTORY}"; then
    return 0
  fi

  echo "Error: target host '${host_alias}' is not defined in the Ansible inventory" >&2
  return 1
}

run_ansible() {
  if [[ -n "${ANSIBLE_INVENTORY:-}" ]]; then
    ansible "$1" -i "${ANSIBLE_INVENTORY}" "${@:2}"
  else
    ansible "$@"
  fi
}

run_remote_shell() {
  local host_alias="$1"
  local remote_command="$2"

  run_ansible "${host_alias}" -m shell -a "${remote_command}"
}

run_remote_shell_with_timeout() {
  local host_alias="$1"
  local remote_command="$2"
  local timeout_seconds="$3"
  local ansible_command=()

  if ! [[ "${timeout_seconds}" =~ ^[0-9]+$ ]] || (( timeout_seconds < 1 )); then
    run_remote_shell "${host_alias}" "${remote_command}"
    return
  fi

  if [[ -n "${ANSIBLE_INVENTORY:-}" ]]; then
    ansible_command=(ansible "${host_alias}" -i "${ANSIBLE_INVENTORY}" -m shell -a "${remote_command}")
  else
    ansible_command=(ansible "${host_alias}" -m shell -a "${remote_command}")
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout "${timeout_seconds}" "${ansible_command[@]}"
  else
    "${ansible_command[@]}"
  fi
}

run_remote_shell_capture() {
  local host_alias="$1"
  local remote_command="$2"
  local output

  if ! output="$(run_ansible "${host_alias}" -m shell -a "${remote_command}" 2>&1)"; then
    printf '%s\n' "${output}" >&2
    return 1
  fi

  printf '%s\n' "${output}"
}

enable_script_logging() {
  local log_file="$1"

  if [[ -z "${log_file}" ]]; then
    return 0
  fi

  mkdir -p "$(dirname "${log_file}")"

  if [[ "${REMOTE_BOOT_ACTIVE_LOG_FILE:-}" == "${log_file}" ]]; then
    return 0
  fi

  exec > >(tee -a "${log_file}") 2>&1
  REMOTE_BOOT_ACTIVE_LOG_FILE="${log_file}"
  export REMOTE_BOOT_ACTIVE_LOG_FILE
}
