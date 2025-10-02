# alm-config

**Public configuration files for Strealer ALM edge computing system**

This repository contains **non-sensitive system configuration files** used by both the **Raspberry Pi image build process** (pi-gen) and **Puppet configuration management** for edge device provisioning.

## Purpose

This public repository eliminates the need for GitHub Personal Access Tokens (PATs) when downloading configuration files to edge devices. Previously, these files were stored in private repositories requiring authentication, creating security vulnerabilities across 1000+ distributed edge nodes.

## Repository Structure

```
alm-config/
└── system-files/
    ├── bashrc                              # Shell environment for almuser and root
    ├── configure_puppet_agent.service      # Systemd service for first-boot Puppet registration
    └── strealer-container.service          # Systemd service for multi-container ALM lifecycle
```

## Files Overview

### `system-files/bashrc`

Standardized Bash shell environment with:
- **Enhanced history management** - Timestamped, cross-session synchronization
- **Safer core utilities** - Interactive prompts for destructive operations
- **Raspberry Pi telemetry** - Temperature, throttling, power monitoring aliases
- **Development conveniences** - Smart archive extractor, git-aware prompt
- **ALM-specific paths** - `/opt/alm/bin` in PATH

**Deployed to**:
- `/home/almuser/.bashrc`
- `/root/.bashrc`

**No sensitive data** - Safe for public distribution

---

### `system-files/configure_puppet_agent.service`

Systemd service that runs Puppet bootstrap script on first device boot.

**Key behaviors**:
- Executes `/opt/configure_puppet_agent.sh` (downloaded separately from private repo)
- Generates hardware-based hostname (`rpi4-12345678-timestamp`)
- Connects to `puppet.strealer.io` for automatic configuration
- Runs continuously with 30-second restart intervals until successful
- Auto-disables after successful Puppet registration

**Network dependency**: Requires `network-online.target`

---

### `system-files/strealer-container.service`

Systemd service managing containerized ALM application lifecycle.

**Key features**:
- **Architecture detection** - Automatically selects ARM64 or AMD64 container variant
- **Auto-update mechanism** - Pulls latest images before starting (`docker compose pull`)
- **Multi-container orchestration** - Manages init → main container dependency flow
- **Graceful lifecycle** - Proper start/stop/restart handling

**Container selection logic**:
```bash
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    docker compose up -d --remove-orphans alm_arm64
else
    docker compose up -d --remove-orphans alm_amd64
fi
```

**Working directory**: `/opt/alm` (contains `docker-compose.yml`)

---

## Usage in Pi-Gen (Raspberry Pi Image Build)

Files are downloaded during **stage3** of the custom Raspberry Pi OS image build:

```bash
ALM_CONFIG_REPO_URL="https://raw.githubusercontent.com/strealer/alm-config/main/system-files"

# Download systemd services
curl -fsSL -o /etc/systemd/system/configure_puppet_agent.service \
    "${ALM_CONFIG_REPO_URL}/configure_puppet_agent.service"

curl -fsSL -o /etc/systemd/system/strealer-container.service \
    "${ALM_CONFIG_REPO_URL}/strealer-container.service"

# Download shell environments
curl -fsSL -o /home/almuser/.bashrc "${ALM_CONFIG_REPO_URL}/bashrc"
curl -fsSL -o /root/.bashrc "${ALM_CONFIG_REPO_URL}/bashrc"
```

**File**: `pi-gen/stage3/00-install-custom-packages/01-run-chroot.sh`

---

## Usage in Puppet (Configuration Management)

Puppet downloads these files every 30 minutes to ensure edge devices stay synchronized:

```puppet
class profiles::raspberry_pi (
  $config_repo_url = 'https://raw.githubusercontent.com/strealer/alm-config/main/system-files',
) {

  # Download strealer-container.service
  exec { 'download_strealer_service':
    command => "curl -fsSL -o /etc/systemd/system/strealer-container.service ${config_repo_url}/strealer-container.service",
    creates => '/etc/systemd/system/strealer-container.service',
  }

  # Download configure_puppet_agent.service
  exec { 'download_configure_puppet_agent_service':
    command => "curl -fsSL -o /etc/systemd/system/configure_puppet_agent.service ${config_repo_url}/configure_puppet_agent.service",
    creates => '/etc/systemd/system/configure_puppet_agent.service',
  }

  # Download bashrc files
  exec { 'download_almuser_bashrc':
    command => "curl -fsSL -o /home/almuser/.bashrc ${config_repo_url}/bashrc",
    creates => '/home/almuser/.bashrc',
  }
}
```

**File**: `alm-infra/puppet/environments/production/modules/profiles/manifests/raspberry_pi.pp`

---

## Security Model

### What's Public (This Repo)
✅ **Safe for public distribution**:
- Shell configuration (bashrc)
- Systemd service definitions
- No credentials, API keys, or secrets
- No business logic or proprietary code

### What's Private (alm-infra Repo)
🔒 **Requires authentication**:
- `/opt/configure_puppet_agent.sh` - Contains Puppet server URLs and registration logic
- Puppet manifests and modules
- Terraform infrastructure definitions
- Client setup scripts with business logic

### What's in Containers (alm Repo)
🐳 **Containerized application**:
- Java application code (edge cache manager)
- Configuration auto-generated by init containers
- No credentials stored in containers (fetched at runtime from central API)

---

## Deployment Flow

### 1️⃣ **Raspberry Pi Image Build** (One-Time)
```
pi-gen build → Embed files from alm-config → Flash to SD card → Boot device
```

### 2️⃣ **First Boot Registration** (Automated)
```
Device boots → configure_puppet_agent.service runs →
Downloads /opt/configure_puppet_agent.sh (private) →
Registers with puppet.strealer.io → Auto-disables service
```

### 3️⃣ **Container Deployment** (Automated)
```
Puppet agent runs (30-min intervals) →
Downloads latest strealer-container.service →
Starts Docker containers →
Web registration available at http://hostname.local:8080
```

### 4️⃣ **Ongoing Updates** (Automated)
```
Puppet ensures configuration files stay current →
Docker Compose pulls latest images →
Containers auto-restart with new versions →
Zero-touch fleet management
```

---

## Architecture Benefits

### Before (Private Repo + PATs)
❌ GitHub PAT hardcoded in Puppet manifests
❌ PAT exposed on 1000+ edge devices
❌ Security vulnerability if device compromised
❌ PAT rotation requires updating all devices

### After (Public Repo)
✅ No authentication required for config files
✅ Zero credentials stored on edge devices
✅ Configuration updates without secret rotation
✅ Public transparency for non-sensitive files

---

## Development Workflow

### Adding New Configuration File

1. **Create file** in `system-files/`
2. **Test locally** by downloading from GitHub raw URL
3. **Update Puppet manifest** (`raspberry_pi.pp`) to download file
4. **Update pi-gen script** (`01-run-chroot.sh`) if needed for image build
5. **Commit and push** to make publicly available
6. **Verify download** works without authentication

### Modifying Existing File

1. **Edit file** in `system-files/`
2. **Test changes** locally
3. **Commit and push**
4. **Puppet auto-applies** within 30 minutes on all devices
5. **Verify via logs**: `journalctl -u puppet -f`

### Testing Downloads

```bash
# Test public download (should work without authentication)
curl -fsSL https://raw.githubusercontent.com/strealer/alm-config/main/system-files/bashrc

# Verify file permissions after download
curl -fsSL -o /tmp/test-bashrc https://raw.githubusercontent.com/strealer/alm-config/main/system-files/bashrc
chmod 644 /tmp/test-bashrc
cat /tmp/test-bashrc
```

---

## Related Repositories

- **[alm](https://github.com/strealer/alm)** - Containerized edge cache manager (Java application)
- **[alm-infra](https://github.com/strealer/alm-infra)** (Private) - Puppet/Terraform infrastructure management
- **[pi-gen](https://github.com/RPi-Distro/pi-gen)** (Fork) - Custom Raspberry Pi OS image builder

---

## Validation

### Systemd Service Validation
```bash
# Validate service file syntax
systemd-analyze verify system-files/strealer-container.service
systemd-analyze verify system-files/configure_puppet_agent.service
```

### Bash Script Validation
```bash
# Shellcheck validation (via Docker)
docker run --rm -v "$(pwd):/scripts" koalaman/shellcheck:stable /scripts/system-files/bashrc
```

---

## Support

For issues related to:
- **Configuration files**: Open issue in this repository
- **Puppet deployment**: See [alm-infra](https://github.com/strealer/alm-infra)
- **Container application**: See [alm](https://github.com/strealer/alm)
- **Pi image building**: See [pi-gen fork](https://github.com/strealer/pi-gen)

---

## License

Configuration files in this repository are provided as-is for Strealer ALM edge computing system deployment.
