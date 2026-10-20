#!/usr/bin/env bash
# Archive with manual distribution signing and upload to TestFlight.
# Imports the shared iOS Distribution certificate (DIST_CERT_P12) into a
# temporary keychain, then fetches or creates an App Store profile per
# distributable target tied to that certificate. Does not create or delete
# certificates. The .p12 is the legacy RC2/3DES export, so macOS security
# imports it. This script does not read the .p12 with openssl. Export does
# not ask Xcode to refresh provisioning, because that option can mint a
# distribution certificate. Deletes the keychain, the .p12, and the API key
# on exit. Does not print secret values.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# TestFlight already holds builds up to 26 from the previous repository, so the
# build number is the run number plus this offset. A re-run of the same run
# appends .attempt so App Store Connect does not reject a repeated upload.
BUILD_NUMBER_OFFSET=100
compute_build_number() {
  local run_number="$1" attempt="${2:-1}" number
  if [[ ! "${run_number}" =~ ^[0-9]+$ ]]; then
    run_number=1
  fi
  number=$((run_number + BUILD_NUMBER_OFFSET))
  if [[ "${attempt}" != "1" ]]; then
    number="${number}.${attempt}"
  fi
  printf '%s' "${number}"
}

# Writes AuthKey_<id>.p8 from ASC_KEY_P8. Accepts base64 (whitespace ignored)
# or PEM text that begins with -----BEGIN PRIVATE KEY-----. Error text never
# includes the secret.
write_api_key() {
  python3 - <<'PY'
import base64
import os
import sys
from pathlib import Path

raw = os.environ.get("ASC_KEY_P8", "")
text = raw.replace("\r\n", "\n").replace("\r", "\n").lstrip("\ufeff").strip()
destination = Path(os.environ["KEY_PATH"])
if text.startswith("-----BEGIN PRIVATE KEY-----"):
    if "PRIVATE KEY" not in text:
        sys.exit("ASC_KEY_P8 does not look like a private key.")
    if not text.endswith("\n"):
        text += "\n"
    destination.write_text(text)
    sys.exit(0)
compact = "".join(text.split())
if not compact:
    sys.exit("ASC_KEY_P8 is empty.")
pad = (-len(compact)) % 4
try:
    data = base64.b64decode(compact + ("=" * pad), validate=True)
except Exception:
    sys.exit("ASC_KEY_P8 is not valid base64 and is not a PEM private key.")
if b"PRIVATE KEY" not in data:
    sys.exit("ASC_KEY_P8 decoded, but it does not look like a .p8 private key.")
destination.write_bytes(data)
PY
}

# Writes the shared distribution certificate from base64 DIST_CERT_P12.
# Error text never includes the secret.
write_p12() {
  python3 - <<'PY'
import base64
import os
import sys
from pathlib import Path

raw = os.environ.get("DIST_CERT_P12", "")
compact = "".join(raw.split())
destination = Path(os.environ["P12_PATH"])
if not compact:
    sys.exit("DIST_CERT_P12 is empty.")
pad = (-len(compact)) % 4
try:
    data = base64.b64decode(compact + ("=" * pad), validate=True)
except Exception:
    sys.exit("DIST_CERT_P12 is not valid base64.")
if not data or data[0] != 0x30:
    sys.exit("DIST_CERT_P12 decoded, but it does not look like a .p12.")
destination.write_bytes(data)
PY
}

write_p12_password() {
  python3 - <<'PY'
import os
import sys
from pathlib import Path

password = os.environ.get("DIST_CERT_PASSWORD", "")
if password.endswith("\r\n"):
    password = password[:-2]
elif password.endswith("\n") or password.endswith("\r"):
    password = password[:-1]
if not password:
    sys.exit("DIST_CERT_PASSWORD is empty.")
Path(os.environ["PASS_PATH"]).write_text(password)
PY
}

check_encryption() {
  local plist
  for plist in App/iOS/Info.plist App/Watch/Info.plist; do
    if ! awk '
      $0 ~ /<key>ITSAppUsesNonExemptEncryption<\/key>/ { found=1; next }
      found { exit ($0 ~ /<false\/>/) ? 0 : 1 }
      END { if (!found) exit 1 }
    ' "${ROOT}/${plist}"; then
      echo "${plist} must set ITSAppUsesNonExemptEncryption to false." >&2
      exit 1
    fi
  done
}

signing_base() {
  printf '%s' "${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
}

if [[ "${1:-}" == "--self-test" ]]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  pem=$'-----BEGIN PRIVATE KEY-----\nMIIB\n-----END PRIVATE KEY-----\n'
  b64="$(printf '%s' "${pem}" | base64 | fold -w 20)"
  run_case() {
    local label="$1"
    local value="$2"
    local out="${tmp}/${label}.p8"
    ASC_KEY_P8="${value}" KEY_PATH="${out}" write_api_key
    python3 - "${out}" "${label}" <<'PY'
import sys
from pathlib import Path
body = Path(sys.argv[1]).read_bytes()
if b"PRIVATE KEY" not in body or b"BEGIN" not in body:
    sys.exit("self-test failed for " + sys.argv[2])
print("asc key decode ok: " + sys.argv[2])
PY
  }
  run_case "pem" "${pem}"
  run_case "base64-wrapped" "${b64}"$'\n'
  run_case "base64-spaces" "$(printf '%s' "${pem}" | base64 | tr -d '\n' | sed 's/..../& /g')"
  if ASC_KEY_P8="not a key" KEY_PATH="${tmp}/bad.p8" write_api_key 2>"${tmp}/err"; then
    echo "self-test failed: invalid input was accepted" >&2
    exit 1
  fi
  if grep -q "not a key" "${tmp}/err"; then
    echo "self-test failed: error text included the secret" >&2
    exit 1
  fi
  echo "asc key decode rejected invalid input"
  p12_b64="$(python3 -c 'import base64; print(base64.b64encode(bytes([48, 3, 1, 1, 0])).decode())')"
  DIST_CERT_P12="${p12_b64}" P12_PATH="${tmp}/distribution.p12" write_p12
  python3 - "${tmp}/distribution.p12" <<'PY'
import sys
from pathlib import Path
body = Path(sys.argv[1]).read_bytes()
if body[:1] != b"\x30":
    sys.exit("self-test failed: p12 decode")
print("dist cert decode ok")
PY
  if DIST_CERT_P12="not-a-cert" P12_PATH="${tmp}/bad.p12" write_p12 2>"${tmp}/p12err"; then
    echo "self-test failed: invalid p12 was accepted" >&2
    exit 1
  fi
  if grep -q "not-a-cert" "${tmp}/p12err"; then
    echo "self-test failed: p12 error text included the secret" >&2
    exit 1
  fi
  echo "dist cert decode rejected invalid input"
  DIST_CERT_PASSWORD=$'pw-fixture\n' PASS_PATH="${tmp}/p12.pass" write_p12_password
  python3 - "${tmp}/p12.pass" <<'PY'
import sys
from pathlib import Path
if Path(sys.argv[1]).read_text() != "pw-fixture":
    sys.exit("self-test failed: p12 password file")
print("dist cert password file ok")
PY
  rm -rf "${tmp}"
  trap - EXIT
  check_encryption
  [[ "$(compute_build_number 1 1)" == "101" ]] || { echo "self-test failed: build number for run 1" >&2; exit 1; }
  [[ "$(compute_build_number 27 1)" == "127" ]] || { echo "self-test failed: build number for run 27" >&2; exit 1; }
  [[ "$(compute_build_number 5 3)" == "105.3" ]] || { echo "self-test failed: build number for a re-run" >&2; exit 1; }
  [[ "$(compute_build_number "" 1)" == "101" ]] || { echo "self-test failed: build number without a run" >&2; exit 1; }
  echo "build number ok: run 1 -> 101, run 5 attempt 3 -> 105.3"
  python3 - "${SCRIPT_DIR}/archive-upload.sh" "${SCRIPT_DIR}/asc_signing.py" "${ROOT}/.github/workflows/ios.yml" <<'PY'
import sys
from pathlib import Path
shell, signing, workflow = (Path(arg).read_text() for arg in sys.argv[1:])
upload = shell.split("\nmissing=0\n", 1)[1]
production = signing.split("\ndef self_test", 1)[0]
for label, text in (("upload", upload), ("signing", production)):
    if "csrContent" in text or "genrsa" in text or "BEGIN CERTIFICATE REQUEST" in text:
        sys.exit(label + " still creates a certificate")
    if "openssl pkcs12" in text or "openssl " + "pkcs12" in text:
        sys.exit(label + " reads the p12 with openssl")
forbidden = "allow" + "ProvisioningUpdates"
for line in upload.splitlines():
    stripped = line.strip()
    if stripped.startswith("xcodebuild") or stripped.startswith("-"):
        if forbidden in line:
            sys.exit("export asks Xcode to update provisioning")
if forbidden in workflow:
    sys.exit("workflow asks Xcode to update provisioning")
if "security import" not in upload or "set-key-partition-list" not in upload:
    sys.exit("upload does not import the shared certificate into a keychain")
if "find-certificate" not in upload:
    sys.exit("upload does not read the certificate from the keychain")
print("certificate creation absent")
PY
  for keychain_script in "${SCRIPT_DIR}/archive-upload.sh" "${SCRIPT_DIR}/delete-signing-keychain.sh"; do
    if ! grep -q 'watchremote-signing.keychain-db' "${keychain_script}"; then
      echo "self-test failed: keychain path is not shared" >&2
      exit 1
    fi
  done
  if ! awk '
    /Delete the temporary signing keychain/ { step=1 }
    step && /if: always\(\)/ { found=1 }
    END { exit found ? 0 : 1 }
  ' "${ROOT}/.github/workflows/ios.yml"; then
    echo "self-test failed: keychain cleanup is not an always step" >&2
    exit 1
  fi
  cleanup_tmp="$(mktemp -d)"
  mkdir -p "${cleanup_tmp}/watchremote-signing"
  printf 'secret' > "${cleanup_tmp}/watchremote-signing/distribution.p12"
  touch "${cleanup_tmp}/watchremote-signing.keychain-db"
  RUNNER_TEMP="${cleanup_tmp}" "${SCRIPT_DIR}/delete-signing-keychain.sh"
  if [[ -e "${cleanup_tmp}/watchremote-signing" || -e "${cleanup_tmp}/watchremote-signing.keychain-db" ]]; then
    echo "self-test failed: signing cleanup left files behind" >&2
    exit 1
  fi
  rm -rf "${cleanup_tmp}"
  echo "signing cleanup ok"
  python3 "${SCRIPT_DIR}/asc_signing.py" --self-test
  python3 "${SCRIPT_DIR}/asc_testflight.py" --self-test
  python3 "${SCRIPT_DIR}/patch-watch-embed.py" --self-test
  exit 0
fi

missing=0
for name in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8 DIST_CERT_P12 DIST_CERT_PASSWORD; do
  if [[ -z "${!name:-}" ]]; then
    echo "Missing GitHub secret ${name}." >&2
    missing=1
  fi
done
if [[ "${missing}" -ne 0 ]]; then
  echo "Add the App Store Connect API key and the shared distribution certificate before uploading. See docs/SETUP.md." >&2
  exit 1
fi

if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  echo "Missing GitHub secret DEVELOPMENT_TEAM." >&2
  exit 1
fi
TEAM="${DEVELOPMENT_TEAM}"
BUILD_NUMBER="$(compute_build_number "${GITHUB_RUN_NUMBER:-1}" "${GITHUB_RUN_ATTEMPT:-1}")"
echo "Archive build number ${BUILD_NUMBER} for com.lojo.WatchRemote and com.lojo.WatchRemote.watchkitapp."
BASE="$(signing_base)"
SECRET_DIR="${BASE}/watchremote-signing"
KEYCHAIN="${BASE}/watchremote-signing.keychain-db"
MANIFEST="${SECRET_DIR}/signing-manifest.json"
KEY_PATH="${SECRET_DIR}/private_keys/AuthKey_${ASC_KEY_ID}.p8"
P12_PATH="${SECRET_DIR}/distribution.p12"
PASS_PATH="${SECRET_DIR}/p12.pass"
KEYCHAIN_PASS="${SECRET_DIR}/keychain.pass"
cleanup() {
  local status=$?
  if [[ -f "${MANIFEST}" ]]; then
    SIGNING_MANIFEST="${MANIFEST}" python3 "${SCRIPT_DIR}/asc_signing.py" cleanup || \
      echo "Warning: could not remove local provisioning profiles for this run." >&2
  fi
  "${SCRIPT_DIR}/delete-signing-keychain.sh" || \
    echo "Warning: could not delete the temporary signing keychain." >&2
  exit "${status}"
}
trap cleanup EXIT
mkdir -p "${SECRET_DIR}/private_keys"
chmod 700 "${SECRET_DIR}"
export KEY_PATH P12_PATH PASS_PATH
umask 077
write_api_key
write_p12
write_p12_password

cd "${ROOT}"
if [[ ! -d WatchRemote.xcodeproj ]]; then
  xcodegen generate
fi
check_encryption

openssl rand -base64 32 | tr -d '\n' > "${KEYCHAIN_PASS}"
chmod 600 "${KEYCHAIN_PASS}" "${PASS_PATH}" "${P12_PATH}"
security delete-keychain "${KEYCHAIN}" >/dev/null 2>&1 || true
rm -f "${KEYCHAIN}"
security create-keychain -p "$(cat "${KEYCHAIN_PASS}")" "${KEYCHAIN}"
security set-keychain-settings -lut 21600 "${KEYCHAIN}"
security unlock-keychain -p "$(cat "${KEYCHAIN_PASS}")" "${KEYCHAIN}"
if ! security import "${P12_PATH}" \
  -k "${KEYCHAIN}" \
  -P "$(cat "${PASS_PATH}")" \
  -f pkcs12 -A \
  -T /usr/bin/codesign \
  -T /usr/bin/security >/dev/null; then
  echo "Could not import the distribution certificate into the temporary keychain." >&2
  exit 1
fi
if ! security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$(cat "${KEYCHAIN_PASS}")" \
  "${KEYCHAIN}" >/dev/null; then
  echo "Could not allow codesign to use the distribution key." >&2
  exit 1
fi
current="$(security list-keychains -d user | sed 's/^[[:space:]]*"//;s/"[[:space:]]*$//' | grep -v 'watchremote-signing.keychain-db' || true)"
# Add the temporary keychain without dropping the keychains already on the search list.
# shellcheck disable=SC2086
security list-keychains -d user -s "${KEYCHAIN}" ${current} >/dev/null
security default-keychain -s "${KEYCHAIN}"
identities="$(security find-identity -p codesigning -v "${KEYCHAIN}" 2>/dev/null || true)"
if ! printf '%s\n' "${identities}" | grep -q "Distribution"; then
  echo "The distribution certificate did not import into the temporary keychain." >&2
  exit 1
fi
echo "Imported the shared distribution certificate into the temporary keychain."

if ! security find-certificate -a -c "Distribution" -p "${KEYCHAIN}" > "${SECRET_DIR}/installed.pem"; then
  echo "Could not read the distribution certificate from the temporary keychain." >&2
  exit 1
fi

python3 "${SCRIPT_DIR}/asc_signing.py" prepare \
  --installed-pem "${SECRET_DIR}/installed.pem" \
  --manifest "${MANIFEST}" \
  --profiles-dir "${HOME}/Library/MobileDevice/Provisioning Profiles" \
  --team "${TEAM}" \
  --keychain "${KEYCHAIN}" \
  --pbxproj "${ROOT}/WatchRemote.xcodeproj/project.pbxproj" \
  --export-plist "${ROOT}/build/ExportOptions.plist"

echo "Archiving with manual distribution signing."
# App and extension targets are switched to Manual in the generated project.
# A global Manual setting would also hit unsigned package targets.
xcodebuild archive \
  -project WatchRemote.xcodeproj \
  -scheme WatchRemote \
  -destination "generic/platform=iOS" \
  -archivePath "${ROOT}/build/WatchRemote.xcarchive" \
  -clonedSourcePackagesDirPath "${ROOT}/build/SourcePackages" \
  -derivedDataPath "${ROOT}/build/ArchiveDerivedData" \
  DEVELOPMENT_TEAM="${TEAM}" \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER}"

python3 "${SCRIPT_DIR}/patch-watch-embed.py" --check-app \
  "${ROOT}/build/WatchRemote.xcarchive/Products/Applications/WatchRemote.app"

# The API key authenticates the upload. It is not used to create a certificate.
xcodebuild -exportArchive \
  -archivePath "${ROOT}/build/WatchRemote.xcarchive" \
  -exportPath "${ROOT}/build/export" \
  -exportOptionsPlist "${ROOT}/build/ExportOptions.plist" \
  -authenticationKeyPath "${KEY_PATH}" \
  -authenticationKeyID "${ASC_KEY_ID}" \
  -authenticationKeyIssuerID "${ASC_ISSUER_ID}"
echo "Uploaded to App Store Connect."
echo "Releasing build ${BUILD_NUMBER} to the internal TestFlight group."
KEY_PATH="${KEY_PATH}" BUILD_NUMBER="${BUILD_NUMBER}" \
  python3 "${SCRIPT_DIR}/asc_testflight.py" release --wait-seconds 1800 --require-ready
