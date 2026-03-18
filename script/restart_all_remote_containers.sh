#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/remote_boot.local.env"
TIMEOUT_OVERRIDE=""
POLL_OVERRIDE=""
DRY_RUN=false
MONITOR_MODE=false

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"
set_log_context "restart_all_remote_containers"

show_help() {
  cat <<EOF
Usage: $0 [options] SERVER_ID [SERVER_ID ...]

Options:
  --config PATH           config file path (default: ${CONFIG_FILE})
  --timeout-seconds N     overall timeout for start/post-check completion
  --poll-seconds N        retry interval between attempts
  --monitor-mode          run limited container checks with start/ssh recovery only
  --dry-run               inspect container inventory and print the start/post-check plan only
  -h, --help              show this help
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
    --timeout-seconds)
      if [[ $# -lt 2 ]]; then
        echo "Error: --timeout-seconds requires a value." >&2
        exit 1
      fi
      TIMEOUT_OVERRIDE="$2"
      shift 2
      ;;
    --poll-seconds)
      if [[ $# -lt 2 ]]; then
        echo "Error: --poll-seconds requires a value." >&2
        exit 1
      fi
      POLL_OVERRIDE="$2"
      shift 2
      ;;
    --monitor-mode)
      MONITOR_MODE=true
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

if [[ $# -eq 0 ]]; then
  echo "Error: at least one SERVER_ID is required." >&2
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

REMOTE_BOOT_CONTAINER_RESTART_TIMEOUT_SECONDS="${REMOTE_BOOT_CONTAINER_RESTART_TIMEOUT_SECONDS:-600}"
REMOTE_BOOT_CONTAINER_RESTART_POLL_SECONDS="${REMOTE_BOOT_CONTAINER_RESTART_POLL_SECONDS:-20}"
REMOTE_BOOT_CONTAINER_POST_RESTART_CHECK_TIMEOUT_SECONDS="${REMOTE_BOOT_CONTAINER_POST_RESTART_CHECK_TIMEOUT_SECONDS:-60}"
REMOTE_BOOT_CONTAINER_POST_RESTART_CHECK_POLL_SECONDS="${REMOTE_BOOT_CONTAINER_POST_RESTART_CHECK_POLL_SECONDS:-5}"
REMOTE_BOOT_CONTAINER_TARGET_IMAGE_REGEX="${REMOTE_BOOT_CONTAINER_TARGET_IMAGE_REGEX:-^(decs|dguailab/decs)(:|$)}"

if [[ -n "${TIMEOUT_OVERRIDE}" ]]; then
  REMOTE_BOOT_CONTAINER_RESTART_TIMEOUT_SECONDS="${TIMEOUT_OVERRIDE}"
fi

if [[ -n "${POLL_OVERRIDE}" ]]; then
  REMOTE_BOOT_CONTAINER_RESTART_POLL_SECONDS="${POLL_OVERRIDE}"
fi

if ! [[ "${REMOTE_BOOT_CONTAINER_RESTART_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || ! [[ "${REMOTE_BOOT_CONTAINER_RESTART_POLL_SECONDS}" =~ ^[0-9]+$ ]] || ! [[ "${REMOTE_BOOT_CONTAINER_POST_RESTART_CHECK_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || ! [[ "${REMOTE_BOOT_CONTAINER_POST_RESTART_CHECK_POLL_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "Error: restart and post-restart timeout values must be numeric." >&2
  exit 1
fi

load_remote_boot_runtime

require_ansible_cli || exit 1
require_ansible_inventory || exit 1

is_target_container_image() {
  local container_image="$1"
  printf '%s\n' "${container_image}" | grep -Eq "${REMOTE_BOOT_CONTAINER_TARGET_IMAGE_REGEX}"
}

extract_container_failure_detail() {
  local output="$1"
  local failure_line reason_value container_value container_id_value

  failure_line="$(printf '%s\n' "${output}" | grep -E 'stage=container_monitor .*reason=(docker_start_failed|container_not_running|ssh_unavailable|gpu_unavailable)|reason=(docker_start_failed|container_not_running|ssh_unavailable|gpu_unavailable)' | tail -n 1 || true)"
  [[ -n "${failure_line}" ]] || return 1

  reason_value="$(printf '%s\n' "${failure_line}" | sed -n 's/.*reason=\([^[:space:]]*\).*/\1/p' | head -n 1)"
  container_value="$(printf '%s\n' "${failure_line}" | sed -n 's/.*container=\([^[:space:]]*\).*/\1/p' | head -n 1)"
  container_id_value="$(printf '%s\n' "${failure_line}" | sed -n 's/.*container_id=\([^[:space:]]*\).*/\1/p' | head -n 1)"

  [[ -n "${reason_value}" ]] || return 1

  printf 'reason=%s' "${reason_value}"
  if [[ -n "${container_value}" ]]; then
    printf ' container=%s' "${container_value}"
  fi
  if [[ -n "${container_id_value}" ]]; then
    printf ' container_id=%s' "${container_id_value}"
  fi
  printf '\n'
}

extract_container_failure_summary() {
  local output="$1"
  local summary_line

  summary_line="$(printf '%s\n' "${output}" | grep -E 'stage=container_monitor|FAILED \| rc=|UNREACHABLE!' | tail -n 1 || true)"
  [[ -n "${summary_line}" ]] || return 1

  summary_line="$(flatten_command "${summary_line}")"
  printf '%s\n' "${summary_line}"
}

dry_run_restart_plan() {
  local server_id="$1"
  local host_alias="$2"
  local inventory_output container_lines
  local container_id container_name container_status container_image
  local matched_target_count=0

  if is_truthy "${MONITOR_MODE}"; then
    log_dry_run "stage=container_monitor server=${server_id} action=monitor_plan host=${host_alias} overall_timeout_seconds=${REMOTE_BOOT_CONTAINER_RESTART_TIMEOUT_SECONDS} poll_seconds=${REMOTE_BOOT_CONTAINER_POST_RESTART_CHECK_POLL_SECONDS}"
    log_dry_run "stage=container_monitor server=${server_id} action=remote_command host=${host_alias} command=\"docker start <stopped_containers>\""
  else
    log_dry_run "server=${server_id} action=restart_plan host=${host_alias} overall_timeout_seconds=${REMOTE_BOOT_CONTAINER_RESTART_TIMEOUT_SECONDS} retry_poll_seconds=${REMOTE_BOOT_CONTAINER_RESTART_POLL_SECONDS}"
    log_dry_run "server=${server_id} action=remote_command host=${host_alias} command=\"docker start <stopped_containers>\""
    log_dry_run "server=${server_id} action=recovery_plan host=${host_alias} recovery=\"sudo -n systemctl restart docker || sudo -n service docker restart\""
  fi

  inventory_output="$(run_remote_shell_capture "${host_alias}" "docker ps -a --format '{% raw %}{{.ID}}|{{.Names}}|{{.Status}}|{{.Image}}{% endraw %}'")" || return 1
  container_lines="$(printf '%s\n' "${inventory_output}" | sed '1d')"

  if [[ -z "$(printf '%s' "${container_lines}" | tr -d '[:space:]')" ]]; then
    log_dry_run "server=${server_id} action=restart_skip reason=no_containers"
    return 0
  fi

  while IFS='|' read -r container_id container_name container_status container_image; do
    if [[ -z "${container_id}" ]]; then
      continue
    fi

    if ! is_target_container_image "${container_image}"; then
      log_dry_run "server=${server_id} action=container_skip host=${host_alias} container=${container_name} container_id=${container_id} reason=non_target_image image=${container_image}"
      continue
    fi

    matched_target_count=$((matched_target_count + 1))

    log_dry_run "server=${server_id} action=container_plan host=${host_alias} container=${container_name} container_id=${container_id} status=\"${container_status}\" image=${container_image}"
    if ! printf '%s\n' "${container_status}" | grep -Eq '^(Up|Restarting)\b'; then
      log_dry_run "server=${server_id} action=start_plan host=${host_alias} container=${container_name} container_id=${container_id} command=\"docker start '${container_id}'\""
    fi
    log_dry_run "server=${server_id} action=ssh_check_plan host=${host_alias} container=${container_name} container_id=${container_id} command=\"docker exec '${container_id}' sh -lc \\\"service ssh status >/dev/null 2>&1 || { [ -x /etc/init.d/ssh ] && /etc/init.d/ssh status >/dev/null 2>&1; } || ps -ef | grep '[s]shd' >/dev/null\\\"\""
    log_dry_run "server=${server_id} action=ssh_recovery_plan host=${host_alias} container=${container_name} container_id=${container_id} command=\"docker exec '${container_id}' sh -lc \\\"service ssh start >/dev/null 2>&1 || { [ -x /etc/init.d/ssh ] && /etc/init.d/ssh start >/dev/null 2>&1; } || true\\\"\""

    log_dry_run "server=${server_id} action=gpu_check_plan host=${host_alias} container=${container_name} container_id=${container_id} command=\"docker exec '${container_id}' nvidia-smi\""
    if ! is_truthy "${MONITOR_MODE}"; then
      log_dry_run "server=${server_id} action=gpu_recovery_plan host=${host_alias} container=${container_name} container_id=${container_id} command=\"docker restart '${container_id}'\""
    fi
  done <<< "${container_lines}"

  if (( matched_target_count == 0 )); then
    log_dry_run "server=${server_id} action=restart_skip host=${host_alias} reason=no_target_containers image_regex=${REMOTE_BOOT_CONTAINER_TARGET_IMAGE_REGEX}"
  fi
}

if dry_run_enabled; then
  for server_id in "$@"; do
    read domain_name server_number <<<"$(split_server_id "${server_id}")" || exit 1
    server_number="$(validate_server_number "${server_number}")" || exit 1
    host_alias="$(compose_ansible_host_alias "${domain_name}" "${server_number}")"
    ensure_ansible_host_exists "${host_alias}" || exit 1
    dry_run_restart_plan "${server_id}" "${host_alias}" || exit 1
  done
  log_event "CONTAINER" "action=dry_run_completed servers=\"$*\""
  exit 0
fi

restart_remote_containers() {
  local server_id="$1"
  local host_alias="$2"
  local local_timeout_seconds="$3"
  local remote_command

if is_truthy "${MONITOR_MODE}"; then
    remote_command="$(cat <<EOF
log_remote() {
  printf '%s [CONTAINER] server=${server_id} host=${host_alias} stage=container_monitor %s\n' "\$(date +%Y-%m-%dT%H:%M:%S%z)" "\$*"
}

log_remote_error() {
  printf '%s [ERROR] server=${server_id} host=${host_alias} stage=container_monitor %s\n' "\$(date +%Y-%m-%dT%H:%M:%S%z)" "\$*" >&2
}

target_container_ids=\$(docker ps -a --format '{% raw %}{{.ID}}|{{.Image}}{% endraw %}' | grep -E '${REMOTE_BOOT_CONTAINER_TARGET_IMAGE_REGEX}' | cut -d'|' -f1 || true)
if [ -z "\$(printf '%s' "\$target_container_ids" | tr -d '[:space:]')" ]; then
  log_remote "action=monitor_skip reason=no_target_containers image_regex=${REMOTE_BOOT_CONTAINER_TARGET_IMAGE_REGEX}"
  exit 0
fi

stopped_container_ids=\$(docker ps -a --format '{% raw %}{{.ID}}|{{.Status}}|{{.Image}}{% endraw %}' | grep -E '${REMOTE_BOOT_CONTAINER_TARGET_IMAGE_REGEX}' | awk -F'|' '\$2 !~ /^(Up|Restarting)/ {print \$1}' || true)
if [ -n "\$(printf '%s' "\$stopped_container_ids" | tr -d '[:space:]')" ]; then
  log_remote "action=start_stopped_start"
  if ! docker start \$stopped_container_ids; then
    log_remote_error "action=monitor_failed reason=docker_start_failed"
    exit 1
  fi
else
  log_remote "action=start_stopped_skip reason=no_stopped_containers"
fi

for container_id in \$target_container_ids; do
  container_name=\$(docker inspect --format '{% raw %}{{.Name}}{% endraw %}' "\$container_id" 2>/dev/null | sed 's#^/##')
  container_image=\$(docker inspect --format '{% raw %}{{.Config.Image}}{% endraw %}' "\$container_id" 2>/dev/null)
  container_running=\$(docker inspect --format '{% raw %}{{.State.Running}}{% endraw %}' "\$container_id" 2>/dev/null || true)
  if [ -z "\$container_name" ]; then
    container_name="\$container_id"
  fi

  if [ "\$container_running" != "true" ]; then
    log_remote_error "action=monitor_failed reason=container_not_running container=\$container_name container_id=\$container_id"
    exit 1
  fi

  log_remote "action=monitor_check_start container=\$container_name container_id=\$container_id"

  ssh_deadline=\$((\$(date +%s) + ${REMOTE_BOOT_CONTAINER_POST_RESTART_CHECK_TIMEOUT_SECONDS}))
  ssh_ready=0
  while [ "\$(date +%s)" -lt "\$ssh_deadline" ]; do
    if docker exec "\$container_id" sh -lc "service ssh status >/dev/null 2>&1 || { [ -x /etc/init.d/ssh ] && /etc/init.d/ssh status >/dev/null 2>&1; } || ps -ef | grep '[s]shd' >/dev/null"; then
      ssh_ready=1
      log_remote "action=ssh_ok container=\$container_name container_id=\$container_id"
      break
    fi

    log_remote "action=ssh_start_attempt container=\$container_name container_id=\$container_id"
    docker exec "\$container_id" sh -lc "service ssh start >/dev/null 2>&1 || { [ -x /etc/init.d/ssh ] && /etc/init.d/ssh start >/dev/null 2>&1; } || true" >/dev/null 2>&1 || true
    sleep ${REMOTE_BOOT_CONTAINER_POST_RESTART_CHECK_POLL_SECONDS}
  done

  if [ "\$ssh_ready" -ne 1 ]; then
    log_remote_error "action=monitor_failed reason=ssh_unavailable container=\$container_name container_id=\$container_id"
    exit 1
  fi

  gpu_deadline=\$((\$(date +%s) + ${REMOTE_BOOT_CONTAINER_POST_RESTART_CHECK_TIMEOUT_SECONDS}))
  gpu_ready=0
  while [ "\$(date +%s)" -lt "\$gpu_deadline" ]; do
    if docker exec "\$container_id" nvidia-smi >/dev/null 2>&1; then
      gpu_ready=1
      log_remote "action=gpu_ok container=\$container_name container_id=\$container_id"
      break
    fi
    sleep ${REMOTE_BOOT_CONTAINER_POST_RESTART_CHECK_POLL_SECONDS}
  done

  if [ "\$gpu_ready" -ne 1 ]; then
    log_remote_error "action=monitor_failed reason=gpu_unavailable container=\$container_name container_id=\$container_id"
    exit 1
  fi

  log_remote "action=monitor_check_passed container=\$container_name container_id=\$container_id"
done

log_remote "action=monitor_complete"
EOF
)"
  else
    remote_command="$(cat <<EOF
log_remote() {
  printf '%s [CONTAINER] server=${server_id} host=${host_alias} %s\n' "\$(date +%Y-%m-%dT%H:%M:%S%z)" "\$*"
}

log_remote_error() {
  printf '%s [ERROR] server=${server_id} host=${host_alias} %s\n' "\$(date +%Y-%m-%dT%H:%M:%S%z)" "\$*" >&2
}

all_container_ids=\$(docker ps -aq)
target_container_ids=\$(docker ps -a --format '{% raw %}{{.ID}}|{{.Image}}{% endraw %}' | grep -E '${REMOTE_BOOT_CONTAINER_TARGET_IMAGE_REGEX}' | cut -d'|' -f1 || true)
if [ -z "\$(printf '%s' "\$target_container_ids" | tr -d '[:space:]')" ]; then
  log_remote "action=restart_skip reason=no_target_containers image_regex=${REMOTE_BOOT_CONTAINER_TARGET_IMAGE_REGEX}"
  exit 0
fi

stopped_container_ids=\$(docker ps -a --format '{% raw %}{{.ID}}|{{.Status}}|{{.Image}}{% endraw %}' | grep -E '${REMOTE_BOOT_CONTAINER_TARGET_IMAGE_REGEX}' | awk -F'|' '\$2 !~ /^(Up|Restarting)/ {print \$1}' || true)
if [ -n "\$(printf '%s' "\$stopped_container_ids" | tr -d '[:space:]')" ]; then
  log_remote "action=start_stopped_start"
  if ! docker start \$stopped_container_ids; then
    log_remote "action=start_stopped_recovery_start recovery=docker_service_restart"
    sudo -n systemctl restart docker >/dev/null 2>&1 || sudo -n service docker restart >/dev/null 2>&1 || true
    sleep ${REMOTE_BOOT_CONTAINER_POST_RESTART_CHECK_POLL_SECONDS}

    if ! docker start \$stopped_container_ids; then
      log_remote_error "action=start_stopped_failed reason=docker_start_failed_after_recovery"
      exit 1
    fi
  fi
else
  log_remote "action=start_stopped_skip reason=no_stopped_containers"
fi

for container_id in \$target_container_ids; do
  container_name=\$(docker inspect --format '{% raw %}{{.Name}}{% endraw %}' "\$container_id" 2>/dev/null | sed 's#^/##')
  container_image=\$(docker inspect --format '{% raw %}{{.Config.Image}}{% endraw %}' "\$container_id" 2>/dev/null)
  container_running=\$(docker inspect --format '{% raw %}{{.State.Running}}{% endraw %}' "\$container_id" 2>/dev/null || true)
  if [ -z "\$container_name" ]; then
    container_name="\$container_id"
  fi

  if [ "\$container_running" != "true" ]; then
    log_remote "action=container_start_attempt container=\$container_name container_id=\$container_id"
    docker start "\$container_id" >/dev/null 2>&1 || true
  fi

  log_remote "action=post_check_start container=\$container_name container_id=\$container_id"

  ssh_deadline=\$((\$(date +%s) + ${REMOTE_BOOT_CONTAINER_POST_RESTART_CHECK_TIMEOUT_SECONDS}))
  ssh_ready=0
  while [ "\$(date +%s)" -lt "\$ssh_deadline" ]; do
    if docker exec "\$container_id" sh -lc "service ssh status >/dev/null 2>&1 || { [ -x /etc/init.d/ssh ] && /etc/init.d/ssh status >/dev/null 2>&1; } || ps -ef | grep '[s]shd' >/dev/null"; then
      ssh_ready=1
      log_remote "action=ssh_ok container=\$container_name container_id=\$container_id"
      break
    fi

    log_remote "action=ssh_start_attempt container=\$container_name container_id=\$container_id"
    docker exec "\$container_id" sh -lc "service ssh start >/dev/null 2>&1 || { [ -x /etc/init.d/ssh ] && /etc/init.d/ssh start >/dev/null 2>&1; } || true" >/dev/null 2>&1 || true
    sleep ${REMOTE_BOOT_CONTAINER_POST_RESTART_CHECK_POLL_SECONDS}
  done

  if [ "\$ssh_ready" -ne 1 ]; then
    log_remote_error "action=post_check_failed reason=ssh_unavailable container=\$container_name container_id=\$container_id"
    exit 1
  fi

  gpu_deadline=\$((\$(date +%s) + ${REMOTE_BOOT_CONTAINER_POST_RESTART_CHECK_TIMEOUT_SECONDS}))
  gpu_ready=0
  gpu_recovery_used=0
  while [ "\$(date +%s)" -lt "\$gpu_deadline" ]; do
    if docker exec "\$container_id" nvidia-smi >/dev/null 2>&1; then
      gpu_ready=1
      log_remote "action=gpu_ok container=\$container_name container_id=\$container_id"
      break
    fi

    if [ "\$gpu_recovery_used" -eq 0 ]; then
      log_remote "action=gpu_recovery_start recovery=container_restart container=\$container_name container_id=\$container_id"
      docker restart "\$container_id" >/dev/null 2>&1 || true
      gpu_recovery_used=1
    fi

    sleep ${REMOTE_BOOT_CONTAINER_POST_RESTART_CHECK_POLL_SECONDS}
  done

  if [ "\$gpu_ready" -ne 1 ]; then
    log_remote_error "action=post_check_failed reason=gpu_unavailable container=\$container_name container_id=\$container_id"
    exit 1
  fi

  log_remote "action=post_check_passed container=\$container_name container_id=\$container_id"
done

log_remote "action=restart_complete"
EOF
)"
  fi

  run_remote_shell_with_timeout "${host_alias}" "${remote_command}" "${local_timeout_seconds}"
}

if is_truthy "${MONITOR_MODE}"; then
  declare -a failed_servers=()
  declare -a passed_servers=()
  monitor_deadline=$((SECONDS + REMOTE_BOOT_CONTAINER_RESTART_TIMEOUT_SECONDS))
  local_output=""
  failure_detail=""
  failure_summary=""

  log_event "CONTAINER" "stage=container_monitor action=begin servers=\"$*\" timeout_seconds=${REMOTE_BOOT_CONTAINER_RESTART_TIMEOUT_SECONDS}"

  for server_id in "$@"; do
    remaining_time=$((monitor_deadline - SECONDS))
    if (( remaining_time <= 0 )); then
      notify_failure "server=${server_id} stage=container_monitor reason=timeout"
      exit 1
    fi

    read domain_name server_number <<<"$(split_server_id "${server_id}")" || exit 1
    server_number="$(validate_server_number "${server_number}")" || exit 1
    host_alias="$(compose_ansible_host_alias "${domain_name}" "${server_number}")"
    ensure_ansible_host_exists "${host_alias}" || exit 1
    log_event "CONTAINER" "stage=container_monitor server=${server_id} action=start host=${host_alias} remaining_time=${remaining_time}"

    if local_output="$(restart_remote_containers "${server_id}" "${host_alias}" "${remaining_time}" 2>&1)"; then
      [[ -n "${local_output}" ]] && printf '%s\n' "${local_output}"
      passed_servers+=("${server_id}")
      clear_failure_alerts_matching "server=${server_id} stage=container_monitor"
      log_event "CONTAINER" "stage=container_monitor server=${server_id} action=passed host=${host_alias}"
    else
      [[ -n "${local_output}" ]] && printf '%s\n' "${local_output}" >&2
      failed_servers+=("${server_id}")
      failure_detail="$(extract_container_failure_detail "${local_output}" || true)"
      failure_summary="$(extract_container_failure_summary "${local_output}" || true)"
      if [[ -n "${failure_detail}" ]]; then
        log_error "stage=container_monitor server=${server_id} host=${host_alias} ${failure_detail}"
      else
        log_error "stage=container_monitor server=${server_id} host=${host_alias} reason=container_health_check_failed"
      fi
      if [[ -n "${failure_detail}" ]]; then
        notify_failure "server=${server_id} stage=container_monitor ${failure_detail}"
      elif [[ -n "${failure_summary}" ]]; then
        notify_failure "server=${server_id} stage=container_monitor reason=container_health_check_failed detail=\"${failure_summary}\""
      else
        notify_failure "server=${server_id} stage=container_monitor reason=container_health_check_failed"
      fi
    fi
  done

  if [[ ${#failed_servers[@]} -gt 0 ]]; then
    log_error "stage=container_monitor action=failed failed_servers=\"${failed_servers[*]}\""
    exit 1
  fi

  log_event "CONTAINER" "stage=container_monitor action=complete servers=\"${passed_servers[*]}\""
  exit 0
fi

declare -a pending_servers=("$@")
declare -a restarted_servers=()
deadline=$((SECONDS + REMOTE_BOOT_CONTAINER_RESTART_TIMEOUT_SECONDS))
attempt=1

while [[ ${#pending_servers[@]} -gt 0 ]]; do
  declare -a next_pending=()

  log_event "CONTAINER" "action=restart_attempt attempt=${attempt} pending=\"${pending_servers[*]}\""
  for server_id in "${pending_servers[@]}"; do
    remaining_time=$((deadline - SECONDS))
    if (( remaining_time <= 0 )); then
      log_error "container_restart_timeout pending=\"${pending_servers[*]}\""
      notify_failure "stage=restart_all_remote_containers reason=timeout pending=\"${pending_servers[*]}\""
      exit 1
    fi

    read domain_name server_number <<<"$(split_server_id "${server_id}")" || exit 1
    server_number="$(validate_server_number "${server_number}")" || exit 1
    host_alias="$(compose_ansible_host_alias "${domain_name}" "${server_number}")"
    ensure_ansible_host_exists "${host_alias}" || exit 1

    if restart_remote_containers "${server_id}" "${host_alias}" "${remaining_time}"; then
      restarted_servers+=("${server_id}")
    else
      log_warn "server=${server_id} action=restart_attempt_failed host=${host_alias}"
      next_pending+=("${server_id}")
    fi
  done

  if [[ ${#next_pending[@]} -eq 0 ]]; then
    clear_failure_alerts_matching "stage=restart_all_remote_containers"
    log_event "CONTAINER" "action=restart_complete servers=\"${restarted_servers[*]}\""
    exit 0
  fi

  pending_servers=("${next_pending[@]}")
  remaining_time=$((deadline - SECONDS))
  if (( remaining_time <= 0 )); then
    log_error "container_restart_timeout pending=\"${pending_servers[*]}\""
    notify_failure "stage=restart_all_remote_containers reason=timeout pending=\"${pending_servers[*]}\""
    exit 1
  fi

  sleep_for="${REMOTE_BOOT_CONTAINER_RESTART_POLL_SECONDS}"
  if (( sleep_for > remaining_time )); then
    sleep_for="${remaining_time}"
  fi

  log_event "CONTAINER" "action=restart_pending servers=\"${pending_servers[*]}\" retry_in_seconds=${sleep_for}"
  sleep "${sleep_for}"
  attempt=$((attempt + 1))
done
