#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

# The setup script performs root/disk preflight checks while being sourced.
# Isolate those checks so the production identity functions can be tested safely.
id() {
	if [[ "${1:-}" == "-u" ]]; then
		echo 0
	else
		command id "$@"
	fi
}

df() {
	printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\n'
	printf '/dev/test 67108864 1 67108863 1%% /\n'
}

export PUPPET_CERTNAME_FILE="$TEST_TMP/puppet-certname"
# shellcheck source=../system-files/configure_puppet_agent.sh
source "$REPO_ROOT/system-files/configure_puppet_agent.sh"
unset -f id df

timestamp_count_file="$TEST_TMP/timestamp-count"
echo 0 >"$timestamp_count_file"

generate_device_hostname() {
	printf 'prod-rpi4-test-12345678\n'
}

# Return a different timestamp for every call. This deterministically simulates
# retries and rotations crossing time boundaries without sleeping.
date() {
	if [[ "${1:-}" == "+%s%N" ]]; then
		local count
		count=$(<"$timestamp_count_file")
		count=$((count + 1))
		echo "$count" >"$timestamp_count_file"
		printf '173704920000000000%s\n' "$count"
	else
		command date "$@"
	fi
}

CACHED_DEVICE_HOSTNAME=""
device_hostname_before=$(get_device_hostname)
puppet_certname_first=$(get_puppet_certname)
CACHED_DEVICE_HOSTNAME=""
device_hostname_after=$(get_device_hostname)
puppet_certname_retry=$(get_puppet_certname)

if [[ "$device_hostname_before" != "$device_hostname_after" ]]; then
	echo "Stable device hostname changed across retry" >&2
	exit 1
fi

if [[ "$puppet_certname_first" != "$puppet_certname_retry" ]]; then
	echo "Puppet certname changed during a normal retry" >&2
	exit 1
fi

if [[ "$puppet_certname_first" != "${device_hostname_before}-"* ]]; then
	echo "Puppet certname is not namespaced under the stable device identity" >&2
	exit 1
fi

rm -f "$PUPPET_CERTNAME_FILE"
puppet_certname_rotated=$(get_puppet_certname)

if [[ "$puppet_certname_rotated" == "$puppet_certname_first" ]]; then
	echo "Explicit certificate rotation did not create a new certname" >&2
	exit 1
fi

if [[ "$(<"$timestamp_count_file")" != "2" ]]; then
	echo "Expected exactly one certname generation per certificate lifecycle" >&2
	exit 1
fi

echo "Device identity is stable; Puppet identity persists across retries and rotates explicitly"
