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
- finally, if `REMOTE_BOOT_ENABLE_CONTAINER_RESTART=true`, all selected servers run a full docker container restart

Standalone test container commands:

```bash
./script/create_test_container.sh --server-id FARM1
./script/delete_test_container.sh --server-id FARM1
```

Recommended manual integration test:

```bash
./script/integration_smoke_test.sh --scope priority
```

## Git

- `config/remote_boot.local.env` is ignored by `.gitignore`
- commit `config/remote_boot.example.env` and keep real server-specific values, including MAC addresses, only in `config/remote_boot.local.env`

## Notes

- `wakeonlan` must be installed on this desktop.
- `wake_targets.sh` reads MAC addresses from `REMOTE_BOOT_MAC_<TARGET>` variables in `config/remote_boot.local.env`.
- `LAB*` targets use `192.168.1.255`, and `FARM*` targets use `192.168.2.255` by default.
- remote scripts can use `REMOTE_BOOT_ANSIBLE_INVENTORY`, or fall back to your existing `ansible.cfg` default inventory.
- host mount checks expect `100.100.100.100:/294t/dcloud/share` for LAB and `100.100.100.120:/volume1/share` for FARM.
- boot health checks create a temporary GPU test container directly via Docker and remove it without writing to the DB.
- container restart uses `docker ps -aq`; if a server has no containers, it logs and continues.
- If the network is not ready at boot, increase `REMOTE_BOOT_PRE_DELAY_SECONDS`.
