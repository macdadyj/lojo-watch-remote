#!/usr/bin/env bash
# Archive with manual distribution signing and upload to TestFlight.
# The shared certificate is already in the temporary keychain created by
# import-dist-cert.sh. App Store profiles are fetched or created for each
# app bundle id through the App Store Connect API, bound to that certificate.
# This script does not create or revoke distribution certificates, and Xcode
# is not asked to create signing assets. It does not print secret values.
# The API key is deleted on exit. The keychain is deleted by import-dist-cert.sh --cleanup.
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
  bash "${SCRIPT_DIR}/import-dist-cert.sh" --self-test
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
if [[ -z "${SIGNING_KEYCHAIN:-}" || ! -f "${SIGNING_KEYCHAIN}" ]]; then
  echo "Import the shared distribution certificate before archiving." >&2
  exit 1
fi
if [[ -z "${SIGNING_CERT_DER:-}" || ! -f "${SIGNING_CERT_DER}" ]]; then
  echo "The shared distribution certificate was not decoded." >&2
  exit 1
fi
if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
  echo "The shared distribution certificate has no signing identity." >&2
  exit 1
fi
TEAM="${DEVELOPMENT_TEAM}"
BUILD_NUMBER="$(compute_build_number "${GITHUB_RUN_NUMBER:-1}" "${GITHUB_RUN_ATTEMPT:-1}")"
echo "Archive build number ${BUILD_NUMBER} for the app targets."
WORKDIR="$(mktemp -d)"
MANIFEST="${WORKDIR}/signing-manifest.json"
KEY_PATH="${WORKDIR}/private_keys/AuthKey_${ASC_KEY_ID}.p8"
cleanup() {
  local status=$?
  # The workflow also deletes the keychain from an always() step. Doing it
  # here covers a local run and a normal exit. Secrets are not printed.
  bash "${SCRIPT_DIR}/import-dist-cert.sh" --cleanup || \
    echo "Warning: could not delete the temporary signing keychain." >&2
  if [[ -f "${MANIFEST}" ]]; then
    SIGNING_MANIFEST="${MANIFEST}" python3 "${SCRIPT_DIR}/asc_signing.py" cleanup || \
      echo "Warning: could not remove local provisioning profiles for this run." >&2
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

python3 "${SCRIPT_DIR}/asc_signing.py" prepare \
  --certificate-der "${SIGNING_CERT_DER}" \
  --manifest "${MANIFEST}" \
  --profiles-dir "${HOME}/Library/MobileDevice/Provisioning Profiles" \
  --project-yml "${ROOT}/project.yml" \
  --team "${TEAM}" \
  --keychain "${SIGNING_KEYCHAIN}" \
  --pbxproj "${ROOT}/WatchRemote.xcodeproj/project.pbxproj" \
  --export-plist "${ROOT}/build/ExportOptions.plist" \
  --identity "${SIGNING_IDENTITY}"

echo "Archiving with manual distribution signing."
# The app targets were switched to Manual in the generated project, each with
# its own App Store profile. A global Manual setting would also hit unsigned
# package targets. Authentication is not passed here: the archive must sign
# with the imported certificate and the profiles already on disk.
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

# The API key authenticates the upload. It is not used to create a certificate
# or a profile; those profiles were installed before the archive.
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
