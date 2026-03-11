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

load_remote_boot_runtime() {
  REMOTE_BOOT_ANSIBLE_INVENTORY="${REMOTE_BOOT_ANSIBLE_INVENTORY:-${ANSIBLE_INVENTORY:-}}"
  ANSIBLE_INVENTORY="${REMOTE_BOOT_ANSIBLE_INVENTORY}"
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
