#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/remote_boot.local.env"
TARGETS_OVERRIDE=""
PORT="${CLUSTER_MONITOR_EXPORTER_PORT:-${REMOTE_BOOT_EXPORTER_PORT:-30074}}"
BUILD_BINARY="${PROJECT_ROOT}/bin/cluster-monitor-exporter"
REMOTE_BINARY="/usr/local/bin/cluster-monitor-exporter"
REMOTE_CONFIG="/etc/default/cluster-monitor-exporter"
REMOTE_SERVICE="/etc/systemd/system/cluster-monitor-exporter.service"
SERVICE_NAME="cluster-monitor-exporter"
OLD_SERVICE_NAME="remote-boot-exporter"
DRY_RUN=false
SKIP_BUILD=false

export ANSIBLE_LOCAL_TEMP="${ANSIBLE_LOCAL_TEMP:-/tmp/ansible-local}"
export ANSIBLE_REMOTE_TEMP="${ANSIBLE_REMOTE_TEMP:-/tmp/.ansible/tmp}"
export ANSIBLE_SSH_CONTROL_PATH_DIR="${ANSIBLE_SSH_CONTROL_PATH_DIR:-/tmp/ansible-cp}"
export GOCACHE="${GOCACHE:-/tmp/cluster-monitor-go-build}"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"
set_log_context "deploy_cluster_monitor_exporter"

render_server_template() {
  local template="$1"
  local server_number="$2"

  printf "${template}" "${server_number}"
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

show_help() {
  cat <<EOF
Usage: $0 [options] [TARGET ...]

Options:
  --config PATH     remote_boot config file path (default: ${CONFIG_FILE})
  --targets VALUE   comma or space separated target list (default: all)
  --port PORT       exporter listen port (default: ${PORT})
  --binary PATH     local build output path (default: ${BUILD_BINARY})
  --skip-build      deploy the existing local binary without rebuilding
  --dry-run         print the deploy plan only
  -h, --help        show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --targets)
      TARGETS_OVERRIDE="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    --binary)
      BUILD_BINARY="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=true
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

load_remote_boot_runtime
if [[ -z "${ANSIBLE_INVENTORY:-}" && -f /home/jy/ansible/inventory.ini ]]; then
  ANSIBLE_INVENTORY="/home/jy/ansible/inventory.ini"
fi
load_target_groups

REMOTE_BOOT_FARM_REQUIRED_MOUNT="${REMOTE_BOOT_FARM_REQUIRED_MOUNT:-100.100.100.120:/volume1/share}"
REMOTE_BOOT_LAB_REQUIRED_MOUNT="${REMOTE_BOOT_LAB_REQUIRED_MOUNT:-100.100.100.100:/294t/dcloud/share}"
REMOTE_BOOT_HOST_SHARE_MOUNT_TEMPLATE="${REMOTE_BOOT_HOST_SHARE_MOUNT_TEMPLATE:-/home/tako%s/share}"
CLUSTER_MONITOR_EXPORTER_CHECK_INTERVAL="${CLUSTER_MONITOR_EXPORTER_CHECK_INTERVAL:-${REMOTE_BOOT_EXPORTER_CHECK_INTERVAL:-30s}}"
CLUSTER_MONITOR_EXPORTER_COMMAND_TIMEOUT="${CLUSTER_MONITOR_EXPORTER_COMMAND_TIMEOUT:-${REMOTE_BOOT_EXPORTER_COMMAND_TIMEOUT:-10s}}"
CLUSTER_MONITOR_EXPORTER_CONTAINER_CHECK_TIMEOUT="${CLUSTER_MONITOR_EXPORTER_CONTAINER_CHECK_TIMEOUT:-${REMOTE_BOOT_EXPORTER_CONTAINER_CHECK_TIMEOUT:-60s}}"
CLUSTER_MONITOR_EXPORTER_CONTAINER_CHECK_POLL="${CLUSTER_MONITOR_EXPORTER_CONTAINER_CHECK_POLL:-${REMOTE_BOOT_EXPORTER_CONTAINER_CHECK_POLL:-5s}}"
CLUSTER_MONITOR_EXPORTER_CONTAINER_NVML_RECOVERY_ENABLED="${CLUSTER_MONITOR_EXPORTER_CONTAINER_NVML_RECOVERY_ENABLED:-${REMOTE_BOOT_EXPORTER_CONTAINER_NVML_RECOVERY_ENABLED:-true}}"
CLUSTER_MONITOR_EXPORTER_CONTAINER_IMAGE_REGEX="${CLUSTER_MONITOR_EXPORTER_CONTAINER_IMAGE_REGEX:-${REMOTE_BOOT_EXPORTER_CONTAINER_IMAGE_REGEX:-${REMOTE_BOOT_CONTAINER_TARGET_IMAGE_REGEX:-^(decs|dguailab/decs)(:|$)}}}"

if ! [[ "${PORT}" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "Error: --port must be a TCP port number." >&2
  exit 1
fi

declare -a selected_targets=()
if [[ $# -gt 0 ]]; then
  selected_targets=("$@")
elif [[ -n "${TARGETS_OVERRIDE}" ]]; then
  parse_target_string "${TARGETS_OVERRIDE}"
  selected_targets=("${PARSED_TARGETS[@]}")
else
  selected_targets=("all")
fi

expand_target_list "${selected_targets[@]}"
selected_targets=("${EXPANDED_TARGETS[@]}")

if [[ ${#selected_targets[@]} -eq 0 ]]; then
  echo "Error: no deploy targets were selected." >&2
  exit 1
fi

require_ansible_cli || exit 1
require_ansible_inventory || exit 1

if [[ "${DRY_RUN}" == "true" ]]; then
  log_dry_run "action=deploy_plan targets=\"${selected_targets[*]}\" port=${PORT} binary=${BUILD_BINARY}"
  exit 0
fi

build_with_local_go() {
  local go_binary gofmt_binary

  go_binary="$(find_local_go)" || return 1
  mkdir -p "$(dirname "${BUILD_BINARY}")"

  if gofmt_binary="$(find_local_gofmt 2>/dev/null)"; then
    "${gofmt_binary}" -w "${PROJECT_ROOT}/cmd/cluster-monitor-exporter/main.go"
  fi

  (
    cd "${PROJECT_ROOT}"
    "${go_binary}" build -o "${BUILD_BINARY}" ./cmd/cluster-monitor-exporter
  )
}

find_remote_go_builder() {
  local server_id domain_name server_number host_alias

  for server_id in "${selected_targets[@]}"; do
    read domain_name server_number <<<"$(split_server_id "${server_id}")" || return 1
    server_number="$(validate_server_number "${server_number}")" || return 1
    host_alias="$(compose_ansible_host_alias "${domain_name}" "${server_number}")"

    if run_remote_shell "${host_alias}" "command -v go >/dev/null 2>&1" >/dev/null 2>&1; then
      printf '%s %s\n' "${server_id}" "${host_alias}"
      return 0
    fi
  done

  return 1
}

build_with_remote_go() {
  local builder_info builder_server builder_host remote_src remote_binary

  if ! builder_info="$(find_remote_go_builder)"; then
    echo "Error: Go is not installed locally and no selected target has Go." >&2
    exit 1
  fi

  read builder_server builder_host <<<"${builder_info}"
  remote_src="/tmp/cluster-monitor-exporter-src"
  remote_binary="/tmp/cluster-monitor-exporter-built"

  log_event "EXPORTER" "action=remote_build_start builder=${builder_server} host=${builder_host}"
  run_remote_shell "${builder_host}" "rm -rf '${remote_src}' '${remote_binary}' && mkdir -p '${remote_src}/cmd/cluster-monitor-exporter'" >/dev/null
  run_ansible "${builder_host}" -m copy -a "src=${PROJECT_ROOT}/go.mod dest=${remote_src}/go.mod mode=0644" >/dev/null
  run_ansible "${builder_host}" -m copy -a "src=${PROJECT_ROOT}/cmd/cluster-monitor-exporter/main.go dest=${remote_src}/cmd/cluster-monitor-exporter/main.go mode=0644" >/dev/null
  run_remote_shell "${builder_host}" "cd '${remote_src}' && go fmt ./cmd/cluster-monitor-exporter >/dev/null && go build -o '${remote_binary}' ./cmd/cluster-monitor-exporter" >/dev/null

  mkdir -p "$(dirname "${BUILD_BINARY}")"
  run_ansible "${builder_host}" -m fetch -a "src=${remote_binary} dest=${BUILD_BINARY} flat=yes" >/dev/null
  chmod +x "${BUILD_BINARY}"
  log_event "EXPORTER" "action=remote_build_complete builder=${builder_server} binary=${BUILD_BINARY}"
}

if [[ "${SKIP_BUILD}" == "false" ]]; then
  if find_local_go >/dev/null 2>&1; then
    build_with_local_go
  else
    build_with_remote_go
  fi
fi

if [[ ! -x "${BUILD_BINARY}" ]]; then
  echo "Error: exporter binary not found or not executable: ${BUILD_BINARY}" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

unit_file="${tmp_dir}/cluster-monitor-exporter.service"
cat >"${unit_file}" <<EOF
[Unit]
Description=Local Prometheus exporter for cluster host/container health
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=${REMOTE_BINARY} --config ${REMOTE_CONFIG}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

deploy_target() {
  local server_id="$1"
  local domain_name server_number host_alias host_mount_path required_mount
  local env_file remote_tmp_binary remote_tmp_env remote_tmp_unit verify_command

  read domain_name server_number <<<"$(split_server_id "${server_id}")" || return 1
  server_number="$(validate_server_number "${server_number}")" || return 1
  host_alias="$(compose_ansible_host_alias "${domain_name}" "${server_number}")"
  host_mount_path="$(render_server_template "${REMOTE_BOOT_HOST_SHARE_MOUNT_TEMPLATE}" "${server_number}")"
  ensure_ansible_host_exists "${host_alias}" || return 1

  case "${domain_name}" in
    FARM)
      required_mount="${REMOTE_BOOT_FARM_REQUIRED_MOUNT}"
      ;;
    LAB)
      required_mount="${REMOTE_BOOT_LAB_REQUIRED_MOUNT}"
      ;;
    *)
      echo "Error: unsupported domain '${domain_name}'." >&2
      return 1
      ;;
  esac

  env_file="${tmp_dir}/${server_id}.env"
  remote_tmp_binary="/tmp/cluster-monitor-exporter"
  remote_tmp_env="/tmp/cluster-monitor-exporter.env"
  remote_tmp_unit="/tmp/cluster-monitor-exporter.service"

  cat >"${env_file}" <<EOF
CLUSTER_MONITOR_EXPORTER_LISTEN_ADDR=":${PORT}"
CLUSTER_MONITOR_EXPORTER_SERVER_ID="${server_id}"
CLUSTER_MONITOR_EXPORTER_CHECK_INTERVAL="${CLUSTER_MONITOR_EXPORTER_CHECK_INTERVAL}"
CLUSTER_MONITOR_EXPORTER_COMMAND_TIMEOUT="${CLUSTER_MONITOR_EXPORTER_COMMAND_TIMEOUT}"
CLUSTER_MONITOR_EXPORTER_CONTAINER_CHECK_TIMEOUT="${CLUSTER_MONITOR_EXPORTER_CONTAINER_CHECK_TIMEOUT}"
CLUSTER_MONITOR_EXPORTER_CONTAINER_CHECK_POLL="${CLUSTER_MONITOR_EXPORTER_CONTAINER_CHECK_POLL}"
CLUSTER_MONITOR_EXPORTER_REQUIRED_MOUNTS="${required_mount}=${host_mount_path}"
CLUSTER_MONITOR_EXPORTER_HOST_GPU_CHECK_ENABLED=true
CLUSTER_MONITOR_EXPORTER_DOCKER_CHECK_ENABLED=true
CLUSTER_MONITOR_EXPORTER_CONTAINER_CHECKS_ENABLED=true
CLUSTER_MONITOR_EXPORTER_START_STOPPED_CONTAINERS=true
CLUSTER_MONITOR_EXPORTER_CONTAINER_SSH_RECOVERY_ENABLED=true
CLUSTER_MONITOR_EXPORTER_CONTAINER_NVML_RECOVERY_ENABLED="${CLUSTER_MONITOR_EXPORTER_CONTAINER_NVML_RECOVERY_ENABLED}"
CLUSTER_MONITOR_EXPORTER_CONTAINER_IMAGE_REGEX="${CLUSTER_MONITOR_EXPORTER_CONTAINER_IMAGE_REGEX}"
CLUSTER_MONITOR_EXPORTER_DOCKER_PATH="docker"
CLUSTER_MONITOR_EXPORTER_NVIDIA_SMI_PATH="nvidia-smi"
EOF

  log_event "EXPORTER" "server=${server_id} host=${host_alias} action=copy"
  run_ansible "${host_alias}" -m copy -a "src=${BUILD_BINARY} dest=${remote_tmp_binary} mode=0755" >/dev/null
  run_ansible "${host_alias}" -m copy -a "src=${env_file} dest=${remote_tmp_env} mode=0644" >/dev/null
  run_ansible "${host_alias}" -m copy -a "src=${unit_file} dest=${remote_tmp_unit} mode=0644" >/dev/null

  log_event "EXPORTER" "server=${server_id} host=${host_alias} action=install"
  run_remote_shell "${host_alias}" "sudo -n install -D -m 0755 '${remote_tmp_binary}' '${REMOTE_BINARY}' && sudo -n install -D -m 0644 '${remote_tmp_env}' '${REMOTE_CONFIG}' && sudo -n install -D -m 0644 '${remote_tmp_unit}' '${REMOTE_SERVICE}' && sudo -n systemctl daemon-reload && (sudo -n systemctl disable --now '${OLD_SERVICE_NAME}.service' >/dev/null 2>&1 || true) && sudo -n systemctl enable --now '${SERVICE_NAME}.service'" >/dev/null

  verify_command="deadline=\$((\$(date +%s) + 180)); while [ \$(date +%s) -lt \$deadline ]; do sudo -n systemctl is-active --quiet '${SERVICE_NAME}.service' && { if command -v curl >/dev/null 2>&1; then curl -fsS 'http://127.0.0.1:${PORT}/metrics'; else wget -qO- 'http://127.0.0.1:${PORT}/metrics'; fi; } | grep -E 'cluster_monitor_exporter_info|cluster_monitor_docker_daemon_up|cluster_monitor_host_gpu_up' >/dev/null && exit 0; sleep 2; done; sudo -n systemctl status '${SERVICE_NAME}.service' --no-pager; exit 1"
  log_event "EXPORTER" "server=${server_id} host=${host_alias} action=verify"
  run_remote_shell "${host_alias}" "${verify_command}" >/dev/null
  log_event "EXPORTER" "server=${server_id} host=${host_alias} action=passed port=${PORT}"
}

for server_id in "${selected_targets[@]}"; do
  deploy_target "${server_id}"
done

log_event "EXPORTER" "status=passed targets=\"${selected_targets[*]}\" port=${PORT}"
