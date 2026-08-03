#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VECTOR_BIN=${VECTOR_BIN:-vector}
EXPECTED_VECTOR_VERSION=$(<"$REPO_ROOT/.vector-version")

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
	"$REPO_ROOT/observability/vector.yaml"
