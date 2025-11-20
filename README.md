# alm-config

Public system files consumed by pi-gen and Puppet. Everything in this repo can
be fetched anonymously, so edge devices never need GitHub credentials.

For the full operational handbook see `../docs/ALM_OPERATIONS.md`.

## Contents

| File | Deployed To | Notes |
| --- | --- | --- |
| `alm` | `/opt/alm/bin/alm` | CLI (`status`, `logs`, `restart`, `reset`) |
| `bashrc` | `/home/almuser/.bashrc`, `/home/almadmin/.bashrc`, `/root/.bashrc` | Adds `/opt/alm/bin` to PATH and prints zero-touch status banners |
| `configure_puppet_agent.sh` | `/opt/configure_puppet_agent.sh` | Public zero-touch bootstrapper (installs Puppet 8, sets hostname, starts agent) |
| `configure_puppet_agent.service` | `/etc/systemd/system/` | Runs the script on first boot |
| `strealer-container.service` | `/etc/systemd/system/` | Starts `docker compose up` for init → main → telemetry |
| `docker-compose.yml` | `/opt/alm/docker-compose.yml` | Production compose file (GCP images, telemetry service, zero host bind mounts) |
| `puppet.conf` | `/etc/puppetlabs/puppet/puppet.conf` (during first-run provisioning) |

## Zero-touch bootstrap script

This is the command referenced across the documentation:

```bash
curl -fsSL https://raw.githubusercontent.com/strealer/alm-config/main/system-files/configure_puppet_agent.sh \
  | sudo bash -x
```

Behavior:

1. Validates disk space (>20 GB total, >6 GB cache).
2. Installs Puppet 8 if missing.
3. Generates the hostname (patterns: `rpi*-*`, `amd-*-*-*`, `dev-*`).
4. Installs `configure_puppet_agent.service` and starts the agent.
5. Leaves `/opt/configure_puppet_agent.sh` on disk so Puppet can re-run it if
   needed.

## CLI summary

```bash
alm status                 # Device + container status
alm logs init              # Follow init container logs
alm logs main              # Follow main container logs
alm logs telemetry         # Follow telemetry sidecar logs
alm restart                # Restart strealer-container.service (requires sudo)
alm reset                  # Factory reset, deletes config/volumes, restarts init
```

The CLI never exposes configuration secrets—`almuser` can only observe the
stack and request restarts/resets.

> Artifact Registry authentication is handled inside the Puppet manifests. They
> template `/opt/alm/config/gcp-registry-token` and execute `docker login`
> before pulling images, so there is no separate helper script in this repo.

## Docker compose (production copy)

- Uses Docker named volumes (`alm_config`, `alm_persist`) instead of host bind
  mounts so Puppet only needs to create `/opt/alm`.
- `alm_init_*` run with `network_mode: host` purely to read hardware data and
  talk to the management API. No HTTP ports are exposed.
- `alm_*` containers expose `80:80` for content delivery.
- `alm_telemetry` keeps `cron_5m.sh` running in a separate container.
- Environment variables `ALM_INIT_*_TAG`, `ALM_APP_*_TAG`, `ALM_TELEMETRY_TAG`
  allow pinning alternate tags without editing the file.

## Updating files

1. Modify the file under `system-files/`.
2. Test locally (pi-gen stage scripts and the Puppet manifests download directly
   from `main`).
3. Update `docs/ALM_OPERATIONS.md` if the behavior of the stack changes.
