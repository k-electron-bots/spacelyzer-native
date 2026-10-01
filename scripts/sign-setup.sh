#!/bin/bash
# Import the self-signed code-signing identity into a throwaway keychain (CI only).
# Env: SIGNING_CERT_P12_BASE64, SIGNING_CERT_PASSWORD. Prints the identity hash on the last line.
set -euo pipefail
KC="$RUNNER_TEMP/spz-signing.keychain-db"
KCPW="$(uuidgen)"
echo "$SIGNING_CERT_P12_BASE64" | base64 --decode > "$RUNNER_TEMP/spz.p12"
security create-keychain -p "$KCPW" "$KC"
security set-keychain-settings -lut 3600 "$KC"
security unlock-keychain -p "$KCPW" "$KC"
security import "$RUNNER_TEMP/spz.p12" -k "$KC" -P "$SIGNING_CERT_PASSWORD" -T /usr/bin/codesign -A
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPW" "$KC" >/dev/null
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
rm -f "$RUNNER_TEMP/spz.p12"
HASH="$(security find-identity -p codesigning "$KC" | awk '/Spacelyzer Self-Signed/ {print $2; exit}')"
[[ -n "$HASH" ]] || { echo "identity not found"; security find-identity "$KC"; exit 1; }
echo "$HASH"
