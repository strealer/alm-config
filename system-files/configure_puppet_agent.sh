#!/bin/bash

# ============================================================================
# Strealer ALM Puppet Agent Setup Script
# ============================================================================
# SOURCE: alm-config/system-files/configure_puppet_agent.sh
# DEPLOYED BY: Puppet (downloads from public GitHub raw URL), pi-gen (baked into image)
# ============================================================================
#
# USAGE:
#   # Default (production environment):
#   curl -fsSL https://raw.githubusercontent.com/strealer/alm-config/main/system-files/configure_puppet_agent.sh | bash
#
#   # Staging environment:
#   curl -fsSL https://raw.githubusercontent.com/strealer/alm-config/main/system-files/configure_puppet_agent.sh | ALM_ENVIRONMENT=staging bash
#
#   # Or set environment before running:
#   export ALM_ENVIRONMENT=staging
#   curl -fsSL https://raw.githubusercontent.com/strealer/alm-config/main/system-files/configure_puppet_agent.sh | bash
#
#   # Or create flag file before first boot (for pi-gen images):
#   echo "staging" > /etc/alm-environment
#
# ENVIRONMENT SELECTION:
#   - **staging**: Hostname prefix 'stg-', uses TEST content, fapi-test.strealer.io
#   - **production**: Hostname prefix 'prod-', uses PRODUCTION+PRELIVE, fapi.strealer.io
#   - Default: production (if not specified)
#
# WHAT THIS SCRIPT DOES:
# 1. **Installs Puppet 8** (if not present) - Downloads and installs from official Puppet repos
# 2. **Generates unique hostname** based on hardware detection (CPU architecture, system info)
# 3. **Configures Puppet agent** to connect to puppet.strealer.io management server
# 4. **Enables automatic certificate** signing and approval for zero-touch deployment
# 5. **Starts Puppet service** for continuous configuration management (runs every 30 minutes)
#
# AUTOMATIC DEPLOYMENT AFTER SCRIPT:
# Once this script completes, Puppet automatically deploys:
# - **Docker Engine** - Container runtime with proper user permissions
# - **ALM Application** - Architecture-specific container (ARM64/AMD64)
# - **Nginx Reverse Proxy** - For content caching and load balancing
# - **System Services** - strealer-container.service, monitoring, logging
# - **Cron Jobs** - Automated maintenance and health checks (every 5 minutes)
# - **Self-Healing** - Automatic service recovery and Docker cleanup
#
# SUPPORTED SYSTEMS:
# - Debian: bookworm, bullseye, buster
# - Ubuntu: jammy, focal, bionic
# - Architectures: ARM64 (Raspberry Pi), AMD64 (x86_64)
#
# EXPECTED TIMELINE:
# - Script execution: ~2-3 minutes
# - Puppet first run: ~3-5 minutes  
# - ALM deployment: ~2-3 minutes
# - Total setup time: ~5-10 minutes
#
# MONITORING PROGRESS:
#   watch "/opt/puppetlabs/bin/puppet agent --test --noop | tail -20"
#   (Use Ctrl+C when you see "Applied catalog in X.XX seconds")
#
# POST-SETUP VERIFICATION:
#   systemctl status docker puppet strealer-container
#   docker ps
#   docker logs strealer-alm

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
  echo "Error: This script must be run as root. Please use 'sudo' or run as root user."
  exit 1
fi

# Check disk space requirements early to avoid wasting time on Puppet setup
total_disk_size_kb=$(df / | awk 'NR==2 {print $2}')
available_disk_size_kb=$(df / | awk 'NR==2 {print $4}')
total_disk_size_gb=$(( total_disk_size_kb / 1024 / 1024 ))
available_disk_size_gb=$(( available_disk_size_kb / 1024 / 1024 ))

if [ $total_disk_size_gb -le 20 ]; then
    echo ""
    echo "SETUP FAILED: Insufficient disk space"
    echo "====================================="
    echo ""
    echo "Total disk space: ${total_disk_size_gb}GB"
    echo "Available free space: ${available_disk_size_gb}GB"
    echo "Required: More than 20GB total"
    echo ""
    echo "The ALM system reserves 20GB for system operations"
    echo "and needs additional space for content caching."
    echo ""
    echo "Solutions:"
    echo "- Free up disk space (apt clean, remove old files)"
    echo "- Use a larger storage device"
    echo "- Recommended minimum: 32GB for optimal performance"
    echo ""
    exit 1
fi

# Flag file to indicate script has already run
FLAG_FILE="/var/lib/puppet-config-done"
PUPPET_MASTER="puppet.strealer.io"
PUPPET_CONF_FILE="/etc/puppetlabs/puppet/puppet.conf"

# Early cleanup for puppet certificate/service issues if flagged run
if [ -f "$FLAG_FILE" ]; then
  if systemctl status puppet 2>&1 | grep -E 'certificate.*does not match|key values mismatch|SSL_CTX_use_PrivateKey|Could not parse PKey: unsupported' || ! systemctl is-active --quiet puppet; then
    echo "Detected Puppet certificate or service issues. Cleaning up SSL and removing flag file..."
    rm -rf "$FLAG_FILE" "$PUPPET_CONF_FILE" /etc/puppetlabs/puppet/ssl
  fi
fi

# Check if script has already run
if [ -f "$FLAG_FILE" ]; then
  echo "Puppet configuration has already been completed. Exiting."
  echo "To force re-configuration, delete $FLAG_FILE and run again."
  exit 0
fi

# Variables

# Public alm-config repository URL (no authentication required)
ALM_CONFIG_REPO_URL="https://raw.githubusercontent.com/strealer/alm-config/main/system-files"

### Function Definitions

# ============================================================================
# install_puppet_agent()
# ============================================================================
# 
# WHAT THIS FUNCTION DOES:
# - **Checks existing installation** - Verifies if Puppet 8 is already installed and working
# - **Installs dependencies** - Ensures wget and other required packages are present
# - **Detects OS version** - Identifies Debian/Ubuntu distribution and codename
# - **Downloads Puppet repo** - Gets official Puppet 8 repository package from apt.puppetlabs.com
# - **Installs Puppet agent** - Installs puppet-agent package via APT
# - **Verifies installation** - Confirms Puppet is working and displays version
#
# SUPPORTED DISTRIBUTIONS:
# - Debian: bookworm (12), bullseye (11), buster (10)
# - Ubuntu: jammy (22.04), focal (20.04), bionic (18.04)
#
# WHY PUPPET 8:
# - Latest stable version with improved performance
# - Better ARM64 support for Raspberry Pi devices
# - Enhanced security and certificate management
# - Required for our infrastructure-as-code approach
# ============================================================================
install_puppet_agent() {
  echo "Checking if Puppet agent is installed..."
  
  # Step 1: Install basic system dependencies required for Puppet installation
  echo "Installing basic dependencies..."
  if ! apt-get update; then
    echo "Warning: Failed to update package lists initially. Continuing..."
  fi
  
  if ! dpkg -l | grep -q wget; then
    echo "Installing wget..."
    apt-get install -y wget || { echo "Error: Failed to install wget"; return 1; }
  fi
  
  # Check if puppet is already installed and working
  if command -v puppet >/dev/null 2>&1 && puppet --version >/dev/null 2>&1; then
    echo "Puppet agent is already installed and working. Version: $(puppet --version)"
    return 0
  fi
  
  echo "Puppet agent not found or not working. Installing..."
  
  # Detect distribution and version
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRIB_ID="$ID"
    DISTRIB_CODENAME="$VERSION_CODENAME"
  else
    echo "Error: Cannot detect Linux distribution. /etc/os-release not found."
    return 1
  fi
  
  case "$DISTRIB_ID" in
    "debian")
      case "$DISTRIB_CODENAME" in
        "bookworm"|"bullseye"|"buster")
          PUPPET_RELEASE_DEB="puppet8-release-${DISTRIB_CODENAME}.deb"
          ;;
        *)
          echo "Warning: Unsupported Debian version '$DISTRIB_CODENAME'. Trying with bookworm package..."
          PUPPET_RELEASE_DEB="puppet8-release-bookworm.deb"
          ;;
      esac
      ;;
    "ubuntu")
      case "$DISTRIB_CODENAME" in
        "jammy"|"focal"|"bionic")
          PUPPET_RELEASE_DEB="puppet8-release-${DISTRIB_CODENAME}.deb"
          ;;
        *)
          echo "Warning: Unsupported Ubuntu version '$DISTRIB_CODENAME'. Trying with jammy package..."
          PUPPET_RELEASE_DEB="puppet8-release-jammy.deb"
          ;;
      esac
      ;;
    *)
      echo "Error: Unsupported distribution '$DISTRIB_ID'. This script supports Debian and Ubuntu only."
      return 1
      ;;
  esac
  
  echo "Installing Puppet 8 repository for $DISTRIB_ID $DISTRIB_CODENAME..."
  
  # Download and install Puppet repository package
  if ! wget -q "https://apt.puppetlabs.com/${PUPPET_RELEASE_DEB}" -O "/tmp/${PUPPET_RELEASE_DEB}"; then
    echo "Error: Failed to download Puppet repository package."
    return 1
  fi
  
  if ! dpkg -i "/tmp/${PUPPET_RELEASE_DEB}"; then
    echo "Error: Failed to install Puppet repository package."
    rm -f "/tmp/${PUPPET_RELEASE_DEB}"
    return 1
  fi
  
  # Clean up the downloaded file
  rm -f "/tmp/${PUPPET_RELEASE_DEB}"
  
  echo "Updating package lists..."
  if ! apt-get update; then
    echo "Error: Failed to update package lists."
    return 1
  fi
  
  echo "Installing Puppet agent..."
  if ! apt-get install -y puppet-agent; then
    echo "Error: Failed to install Puppet agent."
    return 1
  fi
  
  # Add Puppet binaries to PATH if not already there
  if ! echo "$PATH" | grep -q "/opt/puppetlabs/bin"; then
    echo 'export PATH="/opt/puppetlabs/bin:$PATH"' >> /etc/profile.d/puppet.sh
    chmod +x /etc/profile.d/puppet.sh
    export PATH="/opt/puppetlabs/bin:$PATH"
  fi
  
  echo "Puppet agent installation completed successfully."
  echo "Installed version: $(puppet --version)"
  return 0
}

# ============================================================================
# detect_alm_environment()
# ============================================================================
#
# WHAT THIS FUNCTION DOES:
# - **Checks environment variable** - ALM_ENVIRONMENT (staging or production)
# - **Checks flag file** - /etc/alm-environment (for pi-gen baked images)
# - **Defaults to production** - If not specified, assumes production for safety
#
# ENVIRONMENT VALUES:
# - staging: Device will use TEST content, fapi-test.strealer.io
# - production: Device will use PRODUCTION+PRELIVE, fapi.strealer.io
# ============================================================================
detect_alm_environment() {
  local env_value

  # Priority 1: Environment variable
  if [ -n "$ALM_ENVIRONMENT" ]; then
    env_value="$ALM_ENVIRONMENT"
  # Priority 2: Flag file (for pi-gen images)
  elif [ -f /etc/alm-environment ]; then
    env_value=$(cat /etc/alm-environment | tr -d '[:space:]')
  # Default: production
  else
    env_value="production"
  fi

  # Normalize to lowercase and validate
  env_value=$(echo "$env_value" | tr '[:upper:]' '[:lower:]')
  case "$env_value" in
    staging|stg) echo "staging" ;;
    *) echo "production" ;;
  esac
}

# ============================================================================
# generate_hostname()
# ============================================================================
#
# WHAT THIS FUNCTION DOES:
# - **Environment Prefix** - Adds 'stg-' or 'prod-' based on ALM_ENVIRONMENT
# - **Hardware Detection** - Identifies device type (Raspberry Pi, AMD64 server, or generic)
# - **Unique ID Generation** - Creates stable hostname based on hardware serial/UUID
# - **Model Classification** - Detects specific RPi models (Pi 4, Pi 5, Zero W, etc.)
# - **Vendor Recognition** - Identifies AMD64 system manufacturers (Dell, HP, Lenovo, etc.)
#
# HOSTNAME PATTERNS GENERATED:
# **Staging Raspberry Pi Devices:**
# - stg-rpi4-12345678 (Pi 4 Model B, staging)
# - stg-rpi5-abcdef12 (Pi 5 Model B, staging)
#
# **Production Raspberry Pi Devices:**
# - prod-rpi4-12345678 (Pi 4 Model B, production)
# - prod-rpi5-abcdef12 (Pi 5 Model B, production)
#
# **Staging AMD64 Servers:**
# - stg-amd-dell-optiplex-9a8b7c6d (Dell OptiPlex, staging)
#
# **Production AMD64 Servers:**
# - prod-amd-dell-optiplex-9a8b7c6d (Dell OptiPlex, production)
#
# **Development/Generic Systems:**
# - stg-dev-4f5e6d7c or prod-dev-4f5e6d7c
#
# WHY HARDWARE-BASED HOSTNAMES:
# - **Puppet Identification** - Each device gets unique certificate/configuration
# - **Environment Classification** - Puppet uses hostname prefix to determine environment
# - **Infrastructure Tracking** - Easy identification in monitoring and logs
# - **Deployment Consistency** - Same device always gets same base hostname
# ============================================================================
generate_hostname() {
  local rpi_serial amd_uuid host_id device_vendor device_model rpi_model final_hostname persistent_uuid uuid_path env_prefix

  # Get environment prefix
  local alm_env
  alm_env=$(detect_alm_environment)
  case "$alm_env" in
    staging) env_prefix="stg" ;;
    *) env_prefix="prod" ;;
  esac

  if grep -q "^Serial" /proc/cpuinfo; then
    rpi_serial=$(awk '/^Serial/{print $3}' /proc/cpuinfo)
    rpi_model=$(tr -d '\0' </proc/device-tree/model 2>/dev/null)
    case "$rpi_model" in
      *"Raspberry Pi 5 Model B"*)          host_id="${env_prefix}-rpi5-${rpi_serial: -8}" ;;
      *"Raspberry Pi 4 Model B"*)          host_id="${env_prefix}-rpi4-${rpi_serial: -8}" ;;
      *"Raspberry Pi 3 Model B Plus"*)     host_id="${env_prefix}-rpi3bp-${rpi_serial: -8}" ;;
      *"Raspberry Pi 3 Model B"*)          host_id="${env_prefix}-rpi3b-${rpi_serial: -8}" ;;
      *"Raspberry Pi 3 Model A Plus"*)     host_id="${env_prefix}-rpi3ap-${rpi_serial: -8}" ;;
      *"Raspberry Pi 2 Model B"*)          host_id="${env_prefix}-rpi2b-${rpi_serial: -8}" ;;
      *"Raspberry Pi Model B Plus"*)       host_id="${env_prefix}-rpi1bp-${rpi_serial: -8}" ;;
      *"Raspberry Pi Model A Plus"*)       host_id="${env_prefix}-rpi1ap-${rpi_serial: -8}" ;;
      *"Raspberry Pi Model B Rev"*|"Raspberry Pi Model B"*) host_id="${env_prefix}-rpi1b-${rpi_serial: -8}" ;;
      *"Raspberry Pi Model A"*)            host_id="${env_prefix}-rpi1a-${rpi_serial: -8}" ;;
      *"Raspberry Pi Zero 2 W"*)           host_id="${env_prefix}-rpiz2w-${rpi_serial: -8}" ;;
      *"Raspberry Pi Zero W"*)             host_id="${env_prefix}-rpizw-${rpi_serial: -8}" ;;
      *"Raspberry Pi Zero"*)               host_id="${env_prefix}-rpiz-${rpi_serial: -8}" ;;
      *"Compute Module 4"*)                host_id="${env_prefix}-rpicm4-${rpi_serial: -8}" ;;
      *"Compute Module 3 Plus"*)           host_id="${env_prefix}-rpicm3p-${rpi_serial: -8}" ;;
      *"Compute Module 3"*)                host_id="${env_prefix}-rpicm3-${rpi_serial: -8}" ;;
      *"Compute Module"*)                  host_id="${env_prefix}-rpicm1-${rpi_serial: -8}" ;;
      *)                                   host_id="${env_prefix}-rpi-${rpi_serial: -8}" ;;
    esac

  elif [ -f /sys/class/dmi/id/product_uuid ]; then
    amd_uuid=$(cat /sys/class/dmi/id/product_uuid | tr -d '-')
    device_vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null | tr '[:upper:]' '[:lower:]')
    device_model=$(cat /sys/class/dmi/id/product_name 2>/dev/null | tr '[:upper:]' '[:lower:]')

    case "$device_vendor" in
      *dell*) device_vendor="dell" ;;
      *lenovo*) device_vendor="lenovo" ;;
      *asus*) device_vendor="asus" ;;
      *acer*) device_vendor="acer" ;;
      *hp*|*hewlett*) device_vendor="hp" ;;
      *microsoft*) device_vendor="microsoft" ;;
      *vmware*) device_vendor="vmware" ;;
      *qemu*) device_vendor="qemu" ;;
      *virtualbox*) device_vendor="vbox" ;;
      *) device_vendor=$(echo "$device_vendor" | tr -cd '[:alnum:]') ;;
    esac

    device_model=$(echo "$device_model" | tr -cd '[:alnum:]')
    host_id="${env_prefix}-amd-${device_vendor}-${device_model}-${amd_uuid: -8}"

  else
    uuid_path="/etc/device_uuid"
    [ ! -f "$uuid_path" ] && uuidgen | tee "$uuid_path" >/dev/null
    persistent_uuid=$(cat "$uuid_path" | tr -d '-')
    host_id="${env_prefix}-dev-${persistent_uuid: -8}"
  fi

  # No timestamp - cleaner hostnames
  final_hostname="${host_id}"
  echo "$final_hostname"
}

# apply_hostname
# Purpose: Set the hostname persistently if not already set correctly
apply_hostname() {
  local desired_hostname current_hostname
  desired_hostname=$(generate_hostname)
  current_hostname=$(hostnamectl --static 2>/dev/null || cat /etc/hostname)

  if [ "$current_hostname" != "$desired_hostname" ]; then
    echo "Updating device hostname from '$current_hostname' to '$desired_hostname'."
    hostnamectl set-hostname "$desired_hostname"

    if grep -q "127.0.1.1" /etc/hosts; then
      sed -i "s/^127.0.1.1\s.*/127.0.1.1\t$desired_hostname/" /etc/hosts
    else
      echo -e "127.0.1.1\t$desired_hostname" | tee -a /etc/hosts >/dev/null
    fi
  else
    echo "Hostname already set correctly to '$desired_hostname'. No changes required."
  fi
}

# Function to update puppet.conf
update_puppet_conf() {
  HOSTNAME=$(generate_hostname)

  # Ensure puppet service is stopped before making changes
  if systemctl is-active --quiet puppet; then
    echo "Stopping Puppet service before configuration..."
    systemctl stop puppet
  fi

  # Create puppetlabs directory structure if it doesn't exist
  mkdir -p /etc/puppetlabs/puppet

  echo "Downloading puppet.conf template from repository..."
  if ! curl -fsSL -o /tmp/puppet.conf.template "${ALM_CONFIG_REPO_URL}/puppet.conf"; then
    echo "Failed to download puppet.conf template. Check network connection."
    return 1
  fi

  # Replace the hostname placeholder and save to the correct location
  echo "Configuring puppet.conf with hostname: $HOSTNAME"
  sed "s/%%HOSTNAME%%/$HOSTNAME/g" /tmp/puppet.conf.template | tee "$PUPPET_CONF_FILE" > /dev/null

  # Clean up temporary file
  rm -f /tmp/puppet.conf.template

  # Set proper permissions
  chmod 644 "$PUPPET_CONF_FILE"

  echo "Puppet configuration completed successfully."
  return 0
}

# Function to ensure Puppet service is started and enabled
ensure_puppet_service() {
  # Ensure Puppet binaries are in PATH
  export PATH="/opt/puppetlabs/bin:$PATH"
  
  # Check if puppet.conf exists before starting service
  if [ ! -f "$PUPPET_CONF_FILE" ]; then
    echo "Error: $PUPPET_CONF_FILE does not exist. Cannot start Puppet service."
    return 1
  fi

  # Verify the puppet.conf file has required settings
  if ! grep -q "certname" "$PUPPET_CONF_FILE"; then
    echo "Error: Puppet config is missing certname. Cannot start Puppet service."
    return 1
  fi

  echo "Starting and enabling Puppet service..."

  # Enable the service first
  if ! systemctl enable puppet; then
    echo "Warning: Failed to enable Puppet service."
    # Continue anyway as this might still work
  else
    echo "Puppet service is now enabled to start on boot."
  fi

  # Start or restart the service
  if ! systemctl restart puppet; then
    echo "Error: Failed to start Puppet service."
    return 1
  fi

  echo "Puppet service started successfully."

  # Check status after starting
  systemctl status puppet --no-pager

  return 0
}

# Create flag file to indicate successful completion
create_flag_file() {
  echo "$(date): Puppet configuration completed successfully" > "$FLAG_FILE"
  chmod 644 "$FLAG_FILE"
  echo "Created flag file at $FLAG_FILE to prevent future runs"
}

### Main Script Execution

main() {
  # Add basic error handling
  set -e

  echo "=== Starting Puppet Configuration Script ==="
  echo "$(date): Beginning setup process"

  # Detect and display environment
  local detected_env
  detected_env=$(detect_alm_environment)
  echo "ALM Environment: ${detected_env}"
  echo "  - Hostname prefix: $([ "$detected_env" = "staging" ] && echo "stg-" || echo "prod-")"
  echo "  - Content: $([ "$detected_env" = "staging" ] && echo "TEST only" || echo "PRODUCTION + PRELIVE")"
  echo "  - API: $([ "$detected_env" = "staging" ] && echo "fapi-test.strealer.io" || echo "fapi.strealer.io")"

  echo "Installing Puppet agent (if needed)..."
  install_puppet_agent || { echo "Error installing Puppet agent. Exiting."; exit 1; }

  echo "Setting hardware-based hostname with environment prefix..."
  apply_hostname || { echo "Error setting hostname. Exiting."; exit 1; }

  echo "Updating Puppet configuration..."
  update_puppet_conf || { echo "Error updating Puppet configuration. Exiting."; exit 1; }

  echo "Starting Puppet service..."
  ensure_puppet_service || { echo "Error starting Puppet service. Exiting."; exit 1; }

  # Create flag file to prevent future runs
  create_flag_file

  echo "=== Puppet installation script completed successfully ==="
  echo "$(date): Setup process completed"
  echo "The device is now configured with hostname: $(hostname)"
  echo "Puppet agent will connect to: $PUPPET_MASTER"
  echo ""
  echo "NEXT STEPS:"
  echo "- Puppet agent will run automatically every 30 minutes"
  echo "- Force immediate run: sudo puppet agent -t"
  echo "- Wait ~5 minutes for full ALM environment setup via Puppet"
}

# Run the main function if the script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
