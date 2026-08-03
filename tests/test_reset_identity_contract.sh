#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ALM="$REPO_ROOT/system-files/alm"
BOOTSTRAP="$REPO_ROOT/system-files/configure_puppet_agent.sh"

factory_capture_line=$(grep -n 'certname=$(get_current_puppet_certname)' "$ALM" | head -1 | cut -d: -f1)
factory_ssl_delete_line=$(grep -n 'rm -rf /etc/puppetlabs/puppet/ssl' "$ALM" | head -1 | cut -d: -f1)
if [[ "$factory_capture_line" -ge "$factory_ssl_delete_line" ]]; then
	echo "Factory reset deletes TLS state before capturing the actual Puppet certname" >&2
	exit 1
fi

if ! grep -q 'ca clean --certname $certname' "$ALM" || ! grep -q 'ca clean --certname $old_certname' "$ALM"; then
	echo "Reset paths clean the CA using OS hostname instead of Puppet certname" >&2
	exit 1
fi

rotation_calls=$(grep -c 'ROTATE_CERTIFICATE=1 bash' "$ALM")
if [[ "$rotation_calls" -lt 2 ]]; then
	echo "Factory reset and environment switching do not explicitly rotate Puppet identity" >&2
	exit 1
fi

if ! grep -q 'Seed the persistent identity when upgrading devices' "$BOOTSTRAP"; then
	echo "Existing certificates are not migrated into the persistent identity file" >&2
	exit 1
fi

echo "Reset, environment switch, and legacy upgrade preserve stable device identity and rotate only Puppet TLS identity"
