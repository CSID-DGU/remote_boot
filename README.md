# Remote Boot

Wake-on-LAN targets can be sent automatically whenever this desktop boots.

## Files

- `script/common.sh`: shared ansible and server-id helpers for remote boot scripts
- `script/wake_targets.sh`: send magic packets for one or more named targets
- `script/run_remote_boot.sh`: boot entrypoint that loads config and runs the target script
- `script/create_test_container.sh`: create a temporary GPU container without touching the DB
- `script/delete_test_container.sh`: remove the temporary test container
- `script/check_server_boot_health.sh`: verify mount, GPU, container create, SSH service, and container GPU
- `script/wait_for_priority_servers.sh`: retry health checks until timeout before waking the rest
- `script/restart_all_remote_containers.sh`: run `docker restart $(docker ps -aq)` on selected servers with retry
- `script/integration_smoke_test.sh`: manual ansible/docker/GPU smoke test before enabling boot automation
- `script/dry_run_remote_boot.sh`: dry-run wrapper for wake, health, container, and full-flow simulations
- `script/test_slack_notification.sh`: send a real Slack test message using local config
- `script/install_remote_boot_service.sh`: installs and enables the systemd boot service
- `config/remote_boot.local.env`: local defaults used at boot time

## Quick start

1. Copy the example config and edit only your local file

```bash
cp config/remote_boot.example.env config/remote_boot.local.env
```

2. Fill in server-specific values in `config/remote_boot.local.env`
3. Review `config/remote_boot.local.env`
4. Install the boot service

```bash
./script/install_remote_boot_service.sh
```

5. Reboot, or run once manually

```bash
sudo systemctl start remote-boot.service
```

Service registration and management:

```bash
# Install and enable at boot
./script/install_remote_boot_service.sh

# Install and start immediately
./script/install_remote_boot_service.sh --start-now

# Check status
systemctl status remote-boot.service

# Read logs
journalctl -u remote-boot.service -b
tail -f /var/log/remote-boot.log
```

## Manual usage

List available targets:

```bash
./script/wake_targets.sh --list-targets
```

Wake a group manually:

```bash
./script/wake_targets.sh all
```

Boot orchestration with staged wake-up:

- `REMOTE_BOOT_PRIORITY_TARGETS="FARM1 LAB1"` is sent first
- `REMOTE_BOOT_ENABLE_GATE=true` waits for priority servers to pass health checks
- the gate retries for up to `REMOTE_BOOT_GATE_TIMEOUT_SECONDS=360`
- once the gate passes, the remaining selected targets are sent
- finally, if `REMOTE_BOOT_ENABLE_CONTAINER_RESTART=true`, all selected servers run a full docker container restart, then each restarted container is checked for `ssh` and `nvidia-smi`
- when a recovery path still cannot fix the issue, the system tries to send a Slack webhook alert and falls back to a stub alert log if Slack is disabled or delivery fails

Standalone test container commands:

```bash
./script/create_test_container.sh --server-id FARM1
./script/delete_test_container.sh --server-id FARM1
```

Recommended manual integration test:

```bash
./script/integration_smoke_test.sh --scope priority
```

Dry-run entrypoints:

```bash
# 1. WOL call simulation
./script/dry_run_remote_boot.sh wake FARM1 LAB1

# 2. Host mount/GPU check plus test-container plan
./script/dry_run_remote_boot.sh health FARM1

# 3. Restart-all-containers flow and per-container SSH/GPU plan
./script/dry_run_remote_boot.sh containers FARM1

# 4. Full orchestration
./script/dry_run_remote_boot.sh --scope priority full
./script/dry_run_remote_boot.sh full
```

Dry-run behavior:

- `wake` and `full` do not send WOL packets, sleep, create containers, restart Docker, or restart containers.
- `health` validates config and inventory, then prints the exact host checks, test-container create/delete commands, and automatic recovery commands that would be used.
- `containers` does not restart anything, but it does read the current remote container inventory so it can show which containers would receive SSH checks and which ones would receive GPU checks.
- For actual verification after a host is already up, use `./script/check_server_boot_health.sh --server-id FARM1` and `./script/restart_all_remote_containers.sh FARM1`.

## Config guide

`config/remote_boot.local.env` is grouped into these sections:

- Remote boot target groups:
  `REMOTE_BOOT_FARM_TARGETS`, `REMOTE_BOOT_LAB_TARGETS`, `REMOTE_BOOT_TARGETS`
- Boot order and gate behavior:
  `REMOTE_BOOT_PRIORITY_TARGETS`, `REMOTE_BOOT_ENABLE_GATE`, `REMOTE_BOOT_GATE_*`, `REMOTE_BOOT_SECONDARY_DELAY_SECONDS`
- Post-boot container restart flow:
  `REMOTE_BOOT_ENABLE_CONTAINER_RESTART`, `REMOTE_BOOT_CONTAINER_RESTART_*`, `REMOTE_BOOT_CONTAINER_POST_RESTART_CHECK_*`
- Ansible / network:
  `REMOTE_BOOT_ANSIBLE_INVENTORY`, broadcast IPs
- Wake-on-LAN MAC addresses:
  `REMOTE_BOOT_MAC_<TARGET>`
- Host health-check requirements:
  required NFS mounts, `REMOTE_BOOT_HOST_SHARE_MOUNT_TEMPLATE`
- Temporary test container for health checks:
  `REMOTE_BOOT_TEST_*`
- Logging / alerts:
  `REMOTE_BOOT_ENABLE_HEALTH_LOGGING`, log paths, rotate count

Most commonly changed options:

- `REMOTE_BOOT_TARGETS`:
  default targets to boot
- `REMOTE_BOOT_PRIORITY_TARGETS`:
  first servers to wake and verify
- `REMOTE_BOOT_ENABLE_GATE`:
  whether the remaining servers wait for priority health checks
- `REMOTE_BOOT_ENABLE_CONTAINER_RESTART`:
  whether all containers are restarted after boot
- `REMOTE_BOOT_TEST_IMAGE_REPOSITORY`, `REMOTE_BOOT_TEST_IMAGE`, `REMOTE_BOOT_TEST_VERSION`:
  the temporary health-check container image
- `REMOTE_BOOT_FARM_TARGETS`, `REMOTE_BOOT_LAB_TARGETS`, `REMOTE_BOOT_MAC_<TARGET>`:
  what exists in each group and how to wake it
- `REMOTE_BOOT_SLACK_ENABLED`, `REMOTE_BOOT_SLACK_WEBHOOK_URL`:
  whether real Slack alerts are sent and which webhook receives them

## Slack test

1. In `config/remote_boot.local.env`, set:

```bash
REMOTE_BOOT_SLACK_ENABLED=true
REMOTE_BOOT_SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."
```

2. Send a test message:

```bash
./script/test_slack_notification.sh
```

You can also override the message text:

```bash
./script/test_slack_notification.sh --message "remote_boot slack test"
```

If Slack is configured, real alert paths now try Slack first and fall back to `REMOTE_BOOT_ALERT_STUB_LOG_FILE` if delivery fails.

Manual health-check logs:

```bash
./script/check_server_boot_health.sh --server-id FARM1
```

This keeps terminal output and also writes a per-run log under `logs/health/` by default.
Use `--log-file /path/to/file.log` to override the destination.

Log format:

```text
2026-03-11T15:10:00+0900 [HEALTH] context=check_server_boot_health server=FARM1 stage=mount_check required_mount=...
```

## Git

- `config/remote_boot.local.env` is ignored by `.gitignore`
- commit `config/remote_boot.example.env` and keep real server-specific values, including MAC addresses, only in `config/remote_boot.local.env`
- when a server is added, update `REMOTE_BOOT_FARM_TARGETS` or `REMOTE_BOOT_LAB_TARGETS` plus the matching `REMOTE_BOOT_MAC_<TARGET>` value in `config/remote_boot.local.env`

## Notes

- `wakeonlan` must be installed on this desktop.
- `wake_targets.sh` reads MAC addresses from `REMOTE_BOOT_MAC_<TARGET>` variables in `config/remote_boot.local.env`.
- `LAB*` targets use `192.168.1.255`, and `FARM*` targets use `192.168.2.255` by default.
- remote scripts can use `REMOTE_BOOT_ANSIBLE_INVENTORY`, or fall back to your existing `ansible.cfg` default inventory.
- host mount checks expect `100.100.100.100:/294t/dcloud/share` for LAB and `100.100.100.120:/volume1/share` for FARM.
- host NFS remount recovery uses `REMOTE_BOOT_HOST_SHARE_MOUNT_TEMPLATE`, which defaults to `/home/tako%s/share`.
- automatic recovery commands use `sudo -n` on the remote hosts; if passwordless sudo is not available there, recovery will not run and the failure will fall through to the alert stub log.
- boot health checks create a temporary GPU test container directly via Docker and remove it without writing to the DB.
- health-check runs can write per-run logs to `REMOTE_BOOT_HEALTH_LOG_DIR` when `REMOTE_BOOT_ENABLE_HEALTH_LOGGING=true`.
- service and orchestration logs use an ISO timestamp plus tag format like `[BOOT]`, `[GATE]`, `[HEALTH]`, `[WAKE]`, `[CONTAINER]`, and `[SMOKE]`.
- unrecovered failures are written to `REMOTE_BOOT_ALERT_STUB_LOG_FILE` when Slack is disabled or Slack delivery fails.
- test container share mounts can use `REMOTE_BOOT_TEST_SHARE_SOURCE_TEMPLATE="/home/tako%s/share/user-share/"`; `%s` is replaced with the server number, so `FARM1` and `LAB1` both use `/home/tako1/share/user-share/`.
- test container GPU launch uses `REMOTE_BOOT_TEST_DOCKER_RUNTIME="auto"` by default, so hosts without a registered `nvidia` runtime still run with `--gpus`.
- container restart uses `docker ps -aq`; after restart, each container is checked for SSH, but GPU checks run only for containers whose image is `decs` or `dguailab/decs` with any tag. CPU-only containers are logged as skipped.
- post-restart per-container checks use `REMOTE_BOOT_CONTAINER_POST_RESTART_CHECK_TIMEOUT_SECONDS` and `REMOTE_BOOT_CONTAINER_POST_RESTART_CHECK_POLL_SECONDS`.
- If the network is not ready at boot, increase `REMOTE_BOOT_PRE_DELAY_SECONDS`.
