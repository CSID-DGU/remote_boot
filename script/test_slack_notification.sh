#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/remote_boot.local.env"
MESSAGE_OVERRIDE=""

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"
set_log_context "test_slack_notification"

show_help() {
  cat <<EOF
Usage: $0 [options]

Options:
  --config PATH       config file path (default: ${CONFIG_FILE})
  --message TEXT      override the Slack test message
  -h, --help          show this help
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
    --message)
      if [[ $# -lt 2 ]]; then
        echo "Error: --message requires a value." >&2
        exit 1
      fi
      MESSAGE_OVERRIDE="$2"
      shift 2
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

if [[ -f "${CONFIG_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
  set +a
fi

if ! slack_notifications_enabled; then
  echo "Error: Slack is not fully configured." >&2
  echo "Set REMOTE_BOOT_SLACK_ENABLED=true and REMOTE_BOOT_SLACK_WEBHOOK_URL in ${CONFIG_FILE}." >&2
  exit 1
fi

test_message="${MESSAGE_OVERRIDE:-test_message=remote_boot_slack_ok host=$(hostname) time=$(log_timestamp)}"

if send_slack_message "${test_message}"; then
  echo "Slack test message sent successfully."
else
  echo "Slack test message failed." >&2
  exit 1
fi
