# Remote Boot

Wake-on-LAN and boot-time initialization for FARM/LAB servers.

This repository is responsible for turning servers on and running one-time boot checks. Periodic monitoring/exporter code is intentionally not kept here.

The only systemd unit managed by this repo is `remote-boot.service`. Cluster monitoring exporters and Prometheus alerting live with the Kubernetes monitoring assets, not in this repository.

## Files

- `script/common.sh`: shared Ansible, logging, alert, and server-id helpers
- `script/wake_targets.sh`: send WOL magic packets for selected targets
- `script/run_remote_boot.sh`: systemd boot entrypoint
- `script/install_remote_boot_service.sh`: install and enable `remote-boot.service`
- `script/check_server_boot_health.sh`: one-time boot health check for host mount/GPU and a temporary GPU test container
- `script/wait_for_priority_servers.sh`: wait for priority servers before waking the rest
- `script/restart_all_remote_containers.sh`: one-time post-boot container start and SSH/GPU post-check
- `script/create_test_container.sh`, `script/delete_test_container.sh`: temporary GPU test-container helpers
- `script/dry_run_remote_boot.sh`: dry-run wrapper for wake, health, container, and full-flow simulations
- `script/integration_smoke_test.sh`: manual Ansible/Docker/GPU smoke test
- `script/test_slack_notification.sh`: send a Slack test message using local config
- `script/reset_remote_boot_alert_state.sh`: clear stored alert suppression state
- `config/remote_boot.example.env`: example boot-time config
- `config/remote_boot.local.env`: ignored local config with real MACs and secrets

## Quick Start

```bash
cp config/remote_boot.example.env config/remote_boot.local.env
```

Edit `config/remote_boot.local.env`, then install the boot service:

```bash
./script/install_remote_boot_service.sh
```

Run once manually:

```bash
sudo systemctl start remote-boot.service
```

Check service logs:

```bash
systemctl status remote-boot.service
journalctl -u remote-boot.service -b
tail -f /var/log/remote-boot.log
```

## Boot Flow

- `REMOTE_BOOT_PRIORITY_TARGETS` are woken first.
- If `REMOTE_BOOT_ENABLE_GATE=true`, priority servers must pass one-time boot health checks before the remaining targets are woken.
- If `REMOTE_BOOT_ENABLE_REMAINING_HEALTH_CHECK=true`, remaining targets also run one-time boot health checks after wake-up.
- If `REMOTE_BOOT_ENABLE_CONTAINER_RESTART=true`, selected servers start stopped target containers and run one-time per-container SSH/GPU post-checks.
- Unrecovered boot-time failures are sent to Slack when configured, otherwise they are written to the alert stub log.

## Manual Usage

List targets:

```bash
./script/wake_targets.sh --list-targets
```

Wake targets:

```bash
./script/wake_targets.sh all
./script/wake_targets.sh FARM1 LAB1
```

Run one-time boot health checks:

```bash
./script/check_server_boot_health.sh --server-id FARM1
```

Run one-time post-boot container start/post-check:

```bash
./script/restart_all_remote_containers.sh FARM1
```

Run a smoke test:

```bash
./script/integration_smoke_test.sh --scope priority
```

## Dry Runs

```bash
./script/dry_run_remote_boot.sh wake FARM1 LAB1
./script/dry_run_remote_boot.sh health FARM1
./script/dry_run_remote_boot.sh containers FARM1
./script/dry_run_remote_boot.sh --scope priority full
./script/dry_run_remote_boot.sh full
```

Dry runs do not send WOL packets, sleep, create containers, restart Docker, or restart containers. Container dry runs still read remote container inventory so the plan reflects current state.

## Config Guide

Commonly changed values in `config/remote_boot.local.env`:

- `REMOTE_BOOT_TARGETS`: default boot targets
- `REMOTE_BOOT_FARM_TARGETS`, `REMOTE_BOOT_LAB_TARGETS`: known server groups
- `REMOTE_BOOT_PRIORITY_TARGETS`: first servers to wake and verify
- `REMOTE_BOOT_ENABLE_GATE`: whether remaining servers wait for priority health checks
- `REMOTE_BOOT_ENABLE_REMAINING_HEALTH_CHECK`: whether non-priority servers run boot-time health checks
- `REMOTE_BOOT_ENABLE_CONTAINER_RESTART`: whether stopped containers are started and post-checked after boot
- `REMOTE_BOOT_TEST_*`: temporary health-check container settings
- `REMOTE_BOOT_FARM_REQUIRED_MOUNT`, `REMOTE_BOOT_LAB_REQUIRED_MOUNT`, `REMOTE_BOOT_HOST_SHARE_MOUNT_TEMPLATE`: boot-time mount requirements
- `REMOTE_BOOT_MAC_<TARGET>`: WOL MAC addresses
- `REMOTE_BOOT_SLACK_*`: Slack alert routing
- `REMOTE_BOOT_ALERT_STATE_DIR`: alert suppression state directory

## Slack Test

Set Slack webhook values in `config/remote_boot.local.env`, then run:

```bash
./script/test_slack_notification.sh
./script/test_slack_notification.sh --server-id FARM1
./script/test_slack_notification.sh --server-id LAB1
```

## Notes

- `wakeonlan` must be installed on the management desktop.
- Remote scripts use Ansible; set `REMOTE_BOOT_ANSIBLE_INVENTORY` or rely on the default Ansible inventory.
- `LAB*` targets use `192.168.1.255`, and `FARM*` targets use `192.168.2.255` by default.
- Boot health checks create and delete a temporary GPU test container without writing to the DB.
- Post-boot container handling starts only stopped containers. GPU checks run only for images matching `REMOTE_BOOT_CONTAINER_TARGET_IMAGE_REGEX`.
- Automatic remote recovery commands use `sudo -n`; passwordless sudo is required on target hosts for those recovery actions.
- If the network is not ready at boot, increase `REMOTE_BOOT_PRE_DELAY_SECONDS`.
- Local binaries under `bin/` are ignored build artifacts. Do not commit exporter binaries here.
