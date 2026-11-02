#!/bin/bash
# One reusable universal integration build. Hardware validation is separate.
set -euo pipefail
cd "$(dirname "$0")/.."
usage() { echo "Usage: $0 [--ci-ad-hoc]" >&2; exit 2; }
mode=developer-id
if [ "$#" -gt 0 ]; then
  [ "$#" -eq 1 ] && [ "$1" = --ci-ad-hoc ] || usage
  [ "${CI:-}" = true ] || { echo "--ci-ad-hoc is permitted only in CI; local hardware builds require Developer ID." >&2; exit 2; }
  mode=ci-ad-hoc
fi
identity=-
signing_keychain=""
umask 077
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if [ "$mode" = developer-id ]; then
  if [ -n "${OPENJBL_SIGNING_KEYCHAIN:-}" ]; then
    signing_keychain="$(python3 -c '
import pathlib, sys
path = pathlib.Path(sys.argv[1]).expanduser().resolve()
if not path.is_file():
    sys.exit("The explicitly selected signing keychain does not exist; no build was started.")
print(path)
' "$OPENJBL_SIGNING_KEYCHAIN")"
    # Some hosts omit otherwise usable identities from the valid-only search.
    # The explicit-keychain path independently verifies the selected leaf below.
    identities="$(security find-identity -p codesigning "$signing_keychain")"
  else
    identities="$(security find-identity -v -p codesigning)"
  fi
  identity="${OPENJBL_SIGNING_IDENTITY:-}"
  if [ -n "$identity" ]; then
    # Match a complete SHA-1 or certificate label, never a substring.
    identity="$(printf '%s\n' "$identities" | python3 -c '
import re, sys
requested = sys.argv[1]
matches = set((m[1].upper(), m[2]) for line in sys.stdin
              if (m := re.fullmatch(r"\s*\d+\) ([A-Fa-f0-9]{40}) \"(Developer ID Application: [^\"]+)\"(?:.*)?\s*", line)))
chosen = [sha for sha, label in matches if requested.lower() == sha.lower() or requested == label]
if len(chosen) != 1:
    sys.exit("The requested Developer ID identity is missing or ambiguous; no build was started.")
print(chosen[0])
' "$identity")"
  else
    identity="$(printf '%s\n' "$identities" | python3 -c '
import re, sys
matches = set(m[1].upper() for line in sys.stdin
              if (m := re.fullmatch(r"\s*\d+\) ([A-Fa-f0-9]{40}) \"Developer ID Application: [^\"]+\"(?:.*)?\s*", line)))
if len(matches) != 1:
    sys.exit("Blocked: install one Developer ID Application certificate with its private key, or select an existing identity using OPENJBL_SIGNING_IDENTITY. No ad-hoc fallback.")
print(next(iter(matches)))
')"
  fi
  if [ -n "$signing_keychain" ]; then
    security find-certificate -a -p "$signing_keychain" > "$tmp/keychain-certificates.pem"
    python3 - "$tmp/keychain-certificates.pem" "$identity" "$tmp/selected-leaf.der" <<'PY'
import hashlib, pathlib, re, ssl, sys
pem = pathlib.Path(sys.argv[1]).read_text()
matches = set()
try:
    for block in re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", pem, re.S):
        der = ssl.PEM_cert_to_DER_cert(block)
        if hashlib.sha1(der).hexdigest().upper() == sys.argv[2].upper():
            matches.add(der)
except (ValueError, TypeError):
    sys.exit("Cannot decode the selected keychain certificate.")
if len(matches) != 1:
    sys.exit("The selected identity has no exact matching certificate in that keychain.")
pathlib.Path(sys.argv[3]).write_bytes(next(iter(matches)))
PY
    security verify-cert -q -c "$tmp/selected-leaf.der" -p codeSign -L -k "$signing_keychain"
  fi
fi
derived="$PWD/build/Validation"
xcode_command=(xcodebuild -quiet -project OpenJBL.xcodeproj -scheme OpenJBL
  -configuration Release -destination 'generic/platform=macOS'
  -derivedDataPath "$derived" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO
  "CODE_SIGN_IDENTITY=$identity" ENABLE_HARDENED_RUNTIME=YES)
if [ "$mode" = developer-id ]; then
  code_sign_flags=--timestamp
  if [ -n "$signing_keychain" ]; then
    quoted_keychain="$(python3 -c 'import shlex, sys; print(shlex.quote(sys.argv[1]))' "$signing_keychain")"
    code_sign_flags="$code_sign_flags --keychain $quoted_keychain"
  fi
  xcode_command+=("OTHER_CODE_SIGN_FLAGS=$code_sign_flags")
fi
if [ "${OPENJBL_HOST_RESTRICTED:-0}" = 1 ]; then
  xcode_command+=(-IDEPackageSupportDisableManifestSandbox=YES 'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox')
fi
xcode_command+=(build)
"${xcode_command[@]}"
app="$derived/Build/Products/Release/OpenJBL.app"
binary="$app/Contents/MacOS/OpenJBL"
scripts/check-entitlements.sh "$app"
for architecture in arm64 x86_64; do lipo -verify_arch "$architecture" "$binary"; done
if [ "$mode" = developer-id ]; then
  # Require an Apple-anchored Developer ID Application signature, not a matching
  # certificate display name or a user-trusted self-signed substitute.
  codesign --verify --deep --strict \
    -R '=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$app"
  codesign -d --verbose=4 "$app" 2>&1 | python3 -c '
import sys
details = sys.stdin.read()
if "Authority=Developer ID Application:" not in details or "runtime" not in details or "Timestamp=" not in details:
    sys.exit("Validation artifact lacks Developer ID, Hardened Runtime or a secure timestamp.")
'
  codesign -d --extract-certificates "$tmp/artifact-cert-" "$app"
  python3 - "$tmp/artifact-cert-0" "$identity" <<'PY'
import hashlib, pathlib, sys
leaf = pathlib.Path(sys.argv[1])
if not leaf.is_file() or hashlib.sha1(leaf.read_bytes()).hexdigest().upper() != sys.argv[2].upper():
    sys.exit("The validation artifact was not signed with the selected certificate.")
PY
  verify_command=(security verify-cert -q -p codeSign -L)
  certificate_index=0
  while [ -f "$tmp/artifact-cert-$certificate_index" ]; do
    verify_command+=(-c "$tmp/artifact-cert-$certificate_index")
    certificate_index=$((certificate_index + 1))
  done
  if [ -n "$signing_keychain" ]; then verify_command+=(-k "$signing_keychain"); fi
  "${verify_command[@]}"
fi
ditto "$app" "$tmp/OpenJBL.app"
"$tmp/OpenJBL.app/Contents/MacOS/OpenJBL" --self-test > "$tmp/self-test.json"
python3 - "$tmp/self-test.json" <<'PY'
import json, sys
with open(sys.argv[1]) as file:
    report = json.load(file)
if report.get("passed") is not True:
    sys.exit("Relocated sandboxed self-test failed; this is not a validated build.")
PY
shasum -a 256 "$binary"
echo "Universal validation build passed: $app"
echo "Hardware behavior, permission persistence and release acceptance remain separate checks."
