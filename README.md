# alm-config

**Public configuration files for Strealer ALM edge computing system**

This repository contains **non-sensitive system configuration files** used by both the **Raspberry Pi image build process** (pi-gen) and **Puppet configuration management** for edge device provisioning.

## Purpose

This public repository eliminates the need for GitHub Personal Access Tokens (PATs) when downloading configuration files to edge devices. Previously, these files were stored in private repositories requiring authentication, creating security vulnerabilities across 1000+ distributed edge nodes.

## Repository Structure

```
alm-config/
└── system-files/
    ├── alm                                 # CLI tool for device management (register, status, logs, restart)
    ├── bashrc                              # Shell environment for almuser and root
    ├── configure_puppet_agent.service      # Systemd service for first-boot Puppet registration
    └── strealer-container.service          # Systemd service for multi-container ALM lifecycle
```

## Files Overview

### `system-files/alm`

**Standalone CLI tool for device management** - Comprehensive command-line interface for ALM operations.

**Deployed to**: `/opt/alm/bin/alm`

**Commands**:
- `alm register` - Interactive device registration with init container
  - Auto-detects registration state
  - Waits for init container API (retry logic)
  - Displays QR code and registration URL
  - Monitors main container startup
  - Supports `--auto` mode for non-interactive use
- `alm status` - Show device and container status
  - Device IP, hostname, architecture
  - Docker service status
  - Container states (init and main)
  - Service accessibility
- `alm logs [init|main]` - Follow container logs in real-time
  - Default: main container
  - Supports `--no-follow`, `--tail N` options
- `alm restart` - Restart ALM systemd service
  - Stops containers gracefully
  - Pulls latest images
  - Starts containers
  - Shows updated status

**Usage Examples**:
```bash
# Interactive registration
alm register

# Check device status
alm status

# View logs
alm logs init          # Init container logs
alm logs main          # Main container logs

# Restart service
alm restart

# Get help
alm help
alm register --help
```

**Design Philosophy**:
- **Standalone script** - Not embedded in bashrc for clean separation
- **User-focused** - Designed for manual execution by SSH users
- **Comprehensive help** - Each command has detailed `--help` output
- **Error handling** - Clear error messages with troubleshooting steps
- **Multi-architecture** - Auto-detects ARM64/AMD64 containers
- **Colored output** - Visual feedback with emoji and ANSI colors

**No sensitive data** - Safe for public distribution

---

### `system-files/bashrc`

Standardized Bash shell environment with **ALM CLI integration**:

**ALM Integration:**
- **Adds `/opt/alm/bin` to PATH** - Makes `alm` command available
- **Auto-detects registration needs** - Checks on SSH login if device needs registration
- **Suggests registration** - Shows banner and recommends `alm register` command
- **Clean separation** - All device management logic lives in `/opt/alm/bin/alm`, not bashrc

**Standard Shell Enhancements:**
- **Enhanced history management** - Timestamped, cross-session synchronization
- **Safer core utilities** - Interactive prompts for destructive operations (cp, mv, rm)
- **Raspberry Pi telemetry** - Temperature, throttling, power monitoring aliases
- **Development conveniences** - Smart archive extractor, git-aware prompt
- **Navigation helpers** - `..`, `...`, `up`, `mkcd` shortcuts

**Deployed to**:
- `/home/almuser/.bashrc`
- `/root/.bashrc`

**Login Experience:**
```bash
# User SSHs into device
ssh almuser@device-ip

# If device needs registration, bashrc shows:
╔════════════════════════════════════════════════════════════════════╗
║  🚀 ALM Device Registration Required                               ║
╚════════════════════════════════════════════════════════════════════╝

Run: alm register

# User runs registration command
almuser@device:~$ alm register
# [Interactive registration starts...]
```

**Benefits of Standalone CLI:**
- **Cleaner bashrc** - Shell config separated from device management
- **Better UX** - Comprehensive help system with `--help` flags
- **Maintainability** - Single script easier to update and test
- **Reusability** - Can be called from scripts, cron jobs, or manually

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

# Download ALM CLI tool
mkdir -p /opt/alm/bin
curl -fsSL -o /opt/alm/bin/alm "${ALM_CONFIG_REPO_URL}/alm"
chmod 755 /opt/alm/bin/alm

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

  # Ensure /opt/alm/bin directory exists
  file { '/opt/alm/bin':
    ensure => directory,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
  }

  # Download ALM CLI tool
  exec { 'download_alm_cli':
    command => "curl -fsSL -o /opt/alm/bin/alm ${config_repo_url}/alm",
    creates => '/opt/alm/bin/alm',
  }

  file { '/opt/alm/bin/alm':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0755',
    require => Exec['download_alm_cli'],
  }

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

### 2️⃣ **First Boot Puppet Registration** (Automated)
```
Device boots → configure_puppet_agent.service runs →
Downloads /opt/configure_puppet_agent.sh (private) →
Registers with puppet.strealer.io → Auto-disables service
```

### 3️⃣ **Container Deployment** (Automated)
```
Puppet agent runs (30-min intervals) →
Downloads latest strealer-container.service →
Starts Docker containers (init + main) →
Init container ready on port 8080
```

### 4️⃣ **Interactive Device Registration** (User Action Required)
```
User SSHs into device → bashrc shows registration banner →
User runs: alm register →
Opens displayed QR code/URL in browser →
Completes device registration form →
Presses Enter in SSH session →
Main container starts automatically →
Service ready on port 80
```

**What happens automatically:**
1. Init container starts and exposes web registration on port 8080
2. Bashrc detects init container running (shows banner: "Run: alm register")
3. User runs `alm register` command
4. CLI waits for registration API to be ready (auto-retry 3x)
5. Displays QR code + registration URL
6. Waits for user input (interactive prompt)
7. Monitors main container startup after registration
8. Shows success message with service URL

**User only needs to:**
- SSH into device
- Run: `alm register` (suggested by bashrc banner)
- Open displayed URL in browser
- Fill registration form
- Press Enter in SSH session
- Done! Main service running at http://device-ip:80

### 5️⃣ **Ongoing Updates** (Automated)
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
