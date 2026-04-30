#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${PROJECT_ROOT}/config"

SERVICE_NAME="cluster-monitor-exporter"
OLD_SERVICE_NAME="remote-boot-exporter"
UNIT_DIR="/etc/systemd/system"
SERVICE_FILE="${UNIT_DIR}/${SERVICE_NAME}.service"
CONFIG_FILE="${CONFIG_DIR}/cluster_monitor_exporter.local.env"
BINARY_FILE="/usr/local/bin/cluster-monitor-exporter"
RUN_USER="${CLUSTER_MONITOR_EXPORTER_SERVICE_USER:-${REMOTE_BOOT_EXPORTER_SERVICE_USER:-root}}"
RUN_GROUP="${CLUSTER_MONITOR_EXPORTER_SERVICE_GROUP:-${REMOTE_BOOT_EXPORTER_SERVICE_GROUP:-root}}"
FORCE_INSTALL=false
START_NOW=false
ORIGINAL_ARGS=("$@")

export GOCACHE="${GOCACHE:-/tmp/cluster-monitor-go-build}"

show_help() {
  cat <<EOF
Usage: $0 [options]

Options:
  --config PATH    exporter config file path
  --binary PATH    installed exporter binary path
  --user USER      systemd service user
  --group GROUP    systemd service group
  --force          rewrite files even when contents are unchanged
  --start-now      start the service immediately after install
  -h, --help       show this help
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

find_local_go() {
  if command -v go >/dev/null 2>&1; then
    command -v go
    return 0
  fi

  local candidate
  for candidate in /usr/local/go/bin/go /usr/lib/go-*/bin/go /opt/go/bin/go; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

find_local_gofmt() {
  if command -v gofmt >/dev/null 2>&1; then
    command -v gofmt
    return 0
  fi

  local candidate
  for candidate in /usr/local/go/bin/gofmt /usr/lib/go-*/bin/gofmt /opt/go/bin/gofmt; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

run_as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

if [[ -f "${CONFIG_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
  set +a
elif [[ -f "${CONFIG_DIR}/cluster_monitor_exporter.example.env" ]]; then
  CONFIG_FILE="${CONFIG_DIR}/cluster_monitor_exporter.example.env"
elif [[ -f "${CONFIG_DIR}/remote_boot_exporter.local.env" ]]; then
  CONFIG_FILE="${CONFIG_DIR}/remote_boot_exporter.local.env"
elif [[ -f "${CONFIG_DIR}/remote_boot_exporter.example.env" ]]; then
  CONFIG_FILE="${CONFIG_DIR}/remote_boot_exporter.example.env"
fi

set -- "${ORIGINAL_ARGS[@]}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --binary)
      BINARY_FILE="$2"
      shift 2
      ;;
    --user)
      RUN_USER="$2"
      shift 2
      ;;
    --group)
      RUN_GROUP="$2"
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

GO_BINARY="$(find_local_go)" || {
  echo "Error: go is required. Install Go or add it to PATH." >&2
  exit 1
}

if ! command -v sudo >/dev/null 2>&1 && [[ "$(id -u)" -ne 0 ]]; then
  echo "Error: sudo is required to install system units under /etc/systemd/system." >&2
  exit 1
fi

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Error: exporter config file not found: ${CONFIG_FILE}" >&2
  echo "Hint: copy config/cluster_monitor_exporter.example.env to config/cluster_monitor_exporter.local.env and edit it." >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

binary_tmp="${tmp_dir}/cluster-monitor-exporter"
service_tmp="${tmp_dir}/${SERVICE_NAME}.service"

(
  cd "${PROJECT_ROOT}"
  if GOFMT_BINARY="$(find_local_gofmt 2>/dev/null)"; then
    "${GOFMT_BINARY}" -w cmd/cluster-monitor-exporter/main.go
  fi
  "${GO_BINARY}" build -o "${binary_tmp}" ./cmd/cluster-monitor-exporter
)

cat >"${service_tmp}" <<EOF
[Unit]
Description=Local Prometheus exporter for cluster host/container health
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_GROUP}
WorkingDirectory=${PROJECT_ROOT}
ExecStart=${BINARY_FILE} --config ${CONFIG_FILE}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
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

sync_root_file "${binary_tmp}" "${BINARY_FILE}" 0755 "exporter binary"
sync_root_file "${service_tmp}" "${SERVICE_FILE}" 0644 "service"

run_as_root systemctl daemon-reload
run_as_root systemctl disable --now "${OLD_SERVICE_NAME}.service" >/dev/null 2>&1 || true
run_as_root systemctl enable "${SERVICE_NAME}.service"

if [[ "${START_NOW}" == "true" ]]; then
  run_as_root systemctl restart "${SERVICE_NAME}.service"
fi

if run_as_root systemctl is-enabled --quiet "${SERVICE_NAME}.service"; then
  echo "Service is enabled: ${SERVICE_NAME}.service"
else
  echo "Warning: service is not enabled: ${SERVICE_NAME}.service" >&2
fi

echo
echo "Exporter install complete."
echo "Config: ${CONFIG_FILE}"
echo "Binary: ${BINARY_FILE}"
echo "Metrics: http://<server>:30074/metrics"
