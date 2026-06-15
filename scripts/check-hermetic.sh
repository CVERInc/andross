#!/bin/bash
# Hermetic-build preflight: verify a *fresh* Apple-silicon Mac has everything
# needed to build andross.app reproducibly from a clean checkout — BEFORE the
# (slow) build itself. Run it on a new machine to catch a missing prerequisite
# early instead of midway through a build.
#
#   ./scripts/check-hermetic.sh
#
# Exit codes:
#   0  all required prerequisites present (build should be reproducible)
#   1  a required prerequisite is missing
#
# GUARDED: checks that genuinely need the network (resolving the pinned Signet
# dependency) degrade to a SKIP — with a non-fatal note — when offline, so the
# script stays useful on an air-gapped machine and in CI. The pin itself is
# still verified offline from Package.resolved.

set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
note() { printf '  • %s\n' "$1"; }
ok()   { printf '✓ %s\n' "$1"; }
bad()  { printf '✗ %s\n' "$1"; fail=1; }
skip() { printf '~ %s (skipped)\n' "$1"; }

echo "▸ Apple-silicon (arm64) host"
arch="$(uname -m)"
if [[ "$arch" == "arm64" ]]; then
  ok "running on arm64 ($arch)"
else
  bad "expected arm64 (Apple silicon), got '$arch' — the Android emulator maps onto M-series silicon"
fi

echo "▸ Swift toolchain (Command Line Tools — no Xcode required)"
if command -v swift >/dev/null 2>&1; then
  ok "swift present: $(swift --version 2>/dev/null | head -1)"
else
  bad "swift not found — install Apple Command Line Tools: xcode-select --install"
fi

echo "▸ Pinned dependency is reproducible"
if [[ -f Package.resolved ]] && grep -q '"revision"' Package.resolved; then
  rev="$(grep '"revision"' Package.resolved | head -1 | sed -E 's/.*"revision" *: *"([0-9a-f]+)".*/\1/')"
  ok "Signet pinned to a fixed revision (${rev:0:12}…) in Package.resolved"
else
  bad "Package.resolved missing or has no pinned revision — build would not be reproducible"
fi

echo "▸ Dependency fetch (network-guarded)"
if [[ -d .build/checkouts/signet ]]; then
  ok "Signet already checked out locally — offline build possible"
elif curl -sSI --max-time 5 https://github.com >/dev/null 2>&1; then
  ok "github.com reachable — 'swift build' can resolve the pinned dependency"
else
  skip "github.com unreachable and no local checkout"
  note "first build on this machine needs network once to fetch the pinned Signet revision"
fi

echo
if [[ "$fail" -eq 0 ]]; then
  echo "✓ hermetic preflight passed — see README 'Reproducible build' for the full recipe"
else
  echo "✗ hermetic preflight found a missing prerequisite (see ✗ lines above)"
fi
exit "$fail"
