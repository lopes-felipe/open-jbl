#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/check-release-gates.py
scripts/check-fixtures.sh
: "$DEVELOPER_ID_P12" "$P12_PASSWORD" "$NOTARY_KEY_ID" "$NOTARY_ISSUER" "$NOTARY_KEY_P8"
umask 077
tmp="$(mktemp -d)"
keychain="$tmp/signing.keychain-db"
keychain_password="$(openssl rand -hex 24)"
cleanup() {
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
printf '%s' "$DEVELOPER_ID_P12" | base64 --decode > "$tmp/signing.p12"
printf '%s' "$NOTARY_KEY_P8" > "$tmp/notary.p8"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$tmp/signing.p12" -P "$P12_PASSWORD" -k "$keychain" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null
identity="$(security find-identity -v -p codesigning "$keychain" | awk -F '"' '/Developer ID Application/{print $2; exit}')"
if [ -z "$identity" ]; then echo "No Developer ID Application identity." >&2; exit 1; fi
swift test
xcodebuild -quiet -project OpenJBL.xcodeproj -scheme OpenJBL -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$tmp/OpenJBL.xcarchive" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="$identity" \
  OTHER_CODE_SIGN_FLAGS="--keychain $keychain --timestamp --options runtime" archive
app="$tmp/OpenJBL.xcarchive/Products/Applications/OpenJBL.app"
scripts/check-entitlements.sh "$app"
for architecture in arm64 x86_64; do
  lipo -verify_arch "$architecture" "$app/Contents/MacOS/OpenJBL"
done
"$app/Contents/MacOS/OpenJBL" --self-test
export NOTARY_KEY_PATH="$tmp/notary.p8"
scripts/notarize.sh "$app"
mkdir -p dist
scripts/make-dmg.sh "$app" dist/OpenJBL.dmg
codesign --force --sign "$identity" --keychain "$keychain" --timestamp dist/OpenJBL.dmg
scripts/notarize.sh dist/OpenJBL.dmg
shasum -a 256 dist/OpenJBL.dmg > dist/OpenJBL.dmg.sha256
