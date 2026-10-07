#!/usr/bin/env bash
# Archive with manual distribution signing and upload to TestFlight.
# The App Store Connect API key creates a new iOS Distribution certificate
# and App Store profiles. Existing certificates are never touched. On exit, success
# or failure, it deletes the profiles it created and revokes only the distribution
# certificate it created in this run, so certificates never pile up.
# Does not print secret values. Deletes the API key, keychain, and profiles on exit.
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

if [[ "${1:-}" == "--self-test" ]]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  pem=$'-----BEGIN PRIVATE KEY-----\nMIIB\n-----END PRIVATE KEY-----\n'
  # Wrapped base64, the shape `base64` writes and GitHub often stores.
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
  rm -rf "${tmp}"
  trap - EXIT
  check_encryption
  [[ "$(compute_build_number 1 1)" == "101" ]] || { echo "self-test failed: build number for run 1" >&2; exit 1; }
  [[ "$(compute_build_number 27 1)" == "127" ]] || { echo "self-test failed: build number for run 27" >&2; exit 1; }
  [[ "$(compute_build_number 5 3)" == "105.3" ]] || { echo "self-test failed: build number for a re-run" >&2; exit 1; }
  [[ "$(compute_build_number "" 1)" == "101" ]] || { echo "self-test failed: build number without a run" >&2; exit 1; }
  echo "build number ok: run 1 -> 101, run 5 attempt 3 -> 105.3"
  python3 "${SCRIPT_DIR}/asc_signing.py" --self-test
  python3 "${SCRIPT_DIR}/asc_testflight.py" --self-test
  python3 "${SCRIPT_DIR}/patch-watch-embed.py" --self-test
  exit 0
fi

missing=0
for name in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8; do
  if [[ -z "${!name:-}" ]]; then
    echo "Missing GitHub secret ${name}." >&2
    missing=1
  fi
done
if [[ "${missing}" -ne 0 ]]; then
  echo "Add the App Store Connect API key secrets before uploading. See docs/SETUP.md." >&2
  exit 1
fi

if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  echo "Missing GitHub secret DEVELOPMENT_TEAM." >&2
  exit 1
fi
TEAM="${DEVELOPMENT_TEAM}"
BUILD_NUMBER="$(compute_build_number "${GITHUB_RUN_NUMBER:-1}" "${GITHUB_RUN_ATTEMPT:-1}")"
echo "Archive build number ${BUILD_NUMBER} for com.lojo.WatchRemote and com.lojo.WatchRemote.watchkitapp."
WORKDIR="$(mktemp -d)"
KEYCHAIN="${WORKDIR}/signing.keychain-db"
MANIFEST="${WORKDIR}/signing-manifest.json"
KEY_PATH="${WORKDIR}/private_keys/AuthKey_${ASC_KEY_ID}.p8"
KEYCHAIN_READY=0
cleanup() {
  local status=$?
  if [[ "${KEYCHAIN_READY}" == "1" ]]; then
    security delete-keychain "${KEYCHAIN}" >/dev/null 2>&1 || true
    security default-keychain -s login.keychain-db >/dev/null 2>&1 || true
    security list-keychains -d user -s login.keychain-db >/dev/null 2>&1 || true
  fi
  if [[ -f "${MANIFEST}" && -f "${KEY_PATH}" ]]; then
    # Deletes this run's profiles, then revokes only the certificate this run created.
    SIGNING_MANIFEST="${MANIFEST}" python3 "${SCRIPT_DIR}/asc_signing.py" cleanup || \
      echo "Warning: could not fully clean up App Store Connect signing assets for this run." >&2
  fi
  rm -rf "${WORKDIR}"
  exit "${status}"
}
trap cleanup EXIT
mkdir -p "${WORKDIR}/private_keys"
export KEY_PATH
umask 077
write_api_key

cd "${ROOT}"
if [[ ! -d WatchRemote.xcodeproj ]]; then
  xcodegen generate
fi
check_encryption

openssl genrsa -out "${WORKDIR}/distribution.key" 2048
cat > "${WORKDIR}/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = Watch Remote Distribution
EOF
openssl req -new -sha256 \
  -key "${WORKDIR}/distribution.key" \
  -out "${WORKDIR}/distribution.csr" \
  -config "${WORKDIR}/openssl.cnf"

python3 "${SCRIPT_DIR}/asc_signing.py" prepare \
  --certificate-out "${WORKDIR}/distribution.cer" \
  --manifest "${MANIFEST}" \
  --profiles-dir "${HOME}/Library/MobileDevice/Provisioning Profiles" \
  --csr "${WORKDIR}/distribution.csr" \
  --team "${TEAM}" \
  --keychain "${KEYCHAIN}" \
  --pbxproj "${ROOT}/WatchRemote.xcodeproj/project.pbxproj" \
  --export-plist "${ROOT}/build/ExportOptions.plist"

openssl x509 -inform DER -in "${WORKDIR}/distribution.cer" -out "${WORKDIR}/distribution.pem"
openssl rand -base64 32 | tr -d '\n' > "${WORKDIR}/keychain.pass"
chmod 600 "${WORKDIR}/keychain.pass"
openssl pkcs12 -export \
  -inkey "${WORKDIR}/distribution.key" \
  -in "${WORKDIR}/distribution.pem" \
  -out "${WORKDIR}/distribution.p12" \
  -passout "file:${WORKDIR}/keychain.pass"
security create-keychain -p "$(cat "${WORKDIR}/keychain.pass")" "${KEYCHAIN}"
KEYCHAIN_READY=1
security set-keychain-settings -lut 21600 "${KEYCHAIN}"
security unlock-keychain -p "$(cat "${WORKDIR}/keychain.pass")" "${KEYCHAIN}"
security import "${WORKDIR}/distribution.p12" \
  -k "${KEYCHAIN}" \
  -P "$(cat "${WORKDIR}/keychain.pass")" \
  -f pkcs12 -A \
  -T /usr/bin/codesign \
  -T /usr/bin/security >/dev/null
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$(cat "${WORKDIR}/keychain.pass")" \
  "${KEYCHAIN}" >/dev/null
security list-keychains -d user -s "${KEYCHAIN}" login.keychain-db >/dev/null
security default-keychain -s "${KEYCHAIN}"
if ! security find-identity -p codesigning "${KEYCHAIN}" 2>/dev/null | grep -q "Distribution"; then
  echo "The distribution certificate did not import into the temporary keychain." >&2
  exit 1
fi

echo "Archiving with manual distribution signing."
# The two app targets were switched to Manual in the generated project, each
# with its own App Store profile. A global Manual setting would also hit
# unsigned package targets.
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
  python3 "${SCRIPT_DIR}/asc_testflight.py" release --wait-seconds 900
