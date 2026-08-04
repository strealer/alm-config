#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VECTOR_BIN=${VECTOR_BIN:-vector}
EXPECTED_VECTOR_VERSION=$(<"$REPO_ROOT/.vector-version")
VECTOR_CONFIG="$REPO_ROOT/observability/vector.yaml"

if ! command -v "$VECTOR_BIN" >/dev/null 2>&1; then
	echo "vector is required for semantic configuration validation" >&2
	exit 1
fi

actual_vector_version=$("$VECTOR_BIN" --version | awk '{print $2}')
if [[ "$actual_vector_version" != "$EXPECTED_VECTOR_VERSION" ]]; then
	echo "expected Vector $EXPECTED_VECTOR_VERSION, got $actual_vector_version" >&2
	exit 1
fi

export LOKI_ENDPOINT="http://85.222.235.47:3100"
export PROMETHEUS_ENDPOINT="http://85.222.235.47:9090"
"$VECTOR_BIN" validate \
	--no-environment \
	"$VECTOR_CONFIG"

if grep -q 'systemctl is-active strealer-container' "$VECTOR_CONFIG"; then
	echo "service health still checks the removed strealer-container unit" >&2
	exit 1
fi

if ! grep -q "docker inspect --format='{{.State.Status}}' alm" "$VECTOR_CONFIG"; then
	echo "service health does not inspect the real ALM container" >&2
	exit 1
fi

if ! grep -q '.source_type = "service_health"' "$VECTOR_CONFIG"; then
	echo "service health events do not match Grafana's log_source selector" >&2
	exit 1
fi
