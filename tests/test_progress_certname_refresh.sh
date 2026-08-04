#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

mock_puppet="$TEST_TMP/puppet"
cat >"$mock_puppet" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "config" ]] && [[ "${2:-}" == "print" ]] && [[ "${3:-}" == "certname" ]] &&
	[[ "${4:-}" == "--section" ]] && [[ "${5:-}" == "agent" ]]; then
	value_file="$(dirname "$0")/certname"
	[[ -s "$value_file" ]] || exit 1
	cat "$value_file"
	exit 0
fi
exit 1
EOF
chmod +x "$mock_puppet"

export PUPPET_BIN="$mock_puppet"
# shellcheck source=../system-files/alm-setup-progress
source "$REPO_ROOT/system-files/alm-setup-progress"
DEVICE_HOSTNAME="prod-rpi4-test-12345678"

before_configuration=$(get_puppet_certname)
printf '%s\n' 'prod-rpi4-test-12345678-1737049200123456789' >"$TEST_TMP/certname"
after_configuration=$(get_puppet_certname)

if [[ "$before_configuration" != "$DEVICE_HOSTNAME" ]]; then
	echo "Expected hostname fallback before Puppet configuration" >&2
	exit 1
fi

if [[ "$after_configuration" != 'prod-rpi4-test-12345678-1737049200123456789' ]]; then
	echo "Progress monitor did not refresh Puppet certname after configuration" >&2
	exit 1
fi

echo "Progress monitor refreshes the agent-section certname after Puppet configuration appears"
