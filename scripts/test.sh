#!/bin/bash
# Auto-guard: build everything + run unit tests. Run before every commit.
#
#   ./scripts/test.sh             # build (release) + unit tests
#   ./scripts/test.sh integration # additionally boots an AVD headless and
#                                 # exercises the identity lifecycle for real
#                                 # (needs SDK + an existing AVD; takes minutes)

set -euo pipefail
cd "$(dirname "$0")/.."

echo "▸ swift build -c release"
swift build -c release

echo "▸ unit tests"
swift run -c release AndrossUnitTests

if [[ "${1:-}" == "integration" ]]; then
  echo "▸ integration: booting AVD headless and exercising identity lifecycle"
  swift run -c release AndrossIntegration
fi

echo "✓ all checks passed"
