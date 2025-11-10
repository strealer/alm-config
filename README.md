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
    ├── configure_puppet_agent.sh           # Puppet bootstrap script (hardware detection, hostname generation)
    ├── puppet.conf                         # Puppet agent configuration template
    └── strealer-container.service          # Systemd service for multi-container ALM lifecycle
```

## Files Overview

### `system-files/alm`

**Standalone CLI tool for device management** - Comprehensive command-line interface for ALM operations.

**Deployed to**: `/opt/alm/bin/alm`

**Commands**:

#### `alm register`
Interactive device registration with init container web interface.

**Features**:
- Auto-detects registration state
- Waits for init container API (3 retries, 2s intervals)
- Displays QR code and registration URL
- User confirmation (y/n) before proceeding
- Extended monitoring (120s timeout)
- Progress indicators and helpful reminders
- Detects init container exit and main container startup
- Supports `--auto` mode for non-interactive use

**Flow**:
```
1. Shows QR code + registration URL
2. User completes registration in browser
3. User confirms with 'y'
4. Waits for init to exit and main to start
5. Shows success with service URL
```

#### `alm status`
Show device and container status overview.

**Displays**:
- Device IP, hostname, architecture
- Docker service status
- Init container status
- Main container status
- Service URLs (port 8080 for init, port 80 for main)

#### `alm logs [init|main]`
Follow container logs in real-time.

**Options**:
- `init` - Init container logs
- `main` - Main container logs (default)
- `--no-follow` - Show logs without following
- `--tail N` - Show last N lines (default: 50)

#### `alm restart`
Restart ALM systemd service.

**Actions**:
- Stops all containers
- Pulls latest images
- Starts containers based on architecture
- Shows updated status

#### `alm reset`
Reset device to allow fresh registration.

**WARNING**: Destructive operation!

**Actions**:
- Stops all containers
- Removes containers and volumes
- Deletes all configuration and registration data
- Starts fresh init container
- Waits for init container to be ready

**Use when**:
- Registration is stuck or incomplete
- Need to re-register device
- Want to start from scratch

#### `alm start-main`
**Workaround** for init container not exiting after registration.

**Actions**:
- Stops init container
- Force starts main container (bypasses dependency)
- Shows service status

**Use when**:
- Registration complete but init won't exit
- Main container won't start automatically
- Stuck after answering 'y' in registration

**Usage Examples**:
```bash
# Complete registration flow
alm register              # Shows QR, waits for user

# If stuck after registration
alm start-main           # Force start main container

# Check status anytime
alm status

# View logs
alm logs init            # Init container logs
alm logs main            # Main container logs

# Reset everything
alm reset                # Clean slate

# Restart service
alm restart              # Pull latest images and restart

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
- **Robust IP detection** - Uses `grep -oP 'src \K[0-9.]+'` for reliability

**Known Issue**:
Init container may not exit automatically after successful registration due to a bug in the alm-init container. Use `alm start-main` as workaround.

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

### `system-files/configure_puppet_agent.sh`

Puppet bootstrap script that configures edge devices for automatic infrastructure management.

**Deployed to**: `/opt/configure_puppet_agent.sh`

**What it does**:
1. **Installs Puppet 8** - Downloads and installs from official Puppet repositories (if not present)
2. **Generates unique hostname** - Hardware-based detection (CPU serial, system UUID, vendor info)
3. **Configures Puppet agent** - Downloads `puppet.conf` template and customizes with hostname
4. **Enables Puppet service** - Connects to `puppet.strealer.io` for continuous configuration management

**Hostname patterns generated**:
- **Raspberry Pi**: `rpi4-12345678-20240115143022`, `rpi5-abcdef12-20240115143022`
- **AMD64 Servers**: `amd-dell-optiplex-9a8b7c6d-20240115143022`, `amd-hp-elitedesk-1f2e3d4c-20240115143022`
- **Development/Generic**: `dev-4f5e6d7c-20240115143022`

**Safety checks**:
- Disk space validation (requires >20GB total)
- Prevents re-running via flag file (`/var/lib/puppet-config-done`)
- Certificate cleanup on SSL errors
- Root-only execution

**Usage**:
```bash
# Download and execute
curl -fsSL https://raw.githubusercontent.com/strealer/alm-config/main/system-files/configure_puppet_agent.sh | bash

# Or save first
curl -fsSL -o configure_puppet_agent.sh \
  https://raw.githubusercontent.com/strealer/alm-config/main/system-files/configure_puppet_agent.sh
bash configure_puppet_agent.sh
```

**No sensitive data** - Safe for public distribution (removed hardcoded GitHub PAT in favor of public downloads)

---

### `system-files/puppet.conf`

Puppet agent configuration template used by `configure_puppet_agent.sh`.

**Deployed to**: `/etc/puppetlabs/puppet/puppet.conf`

**Configuration**:
- **Puppet Master**: `puppet.strealer.io`
- **Certname**: Dynamically set via `%%HOSTNAME%%` placeholder
- **Run Interval**: 120 seconds (2 minutes) - frequent updates for edge devices
- **Environment**: Production
- **Wait for cert**: 60 seconds

**Template processing**:
```bash
# Script replaces %%HOSTNAME%% with generated hostname
sed "s/%%HOSTNAME%%/$HOSTNAME/g" puppet.conf.template > /etc/puppetlabs/puppet/puppet.conf
```

**No sensitive data** - Contains only Puppet server hostname and timing configuration

---

### `system-files/configure_puppet_agent.service`

Systemd service that runs Puppet bootstrap script on first device boot.

**Key behaviors**:
- Executes `/opt/configure_puppet_agent.sh` (downloaded from public alm-config repo)
- Generates hardware-based hostname (`rpi4-12345678-timestamp`)
- Connects to `puppet.strealer.io` for automatic configuration
- Runs continuously with 30-second restart intervals until successful
- Auto-disables after successful Puppet registration (via flag file)

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

### Docker Registry Authentication (GCP Artifact Registry)
🔐 **Puppet-Managed Token Distribution** (November 2025):
- Docker images stored in GCP Artifact Registry (`europe-west1-docker.pkg.dev`)
- OAuth2 tokens generated hourly on Puppet server
- Tokens distributed automatically to all devices via Puppet
- **No tokens stored in this public repository**
- **Device-side files**:
  - `/opt/alm/config/gcp-registry-token` - Token file (Puppet-distributed)
  - `/usr/local/bin/docker-login-gcp` - Docker login helper script
- **Service integration**: `strealer-container.service` calls docker login before pulling images
- **Documentation**: See `alm-infra/puppet-infra-config/server-setup/GCP_ARTIFACT_REGISTRY_ACCESS_PROPOSAL.md` for complete architecture
- **Deployment**: Automated via Ansible playbook in `alm-infra/puppet-infra-config/server-setup/setup_puppet_server.yml`
- **Benefits**: Hourly rotation, instant revocation, zero manual credential management

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
User SSHs into device → bashrc auto-starts: alm register →
Shows QR code/URL →
User opens URL in browser →
Completes device registration form →
Returns to terminal, confirms with 'y' →
[If stuck: Ctrl+C, run: alm start-main] →
Main container starts →
Service ready on port 80
```

**What happens automatically:**
1. Init container starts and exposes web registration on port 8080
2. Bashrc detects init container running (auto-runs `alm register`)
3. CLI waits for registration API to be ready (auto-retry 3x, 2s intervals)
4. Displays QR code + registration URL
5. Waits for user to confirm registration complete (y/n prompt)
6. Monitors init container exit and main container startup (120s timeout)
7. Shows helpful reminder at 30s if still waiting
8. Shows success message with service URL when main starts

**User workflow:**
1. **SSH into device** - Bashrc automatically starts registration
2. **Open URL in browser** - Use displayed QR code or URL
3. **Fill registration form** - Complete all required fields
4. **Submit form** - Wait for "Successfully registered" message
5. **Return to terminal** - Answer 'y' to confirmation prompt
6. **Wait for startup** - CLI monitors container startup automatically
7. **Done!** - Service URL displayed when ready

**If registration gets stuck:**
```bash
# Press Ctrl+C to cancel waiting
# Then force start main container
alm start-main

# Or reset and try again
alm reset
```

**Troubleshooting:**
```bash
# Check current status
alm status

# View init container logs
alm logs init

# View main container logs
alm logs main

# Reset everything and start fresh
alm reset
```

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

## Troubleshooting

### Common Issues and Solutions

#### **Issue: Registration stuck, main container won't start**

**Symptoms:**
- Completed registration in browser
- Terminal stuck at "Waiting for main container to start..."
- Init container still running after 60+ seconds

**Root Cause:**
Init container bug - doesn't exit after successful registration, blocking main container due to `depends_on: service_completed_successfully` constraint.

**Solution:**
```bash
# Press Ctrl+C to cancel waiting
# Then force start main container
alm start-main
```

**Or reset and try again:**
```bash
alm reset
alm register
# Complete registration
# If stuck again: alm start-main
```

---

#### **Issue: "bash: local: can only be used in a function"**

**Symptoms:**
Error on SSH login before fixes were applied.

**Solution:**
Already fixed in current version. Variables use regular declarations with `_alm_` prefix and `unset` cleanup.

**If you still see this:**
```bash
# On device, update bashrc
sudo curl -fsSL -o /home/almuser/.bashrc \
  https://raw.githubusercontent.com/strealer/alm-config/main/system-files/bashrc
sudo curl -fsSL -o /root/.bashrc \
  https://raw.githubusercontent.com/strealer/alm-config/main/system-files/bashrc
```

---

#### **Issue: Container architecture mismatch errors**

**Symptoms:**
```
no matching manifest for linux/arm64/v8 in the manifest list entries
```

**Root Cause:**
Trying to pull both arm64 and amd64 images on single-architecture device.

**Solution:**
Already fixed in current `strealer-container.service`. Architecture-aware pulls:
```bash
# ARM64 devices pull only arm64
# AMD64 devices pull only amd64
```

**If you still see this:**
```bash
# Update service file
sudo curl -fsSL -o /etc/systemd/system/strealer-container.service \
  https://raw.githubusercontent.com/strealer/alm-config/main/system-files/strealer-container.service
sudo systemctl daemon-reload
sudo systemctl restart strealer-container.service
```

---

#### **Issue: alm command not found**

**Symptoms:**
```bash
almuser@device:~$ alm
-bash: alm: command not found
```

**Solution:**
```bash
# Download and install ALM CLI
sudo mkdir -p /opt/alm/bin
sudo curl -fsSL -o /opt/alm/bin/alm \
  https://raw.githubusercontent.com/strealer/alm-config/main/system-files/alm
sudo chmod 755 /opt/alm/bin/alm

# Verify PATH includes /opt/alm/bin
echo $PATH | grep -q /opt/alm/bin || echo 'export PATH="/opt/alm/bin:$PATH"' >> ~/.bashrc

# Reload bashrc
source ~/.bashrc

# Test
alm help
```

---

#### **Issue: Containers keep restarting or failing**

**Symptoms:**
```bash
alm status
# Shows containers in "Restarting" or "Exited" state
```

**Solution:**
```bash
# Check logs for errors
alm logs init
alm logs main

# Common fixes:

# 1. Missing configuration (if using old setup)
alm reset  # Generates fresh configs

# 2. Port conflicts
sudo netstat -tlnp | grep :80    # Check what's using port 80
sudo netstat -tlnp | grep :8080  # Check what's using port 8080

# 3. Docker issues
sudo systemctl restart docker
alm restart

# 4. Corrupted volumes
alm reset  # Nuclear option - deletes everything
```

---

#### **Issue: Can't access service at http://device-ip:80**

**Symptoms:**
- Main container running (`alm status` shows it)
- Can't access via browser
- Connection refused or timeout

**Solution:**
```bash
# 1. Verify container is actually running
alm status

# 2. Check if nginx is listening inside container
sudo docker exec alm_arm64 curl -s http://localhost:80

# 3. Check firewall
sudo iptables -L -n | grep 80

# 4. Check container logs for errors
alm logs main

# 5. Restart container
sudo docker restart alm_arm64
```

---

#### **Issue: Old docker-compose.yml without init containers**

**Symptoms:**
- Device has old single-container setup
- Missing init container
- Registration not working

**Solution:**
```bash
# Download latest docker-compose.yml from alm repository
cd /opt/alm
sudo curl -fsSL -o docker-compose.yml \
  https://raw.githubusercontent.com/strealer/alm/production/docker-compose.yml
sudo systemctl restart strealer-container.service
```

---

### Quick Reference Commands

```bash
# Registration workflow
alm register          # Start registration
alm start-main        # Force start if stuck
alm reset             # Start completely fresh

# Monitoring
alm status            # Device and container status
alm logs init         # Init container logs
alm logs main         # Main container logs

# Maintenance
alm restart           # Restart service (pulls latest images)
alm reset             # Nuclear option - deletes everything

# Help
alm help              # Show all commands
alm <command> --help  # Specific command help
```

---

## Support

For issues related to:
- **Configuration files**: Open issue in this repository
- **Puppet deployment**: See [alm-infra](https://github.com/strealer/alm-infra)
- **Container application**: See [alm](https://github.com/strealer/alm)
- **Init container bug**: See [alm](https://github.com/strealer/alm) - Known issue with container not exiting
- **Pi image building**: See [pi-gen fork](https://github.com/strealer/pi-gen)

---

## License

Configuration files in this repository are provided as-is for Strealer ALM edge computing system deployment.
