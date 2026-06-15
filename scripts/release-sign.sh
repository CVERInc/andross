#!/bin/bash
# Sign, notarize, and staple a built andross.app — one command, fully
# parameterized by environment variables. This is the *release* path; it does
# NOT build (run ./scripts/build-app.sh first) and it does NOT upload the result
# to GitHub (that final step is the human's, see RELEASING.md).
#
#   DEVELOPER_ID="Developer ID Application: CVER Inc. (TEAMID)" \
#   NOTARY_PROFILE="andross-notary" \
#   ./scripts/release-sign.sh
#
# Optional env vars:
#   APP_PATH   path to the built .app           (default: /Applications/andross.app)
#   OUT_DIR    where the signed .zip is written (default: ./dist)
#
# Required secrets (see RELEASING.md for how to provision them):
#   DEVELOPER_ID     the full "Developer ID Application: …" identity string,
#                    matching a cert + private key in your login keychain.
#   NOTARY_PROFILE   the `xcrun notarytool store-credentials` keychain profile
#                    name holding your App Store Connect API key (or Apple ID +
#                    app-specific password + team id).
#
# What it does, in order:
#   1. codesign --deep --force --options runtime  (hardened runtime, required
#      for notarization)
#   2. verify the signature                       (codesign --verify + spctl)
#   3. ditto -c -k --keepParent  → a .zip notary submission archive
#   4. xcrun notarytool submit --wait             (blocks until Apple rules)
#   5. xcrun stapler staple                       (attaches the ticket to .app)
#   6. re-zip the *stapled* .app as the release artifact

set -euo pipefail
cd "$(dirname "$0")/.."

APP_PATH="${APP_PATH:-/Applications/andross.app}"
OUT_DIR="${OUT_DIR:-./dist}"

# ── Preflight ───────────────────────────────────────────────────────────────
fail=0
need_env() {
  if [[ -z "${!1:-}" ]]; then
    printf '✗ %s is required but unset — see RELEASING.md\n' "$1"
    fail=1
  fi
}
need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1 && ! xcrun --find "$1" >/dev/null 2>&1; then
    printf '✗ required tool not found: %s\n' "$1"
    fail=1
  fi
}

echo "▸ Preflight"
need_env DEVELOPER_ID
need_env NOTARY_PROFILE
need_cmd codesign
need_cmd ditto
need_cmd xcrun

if [[ ! -d "$APP_PATH" ]]; then
  printf '✗ app bundle not found at %s — run ./scripts/build-app.sh first\n' "$APP_PATH"
  fail=1
fi

# The signing identity must actually exist in a keychain, else codesign fails
# late and cryptically. Surface it now.
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$DEVELOPER_ID"; then
    printf '✓ signing identity found in keychain\n'
  else
    printf '✗ signing identity not found in any keychain: %s\n' "$DEVELOPER_ID"
    printf '  (list available identities with: security find-identity -v -p codesigning)\n'
    fail=1
  fi
fi

# The notarytool keychain profile must exist. There is no clean "list profiles"
# command, so we just note where it lives; a wrong name fails fast at step 4.
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  printf '• will submit with notarytool keychain profile: %s\n' "$NOTARY_PROFILE"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "✗ preflight failed — fix the ✗ items above, nothing was signed"
  exit 1
fi
echo "✓ preflight passed"

mkdir -p "$OUT_DIR"
APP_NAME="$(basename "$APP_PATH")"          # andross.app
STEM="${APP_NAME%.app}"                      # andross
SUBMIT_ZIP="$OUT_DIR/${STEM}-notarize.zip"   # transient: the notary submission
RELEASE_ZIP="$OUT_DIR/${STEM}.zip"           # final: the stapled release artifact

# ── 1. Sign with the hardened runtime ─────────────────────────────────────────
echo "▸ codesign (hardened runtime)"
codesign --deep --force --options runtime --timestamp \
  --sign "$DEVELOPER_ID" "$APP_PATH"

# ── 2. Verify the signature locally before paying the notary round-trip ───────
echo "▸ verify signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
# spctl will still report "rejected" until the ticket is stapled in step 5;
# that is expected here, so this check is informational only.
spctl --assess --type execute --verbose=4 "$APP_PATH" 2>&1 || \
  echo "  (spctl rejection before stapling is expected — continues after step 5)"

# ── 3. Build the notarization submission archive ──────────────────────────────
echo "▸ ditto → $SUBMIT_ZIP"
rm -f "$SUBMIT_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$SUBMIT_ZIP"

# ── 4. Submit to Apple and block until a verdict ──────────────────────────────
echo "▸ notarytool submit --wait"
xcrun notarytool submit "$SUBMIT_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

# ── 5. Staple the notarization ticket onto the .app ───────────────────────────
echo "▸ stapler staple"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

# ── 6. Zip the stapled app as the release artifact ────────────────────────────
echo "▸ ditto → $RELEASE_ZIP (stapled release artifact)"
rm -f "$RELEASE_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$RELEASE_ZIP"
rm -f "$SUBMIT_ZIP"

echo
echo "✓ Signed, notarized, and stapled: $APP_PATH"
echo "✓ Release artifact ready: $RELEASE_ZIP"
echo "  Next (human step): upload $RELEASE_ZIP to a GitHub Release. See RELEASING.md."
