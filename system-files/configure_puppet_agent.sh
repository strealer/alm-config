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
#   # Force re-run (bypass flag file check):
#   curl -fsSL ... | FORCE=1 bash
#
#   # Or create flag file before first boot (for pi-gen images):
#   echo "staging" > /etc/alm-environment
#
# ENVIRONMENT SELECTION:
#   - **staging**: Hostname prefix 'stg-', uses TEST content, fapi-test.strealer.io
#   - **production**: Hostname prefix 'prod-', uses PRODUCTION+PRELIVE, fapi.strealer.io
#   - Default: production (if not specified)
#
# IDEMPOTENCY:
#   - Safe to run multiple times
#   - Uses flag file to skip if already completed
#   - Set FORCE=1 to bypass flag file check
#   - Only modifies system if changes needed
#
# ============================================================================

set -euo pipefail

# ============================================================================
# CONSTANTS
# ============================================================================
readonly FLAG_FILE="/var/lib/puppet-config-done"
readonly PUPPET_MASTER="puppet.strealer.io"
readonly PUPPET_CONF_FILE="/etc/puppetlabs/puppet/puppet.conf"
readonly ALM_CONFIG_REPO_URL="https://raw.githubusercontent.com/strealer/alm-config/main/system-files"
readonly AUTOSIGN_SECRET_FILE="/etc/strealer/autosign_secret"

# Cached hostname (computed once, used multiple times)
CACHED_HOSTNAME=""

# Support FORCE flag with default value (for set -u compatibility)
: "${FORCE:=0}"
: "${ALM_ENVIRONMENT:=}"

# ============================================================================
# EARLY CHECKS
# ============================================================================

# Check if running as root
if [[ "$(id -u)" -ne 0 ]]; then
	echo "Error: This script must be run as root. Please use 'sudo' or run as root user."
	exit 1
fi

# Check disk space requirements early to avoid wasting time on Puppet setup
total_disk_size_kb=$(df / | awk 'NR==2 {print $2}')
available_disk_size_kb=$(df / | awk 'NR==2 {print $4}')
total_disk_size_gb=$((total_disk_size_kb / 1024 / 1024))
available_disk_size_gb=$((available_disk_size_kb / 1024 / 1024))

if [[ $total_disk_size_gb -le 20 ]]; then
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

# Early cleanup for puppet certificate/service issues if flagged run
if [[ -f "$FLAG_FILE" ]]; then
	if systemctl status puppet 2>&1 | grep -qE 'certificate.*does not match|key values mismatch|SSL_CTX_use_PrivateKey|Could not parse PKey: unsupported' || ! systemctl is-active --quiet puppet; then
		echo "Detected Puppet certificate or service issues. Cleaning up SSL and removing flag file..."
		rm -rf "$FLAG_FILE" "$PUPPET_CONF_FILE" /etc/puppetlabs/puppet/ssl
	fi
fi

# Check if script has already run (unless FORCE=1)
if [[ -f "$FLAG_FILE" ]] && [[ "$FORCE" != "1" ]]; then
	echo "Puppet configuration has already been completed. Exiting."
	echo "To force re-configuration, run with FORCE=1 or delete $FLAG_FILE"
	exit 0
fi

# If FORCE mode, clean up for fresh start
if [[ "$FORCE" == "1" ]] && [[ -f "$FLAG_FILE" ]]; then
	echo "FORCE mode enabled. Removing flag file and cleaning SSL certificates..."
	rm -rf "$FLAG_FILE" "$PUPPET_CONF_FILE" /etc/puppetlabs/puppet/ssl
fi

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

	# Check if puppet is already installed - check both PATH and explicit location
	# (puppet might be installed but /opt/puppetlabs/bin not in PATH for this shell)
	local puppet_cmd=""
	if command -v puppet >/dev/null 2>&1; then
		puppet_cmd="puppet"
	elif [[ -x /opt/puppetlabs/bin/puppet ]]; then
		puppet_cmd="/opt/puppetlabs/bin/puppet"
		# Add to PATH for this session
		export PATH="/opt/puppetlabs/bin:$PATH"
	fi

	if [[ -n "$puppet_cmd" ]] && $puppet_cmd --version >/dev/null 2>&1; then
		echo "Puppet agent is already installed and working. Version: $($puppet_cmd --version)"
		return 0
	fi

	echo "Puppet agent not found or not working. Installing..."

	# Only install wget if not present
	if ! command -v wget >/dev/null 2>&1; then
		echo "Installing wget..."
		apt-get update
		apt-get install -y wget || {
			echo "Error: Failed to install wget"
			return 1
		}
	fi

	# Detect distribution and version
	if [[ -f /etc/os-release ]]; then
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
		"bookworm" | "bullseye" | "buster")
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
		"jammy" | "focal" | "bionic")
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
		echo 'export PATH="/opt/puppetlabs/bin:$PATH"' >>/etc/profile.d/puppet.sh
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
	if [[ -n "$ALM_ENVIRONMENT" ]]; then
		env_value="$ALM_ENVIRONMENT"
	# Priority 2: Flag file (for pi-gen images)
	elif [[ -f /etc/alm-environment ]]; then
		env_value=$(tr -d '[:space:]' </etc/alm-environment)
	# Default: production
	else
		env_value="production"
	fi

	# Normalize to lowercase and validate
	env_value=$(echo "$env_value" | tr '[:upper:]' '[:lower:]')
	case "$env_value" in
	staging | stg) echo "staging" ;;
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
# HOSTNAME FORMAT: <env>-<type>-<secret>-<serial>
# The secret must match Puppet server's autosign.conf pattern.
# Secret is read from /etc/strealer/autosign_secret (set during provisioning).
#
# **Staging Raspberry Pi Devices:**
# - stg-rpi4-<secret>-12345678 (Pi 4 Model B, staging)
# - stg-rpi5-<secret>-abcdef12 (Pi 5 Model B, staging)
#
# **Production Raspberry Pi Devices:**
# - prod-rpi4-<secret>-12345678 (Pi 4 Model B, production)
# - prod-rpi5-<secret>-abcdef12 (Pi 5 Model B, production)
#
# **AMD64 Servers:**
# - stg-amd-<secret>-9a8b7c6d (staging)
# - prod-amd-<secret>-9a8b7c6d (production)
#
# **Development/Generic Systems:**
# - stg-dev-<secret>-4f5e6d7c or prod-dev-<secret>-4f5e6d7c
#
# WHY HARDWARE-BASED HOSTNAMES:
# - **Puppet Identification** - Each device gets unique certificate/configuration
# - **Environment Classification** - Puppet uses hostname prefix to determine environment
# - **Infrastructure Tracking** - Easy identification in monitoring and logs
# - **Deployment Consistency** - Same device always gets same base hostname
# ============================================================================
generate_hostname() {
	local rpi_serial amd_uuid host_id rpi_model final_hostname persistent_uuid uuid_path env_prefix

	# Autosign secret - must match pattern in Puppet server's autosign.conf
	# Read from config file (set during provisioning via pi-gen or manual setup)
	local autosign_secret=""

	if [[ -f "$AUTOSIGN_SECRET_FILE" ]]; then
		autosign_secret=$(tr -d '[:space:]' <"$AUTOSIGN_SECRET_FILE")
	fi

	if [[ -z "$autosign_secret" ]]; then
		echo "ERROR: Autosign secret not found at $AUTOSIGN_SECRET_FILE" >&2
		echo "Please create this file with the secret from your Puppet server." >&2
		exit 1
	fi

	# Get environment prefix
	local alm_env
	alm_env=$(detect_alm_environment)
	case "$alm_env" in
	staging) env_prefix="stg" ;;
	*) env_prefix="prod" ;;
	esac

	if grep -q "^Serial" /proc/cpuinfo; then
		rpi_serial=$(awk '/^Serial/{print $3}' /proc/cpuinfo)
		if [[ -z "$rpi_serial" ]]; then
			echo "ERROR: Found Serial in /proc/cpuinfo but value is empty" >&2
			exit 1
		fi
		rpi_model=$(tr -d '\0' </proc/device-tree/model 2>/dev/null)
		local serial_suffix="${rpi_serial: -8}"
		case "$rpi_model" in
		*"Raspberry Pi 5 Model B"*) host_id="${env_prefix}-rpi5-${autosign_secret}-${serial_suffix}" ;;
		*"Raspberry Pi 4 Model B"*) host_id="${env_prefix}-rpi4-${autosign_secret}-${serial_suffix}" ;;
		*"Raspberry Pi 3 Model B Plus"*) host_id="${env_prefix}-rpi3bp-${autosign_secret}-${serial_suffix}" ;;
		*"Raspberry Pi 3 Model B"*) host_id="${env_prefix}-rpi3b-${autosign_secret}-${serial_suffix}" ;;
		*"Raspberry Pi 3 Model A Plus"*) host_id="${env_prefix}-rpi3ap-${autosign_secret}-${serial_suffix}" ;;
		*"Raspberry Pi 2 Model B"*) host_id="${env_prefix}-rpi2b-${autosign_secret}-${serial_suffix}" ;;
		*"Raspberry Pi Model B Plus"*) host_id="${env_prefix}-rpi1bp-${autosign_secret}-${serial_suffix}" ;;
		*"Raspberry Pi Model A Plus"*) host_id="${env_prefix}-rpi1ap-${autosign_secret}-${serial_suffix}" ;;
		*"Raspberry Pi Model B Rev"* | "Raspberry Pi Model B"*) host_id="${env_prefix}-rpi1b-${autosign_secret}-${serial_suffix}" ;;
		*"Raspberry Pi Model A"*) host_id="${env_prefix}-rpi1a-${autosign_secret}-${serial_suffix}" ;;
		*"Raspberry Pi Zero 2 W"*) host_id="${env_prefix}-rpiz2w-${autosign_secret}-${serial_suffix}" ;;
		*"Raspberry Pi Zero W"*) host_id="${env_prefix}-rpizw-${autosign_secret}-${serial_suffix}" ;;
		*"Raspberry Pi Zero"*) host_id="${env_prefix}-rpiz-${autosign_secret}-${serial_suffix}" ;;
		*"Compute Module 4"*) host_id="${env_prefix}-rpicm4-${autosign_secret}-${serial_suffix}" ;;
		*"Compute Module 3 Plus"*) host_id="${env_prefix}-rpicm3p-${autosign_secret}-${serial_suffix}" ;;
		*"Compute Module 3"*) host_id="${env_prefix}-rpicm3-${autosign_secret}-${serial_suffix}" ;;
		*"Compute Module"*) host_id="${env_prefix}-rpicm1-${autosign_secret}-${serial_suffix}" ;;
		*) host_id="${env_prefix}-rpi-${autosign_secret}-${serial_suffix}" ;;
		esac

	elif [[ -f /sys/class/dmi/id/product_uuid ]]; then
		amd_uuid=$(tr -d '-' </sys/class/dmi/id/product_uuid)
		if [[ -z "$amd_uuid" ]]; then
			echo "ERROR: product_uuid file exists but is empty" >&2
			exit 1
		fi
		local uuid_suffix="${amd_uuid: -8}"
		host_id="${env_prefix}-amd-${autosign_secret}-${uuid_suffix}"

	else
		uuid_path="/etc/device_uuid"
		[[ ! -f "$uuid_path" ]] && uuidgen >"$uuid_path"
		persistent_uuid=$(tr -d '-' <"$uuid_path")
		host_id="${env_prefix}-dev-${autosign_secret}-${persistent_uuid: -8}"
	fi

	# No timestamp - cleaner hostnames
	final_hostname="${host_id}"
	echo "$final_hostname"
}

# ============================================================================
# get_hostname()
# ============================================================================
#
# WHAT THIS FUNCTION DOES:
# - Returns cached hostname if already computed
# - Calls generate_hostname() only once and caches result
# - Use this instead of generate_hostname() to avoid redundant computation
# ============================================================================
get_hostname() {
	if [[ -z "$CACHED_HOSTNAME" ]]; then
		CACHED_HOSTNAME=$(generate_hostname)
	fi
	echo "$CACHED_HOSTNAME"
}

# apply_hostname
# Purpose: Set the hostname persistently if not already set correctly
apply_hostname() {
	local desired_hostname current_hostname
	desired_hostname=$(get_hostname)
	# Try hostnamectl first, fall back to /etc/hostname, then to 'localhost'
	current_hostname=$(hostnamectl --static 2>/dev/null || cat /etc/hostname 2>/dev/null | tr -d '[:space:]' || echo "localhost")

	if [[ "$current_hostname" != "$desired_hostname" ]]; then
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
	local HOSTNAME
	HOSTNAME=$(get_hostname)

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
	sed "s/%%HOSTNAME%%/$HOSTNAME/g" /tmp/puppet.conf.template | tee "$PUPPET_CONF_FILE" >/dev/null

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
	if [[ ! -f "$PUPPET_CONF_FILE" ]]; then
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
	echo "$(date): Puppet configuration completed successfully" >"$FLAG_FILE"
	chmod 644 "$FLAG_FILE"
	echo "Created flag file at $FLAG_FILE to prevent future runs"
}

### Main Script Execution

main() {
	echo "=== Starting Puppet Configuration Script ==="
	echo "$(date): Beginning setup process"

	# Detect and display environment
	local detected_env
	detected_env=$(detect_alm_environment)
	echo "ALM Environment: ${detected_env}"
	echo "  - Hostname prefix: $([[ "$detected_env" == "staging" ]] && echo "stg-" || echo "prod-")"
	echo "  - Content: $([[ "$detected_env" == "staging" ]] && echo "TEST only" || echo "PRODUCTION + PRELIVE")"
	echo "  - API: $([[ "$detected_env" == "staging" ]] && echo "fapi-test.strealer.io" || echo "fapi.strealer.io")"

	echo "Installing Puppet agent (if needed)..."
	install_puppet_agent || {
		echo "Error installing Puppet agent. Exiting."
		exit 1
	}

	echo "Setting hardware-based hostname with environment prefix..."
	apply_hostname || {
		echo "Error setting hostname. Exiting."
		exit 1
	}

	echo "Updating Puppet configuration..."
	update_puppet_conf || {
		echo "Error updating Puppet configuration. Exiting."
		exit 1
	}

	echo "Starting Puppet service..."
	ensure_puppet_service || {
		echo "Error starting Puppet service. Exiting."
		exit 1
	}

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

# Run the main function if the script is executed directly or piped
# BASH_SOURCE is empty when piped through bash (curl | bash), so we check for that too
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]] || [[ -z "${BASH_SOURCE[0]:-}" ]]; then
	main
fi
