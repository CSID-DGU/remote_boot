#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${PROJECT_ROOT}/config"

SERVICE_NAME="remote-boot-monitor"
UNIT_DIR="/etc/systemd/system"
SERVICE_FILE="${UNIT_DIR}/${SERVICE_NAME}.service"
TIMER_FILE="${UNIT_DIR}/${SERVICE_NAME}.timer"
LOGROTATE_FILE="/etc/logrotate.d/${SERVICE_NAME}"
RUNNER_SCRIPT="${SCRIPT_DIR}/run_remote_boot_monitor.sh"
CONFIG_FILE="${CONFIG_DIR}/remote_boot.local.env"
ON_CALENDAR="*:0/15"
LOG_FILE="/var/log/${SERVICE_NAME}.log"
LOG_ROTATE_COUNT=14
FORCE_INSTALL=false
START_NOW=false
ORIGINAL_ARGS=("$@")

show_help() {
  cat <<EOF
Usage: $0 [options]

Options:
  --config PATH         config file path (default: ${CONFIG_FILE})
  --on-calendar VALUE   systemd OnCalendar value (default: ${ON_CALENDAR})
  --log-file PATH       log file path
  --rotate-count N      logrotate daily retention count
  --force               rewrite files even when contents are unchanged
  --start-now           start the service immediately after install
  -h, --help            show this help
EOF
}

require_command() {
  local cmd="$1"
  local hint="$2"

  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Error: ${cmd} is required. ${hint}" >&2
    exit 1
  fi
}

for ((i = 0; i < ${#ORIGINAL_ARGS[@]}; i++)); do
  case "${ORIGINAL_ARGS[$i]}" in
    --config)
      if (( i + 1 >= ${#ORIGINAL_ARGS[@]} )); then
        echo "Error: --config requires a value." >&2
        exit 1
      fi
      CONFIG_FILE="${ORIGINAL_ARGS[$((i + 1))]}"
      i=$((i + 1))
      ;;
    *)
      ;;
  esac
done

if [[ -f "${CONFIG_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
  set +a
fi

if [[ -n "${REMOTE_BOOT_MONITOR_ON_CALENDAR:-}" ]]; then
  ON_CALENDAR="${REMOTE_BOOT_MONITOR_ON_CALENDAR}"
fi

if [[ -n "${REMOTE_BOOT_MONITOR_LOG_FILE:-}" ]]; then
  LOG_FILE="${REMOTE_BOOT_MONITOR_LOG_FILE}"
fi

if [[ -n "${REMOTE_BOOT_MONITOR_LOG_ROTATE_COUNT:-}" ]]; then
  LOG_ROTATE_COUNT="${REMOTE_BOOT_MONITOR_LOG_ROTATE_COUNT}"
fi

set -- "${ORIGINAL_ARGS[@]}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      shift 2
      ;;
    --on-calendar)
      ON_CALENDAR="$2"
      shift 2
      ;;
    --log-file)
      LOG_FILE="$2"
      shift 2
      ;;
    --rotate-count)
      LOG_ROTATE_COUNT="$2"
      shift 2
      ;;
    --force)
      FORCE_INSTALL=true
      shift
      ;;
    --start-now)
      START_NOW=true
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

require_command "systemctl" "systemd must be available."
require_command "ansible" "Install Ansible or ensure it is available in PATH."

if ! command -v sudo >/dev/null 2>&1 && [[ "$(id -u)" -ne 0 ]]; then
  echo "Error: sudo is required to install system units under /etc/systemd/system." >&2
  exit 1
fi

for script_path in "${SCRIPT_DIR}"/*.sh; do
  if [[ -f "${script_path}" && ! -x "${script_path}" ]]; then
    chmod +x "${script_path}"
  fi
done

if ! [[ "${LOG_ROTATE_COUNT}" =~ ^[0-9]+$ ]] || [[ "${LOG_ROTATE_COUNT}" -lt 1 ]]; then
  echo "Error: --rotate-count must be a positive integer." >&2
  exit 1
fi

install_user="${SUDO_USER:-$USER}"
install_group="$(id -gn "${install_user}")"

run_as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

service_tmp="${tmp_dir}/${SERVICE_NAME}.service"
timer_tmp="${tmp_dir}/${SERVICE_NAME}.timer"
logrotate_tmp="${tmp_dir}/${SERVICE_NAME}.logrotate"

cat >"${service_tmp}" <<EOF
[Unit]
Description=Periodic remote host/container health monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=${install_user}
Group=${install_group}
WorkingDirectory=${PROJECT_ROOT}
ExecStart=${RUNNER_SCRIPT} --config ${CONFIG_FILE}
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF

cat >"${timer_tmp}" <<EOF
[Unit]
Description=Run remote host/container health monitor every 15 minutes

[Timer]
OnCalendar=${ON_CALENDAR}
Persistent=true
Unit=${SERVICE_NAME}.service

[Install]
WantedBy=timers.target
EOF

cat >"${logrotate_tmp}" <<EOF
${LOG_FILE} {
    daily
    rotate ${LOG_ROTATE_COUNT}
    compress
    delaycompress
    missingok
    notifempty
    create 0640 ${install_user} ${install_group}
}
EOF

sync_root_file() {
  local source_file="$1"
  local target_file="$2"
  local mode="$3"
  local label="$4"

  if run_as_root test -f "${target_file}"; then
    if [[ "${FORCE_INSTALL}" == "false" ]] && run_as_root cmp -s "${source_file}" "${target_file}"; then
      echo "${label} is already up to date: ${target_file}"
      return
    fi
    run_as_root install -D -m "${mode}" "${source_file}" "${target_file}"
    echo "Updated ${label}: ${target_file}"
    return
  fi

  run_as_root install -D -m "${mode}" "${source_file}" "${target_file}"
  echo "Installed ${label}: ${target_file}"
}

sync_root_file "${service_tmp}" "${SERVICE_FILE}" 0644 "service"
sync_root_file "${timer_tmp}" "${TIMER_FILE}" 0644 "timer"

if ! run_as_root test -f "${LOG_FILE}"; then
  run_as_root install -D -m 0640 /dev/null "${LOG_FILE}"
fi
run_as_root chown "${install_user}:${install_group}" "${LOG_FILE}"

sync_root_file "${logrotate_tmp}" "${LOGROTATE_FILE}" 0644 "logrotate config"

run_as_root systemctl daemon-reload
run_as_root systemctl enable "${SERVICE_NAME}.timer"

if run_as_root systemctl is-active --quiet "${SERVICE_NAME}.timer"; then
  run_as_root systemctl restart "${SERVICE_NAME}.timer"
else
  run_as_root systemctl start "${SERVICE_NAME}.timer"
fi

if [[ "${START_NOW}" == "true" ]]; then
  run_as_root systemctl start "${SERVICE_NAME}.service"
fi

if run_as_root systemctl is-active --quiet "${SERVICE_NAME}.timer"; then
  echo "Timer is active: ${SERVICE_NAME}.timer"
else
  echo "Warning: timer is not active: ${SERVICE_NAME}.timer" >&2
fi

echo "Next runs:"
run_as_root systemctl list-timers "${SERVICE_NAME}.timer" --no-pager || true

echo
if [[ "${START_NOW}" == "true" ]]; then
  echo "The monitor service was started immediately."
else
  echo "To run the monitor job immediately:"
  echo "  sudo systemctl start ${SERVICE_NAME}.service"
fi
echo
echo "Config file:"
echo "  ${CONFIG_FILE}"
echo "Log file:"
echo "  ${LOG_FILE}"
echo "Retention:"
echo "  ${LOG_ROTATE_COUNT} days via ${LOGROTATE_FILE}"
