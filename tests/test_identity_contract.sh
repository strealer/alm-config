#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BOOTSTRAP="$REPO_ROOT/system-files/configure_puppet_agent.sh"
PROGRESS="$REPO_ROOT/system-files/alm-setup-progress"
VECTOR="$REPO_ROOT/observability/vector.yaml"

require_pattern() {
	local pattern="$1" file="$2" description="$3"
	if ! grep -Eq "$pattern" "$file"; then
		echo "Identity contract failed: $description ($file)" >&2
		exit 1
	fi
}

require_pattern 'desired_hostname=\$\(get_device_hostname\)' "$BOOTSTRAP" \
	"OS hostname must use the stable device identity"
require_pattern 'puppet_certname=\$\(get_puppet_certname\)' "$BOOTSTRAP" \
	"puppet.conf must use the persisted Puppet identity"
require_pattern 'PUPPET_CERTNAME_FILE=.*\/etc\/strealer\/puppet-certname' "$BOOTSTRAP" \
	"Puppet certname must survive service retries"
require_pattern 'puppet_certname=\$\(get_puppet_certname\)' "$PROGRESS" \
	"progress checks must dynamically follow Puppet's configured certname"
require_pattern 'config print certname --section agent' "$PROGRESS" \
	"progress checks must read the agent section instead of Puppet's main-section default"
require_pattern 'config print certname --section agent' "$REPO_ROOT/system-files/alm" \
	"reset identity fallback must read the agent section instead of Puppet's main-section default"
require_pattern 'get_hostname\(\)' "$VECTOR" \
	"Vector labels must use the stable OS hostname"
require_pattern 'io\.open\("/etc/hostname"' "$VECTOR" \
	"Vector container metrics must use the mounted stable OS hostname"

echo "Device, Puppet, progress, and observability identity contracts are consistent"
