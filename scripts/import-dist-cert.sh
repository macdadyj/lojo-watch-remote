#!/usr/bin/env bash
# Import the shared iOS Distribution certificate into a temporary keychain.
# DIST_CERT_P12 is a base64-encoded .p12 (certificate plus private key).
# DIST_CERT_PASSWORD is that file's password. Neither value is printed.
# Cleanup deletes the keychain and the decoded files. It does not need the secrets.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_STATE_DIR="${RUNNER_TEMP:-/tmp}/watchremote-signing"
STATE_DIR="${SIGNING_STATE_DIR:-${DEFAULT_STATE_DIR}}"

strip_chain_line() {
  local line="$1"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  line="${line#\"}"
  line="${line%\"}"
  printf '%s' "${line}"
}

read_chains() {
  local file="$1" line stripped
  CHAINS=()
  if [[ ! -f "${file}" ]]; then
    return 0
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    stripped="$(strip_chain_line "${line}")"
    if [[ -n "${stripped}" ]]; then
      CHAINS+=("${stripped}")
    fi
  done < "${file}"
}

restore_keychains() {
  if ! command -v security >/dev/null 2>&1; then
    return 0
  fi
  if [[ -f "${STATE_DIR}/keychains.before" ]]; then
    read_chains "${STATE_DIR}/keychains.before"
    if [[ "${#CHAINS[@]}" -gt 0 ]]; then
      security list-keychains -d user -s "${CHAINS[@]}" >/dev/null 2>&1 || true
    fi
  else
    security list-keychains -d user -s login.keychain-db >/dev/null 2>&1 || \
      security list-keychains -d user -s login.keychain >/dev/null 2>&1 || true
  fi
  if [[ -f "${STATE_DIR}/default.before" ]]; then
    local previous
    previous="$(strip_chain_line "$(cat "${STATE_DIR}/default.before")")"
    if [[ -n "${previous}" ]]; then
      security default-keychain -s "${previous}" >/dev/null 2>&1 || true
    fi
  else
    security default-keychain -s login.keychain-db >/dev/null 2>&1 || \
      security default-keychain -s login.keychain >/dev/null 2>&1 || true
  fi
}

cleanup_keychain() {
  local keychain=""
  if [[ -f "${STATE_DIR}/keychain.path" ]]; then
    keychain="$(cat "${STATE_DIR}/keychain.path")"
  fi
  restore_keychains
  if [[ -n "${keychain}" ]] && command -v security >/dev/null 2>&1; then
    security delete-keychain "${keychain}" >/dev/null 2>&1 || true
  fi
  rm -rf "${STATE_DIR}"
  return 0
}

# Prints Apple Distribution, iPhone Distribution, or iOS Distribution.
# Prints nothing and returns 1 when the text has no distribution identity.
classify_identity() {
  local text="$1"
  if printf '%s\n' "${text}" | grep -q "Apple Distribution"; then
    printf '%s' "Apple Distribution"
    return 0
  fi
  if printf '%s\n' "${text}" | grep -q "iPhone Distribution"; then
    printf '%s' "iPhone Distribution"
    return 0
  fi
  if printf '%s\n' "${text}" | grep -q "iOS Distribution"; then
    printf '%s' "iOS Distribution"
    return 0
  fi
  return 1
}

# Writes decoded PKCS#12 bytes to the path in DECODED_P12.
# Error text never includes the input.
decode_p12() {
  python3 - <<'PY'
import base64
import os
import sys
from pathlib import Path

raw = os.environ.get("DIST_CERT_P12", "")
text = raw.replace("\r\n", "\n").replace("\r", "\n").strip()
compact = "".join(text.split())
destination = Path(os.environ["DECODED_P12"])
if not compact:
    sys.exit("DIST_CERT_P12 is empty.")
pad = (-len(compact)) % 4
try:
    data = base64.b64decode(compact + ("=" * pad), validate=True)
except Exception:
    sys.exit("DIST_CERT_P12 is not valid base64.")
if not data or data[0] != 0x30:
    sys.exit("DIST_CERT_P12 decoded, but it does not look like a PKCS#12 file.")
destination.write_bytes(data)
os.chmod(destination, 0o600)
PY
}

write_password_file() {
  python3 - <<'PY'
import os
from pathlib import Path

password = os.environ.get("DIST_CERT_PASSWORD", "")
if password.endswith("\r\n"):
    password = password[:-2]
elif password.endswith("\n"):
    password = password[:-1]
if password == "":
    raise SystemExit("DIST_CERT_PASSWORD is empty.")
path = Path(os.environ["P12_PASS_PATH"])
path.write_text(password)
os.chmod(path, 0o600)
PY
}

show_safe_error() {
  local label="$1" err_file="$2"
  if [[ -f "${STATE_DIR}/p12.pass" ]] && grep -q -F -f "${STATE_DIR}/p12.pass" "${err_file}"; then
    echo "${label}" >&2
    return 0
  fi
  if [[ -f "${STATE_DIR}/keychain.pass" ]] && grep -q -F -f "${STATE_DIR}/keychain.pass" "${err_file}"; then
    echo "${label}" >&2
    return 0
  fi
  cat "${err_file}" >&2
  echo "${label}" >&2
}

run_security() {
  local label="$1"
  shift
  local err="${STATE_DIR}/security.err"
  if "$@" >"${STATE_DIR}/security.out" 2>"${err}" </dev/null; then
    rm -f "${STATE_DIR}/security.out" "${err}"
    return 0
  fi
  show_safe_error "${label}" "${err}"
  rm -f "${STATE_DIR}/security.out" "${err}"
  return 1
}

publish_env() {
  if [[ -z "${GITHUB_ENV:-}" ]]; then
    return 0
  fi
  if [[ "${STATE_DIR}" != "${DEFAULT_STATE_DIR}" ]]; then
    return 0
  fi
  {
    printf 'SIGNING_KEYCHAIN=%s\n' "${KEYCHAIN}"
    printf 'SIGNING_CERT_DER=%s\n' "${STATE_DIR}/cert.der"
    printf 'SIGNING_IDENTITY=%s\n' "${IDENTITY}"
    printf 'SIGNING_STATE_DIR=%s\n' "${STATE_DIR}"
  } >> "${GITHUB_ENV}"
}

import_certificate() {
  local require_distribution="${1:-1}"
  umask 077
  mkdir -p "${STATE_DIR}"
  chmod 700 "${STATE_DIR}"
  KEYCHAIN="${STATE_DIR}/signing.keychain-db"
  if [[ -z "${DIST_CERT_P12:-}" ]]; then
    echo "Missing GitHub secret DIST_CERT_P12." >&2
    exit 1
  fi
  if [[ -z "${DIST_CERT_PASSWORD:-}" ]]; then
    echo "Missing GitHub secret DIST_CERT_PASSWORD." >&2
    exit 1
  fi
  export DECODED_P12="${STATE_DIR}/cert.p12"
  export P12_PASS_PATH="${STATE_DIR}/p12.pass"
  decode_p12
  write_password_file
  openssl rand -base64 32 | tr -d '\n' > "${STATE_DIR}/keychain.pass"
  chmod 600 "${STATE_DIR}/keychain.pass"

  security list-keychains -d user > "${STATE_DIR}/keychains.before"
  security default-keychain > "${STATE_DIR}/default.before"
  run_security "Could not create the temporary signing keychain." \
    security create-keychain -p "$(cat "${STATE_DIR}/keychain.pass")" "${KEYCHAIN}"
  printf '%s' "${KEYCHAIN}" > "${STATE_DIR}/keychain.path"
  run_security "Could not configure the temporary signing keychain." \
    security set-keychain-settings -lut 21600 "${KEYCHAIN}"
  run_security "Could not unlock the temporary signing keychain." \
    security unlock-keychain -p "$(cat "${STATE_DIR}/keychain.pass")" "${KEYCHAIN}"
  read_chains "${STATE_DIR}/keychains.before"
  if [[ "${#CHAINS[@]}" -eq 0 ]]; then
    run_security "Could not add the temporary signing keychain to the search list." \
      security list-keychains -d user -s "${KEYCHAIN}" login.keychain-db
  else
    run_security "Could not add the temporary signing keychain to the search list." \
      security list-keychains -d user -s "${KEYCHAIN}" "${CHAINS[@]}"
  fi
  run_security "Could not select the temporary signing keychain." \
    security default-keychain -s "${KEYCHAIN}"

  if ! run_security "Could not import the distribution certificate." \
    security import "${STATE_DIR}/cert.p12" \
      -k "${KEYCHAIN}" \
      -P "$(cat "${STATE_DIR}/p12.pass")" \
      -f pkcs12 -A \
      -T /usr/bin/codesign \
      -T /usr/bin/security \
      -T /usr/bin/productbuild; then
    # OpenSSL 3 PKCS#12 uses a cipher macOS security sometimes rejects.
    # Re-export with the legacy algorithms, then import that file.
    if ! openssl pkcs12 \
      -in "${STATE_DIR}/cert.p12" \
      -passin "file:${STATE_DIR}/p12.pass" \
      -passout "file:${STATE_DIR}/p12.pass" \
      -export -legacy \
      -out "${STATE_DIR}/cert-legacy.p12" \
      >/dev/null 2>"${STATE_DIR}/openssl.err"; then
      show_safe_error "Could not import the distribution certificate." "${STATE_DIR}/openssl.err"
      exit 1
    fi
    run_security "Could not import the distribution certificate." \
      security import "${STATE_DIR}/cert-legacy.p12" \
        -k "${KEYCHAIN}" \
        -P "$(cat "${STATE_DIR}/p12.pass")" \
        -f pkcs12 -A \
        -T /usr/bin/codesign \
        -T /usr/bin/security \
        -T /usr/bin/productbuild
  fi
  run_security "Could not allow codesign to use the distribution key." \
    security set-key-partition-list \
      -S apple-tool:,apple:,codesign: \
      -s \
      -k "$(cat "${STATE_DIR}/keychain.pass")" \
      "${KEYCHAIN}"

  # Keychain Access exports use RC2, which OpenSSL 3 reads only with -legacy.
  if ! openssl pkcs12 \
    -in "${STATE_DIR}/cert.p12" \
    -nokeys \
    -passin "file:${STATE_DIR}/p12.pass" \
    -out "${STATE_DIR}/cert.pem" \
    >/dev/null 2>"${STATE_DIR}/openssl.err"; then
    if ! openssl pkcs12 \
      -in "${STATE_DIR}/cert.p12" \
      -nokeys \
      -legacy \
      -passin "file:${STATE_DIR}/p12.pass" \
      -out "${STATE_DIR}/cert.pem" \
      >/dev/null 2>"${STATE_DIR}/openssl.err"; then
      show_safe_error "Could not read the distribution certificate." "${STATE_DIR}/openssl.err"
      exit 1
    fi
  fi
  # A .p12 can carry the leaf plus intermediates. Keep the distribution leaf.
  # The subject is not printed: it contains the team id.
  if ! CERT_PEM="${STATE_DIR}/cert.pem" CERT_DER="${STATE_DIR}/cert.der" python3 - <<'PY'
import os
import subprocess
import sys
from pathlib import Path

pem = Path(os.environ["CERT_PEM"]).read_text()
parts = []
current = []
for line in pem.splitlines(True):
    if "BEGIN CERTIFICATE" in line:
        current = [line]
        continue
    if current:
        current.append(line)
    if "END CERTIFICATE" in line and current:
        parts.append("".join(current))
        current = []
if not parts:
    sys.exit("Could not read the distribution certificate.")
chosen = None
fallback = None
for part in parts:
    rendered = subprocess.run(
        ["openssl", "x509", "-outform", "DER"],
        input=part.encode(),
        capture_output=True,
        check=False,
    )
    if rendered.returncode != 0 or not rendered.stdout:
        continue
    subject = subprocess.run(
        ["openssl", "x509", "-inform", "DER", "-noout", "-subject"],
        input=rendered.stdout,
        capture_output=True,
        check=False,
    )
    label = subject.stdout.decode(errors="replace") if subject.returncode == 0 else ""
    if fallback is None:
        fallback = rendered.stdout
    if "Distribution" in label and chosen is None:
        chosen = rendered.stdout
if chosen is None:
    chosen = fallback
if not chosen:
    sys.exit("Could not read the distribution certificate.")
destination = Path(os.environ["CERT_DER"])
destination.write_bytes(chosen)
os.chmod(destination, 0o600)
PY
  then
    echo "Could not read the distribution certificate." >&2
    exit 1
  fi
  chmod 600 "${STATE_DIR}/cert.der"
  rm -f "${STATE_DIR}/cert.pem" "${STATE_DIR}/cert.p12" "${STATE_DIR}/cert-legacy.p12" \
    "${STATE_DIR}/p12.pass" "${STATE_DIR}/keychain.pass" "${STATE_DIR}/openssl.err"

  local identities=""
  identities="$(security find-identity -p codesigning "${KEYCHAIN}" 2>/dev/null || true)"
  if [[ "${require_distribution}" == "1" ]]; then
    if ! IDENTITY="$(classify_identity "${identities}")"; then
      echo "The distribution certificate did not import into the temporary keychain." >&2
      exit 1
    fi
    printf '%s' "${IDENTITY}" > "${STATE_DIR}/identity"
    publish_env
    echo "Imported the shared distribution certificate into the temporary keychain."
    return 0
  fi
  local certificates=""
  certificates="$(security find-certificate -a "${KEYCHAIN}" 2>/dev/null || true)"
  if [[ -z "${certificates}" ]]; then
    echo "The certificate did not import into the temporary keychain." >&2
    exit 1
  fi
  echo "Imported a certificate into the temporary keychain."
}

self_test() {
  local tmp password b64 out identity fixture
  tmp="$(mktemp -d)"
  password="super-secret-password"
  fixture='1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Distribution: Example (TEAMID1234)"'
  identity="$(classify_identity "${fixture}")"
  if [[ "${identity}" != "Apple Distribution" ]]; then
    echo "self-test failed: Apple Distribution was not classified" >&2
    exit 1
  fi
  if printf '%s' "${identity}" | grep -q "TEAMID1234"; then
    echo "self-test failed: identity classification kept the team id" >&2
    exit 1
  fi
  fixture='1) BBB "iPhone Distribution: Example (TEAMID1234)"'
  identity="$(classify_identity "${fixture}")"
  if [[ "${identity}" != "iPhone Distribution" ]]; then
    echo "self-test failed: iPhone Distribution was not classified" >&2
    exit 1
  fi
  if classify_identity "Developer: Example" >/dev/null; then
    echo "self-test failed: a development identity was accepted" >&2
    exit 1
  fi

  # Invalid input must be rejected without echoing the value.
  if DIST_CERT_P12="not-a-certificate SECRETVALUE" DECODED_P12="${tmp}/bad.p12" decode_p12 2>"${tmp}/err"; then
    echo "self-test failed: invalid certificate input was accepted" >&2
    exit 1
  fi
  if grep -q "SECRETVALUE" "${tmp}/err"; then
    echo "self-test failed: decode error included the secret" >&2
    exit 1
  fi
  echo "p12 decode rejected invalid input"

  openssl req -x509 -newkey rsa:2048 -keyout "${tmp}/key.pem" -out "${tmp}/cert.pem" \
    -days 1 -nodes -subj "/CN=Self Test Distribution" >/dev/null 2>&1
  printf '%s' "${password}" > "${tmp}/pass"
  chmod 600 "${tmp}/pass"
  if ! openssl pkcs12 -export \
    -inkey "${tmp}/key.pem" -in "${tmp}/cert.pem" \
    -out "${tmp}/cert.p12" \
    -passout "file:${tmp}/pass" \
    -legacy >/dev/null 2>&1; then
    openssl pkcs12 -export \
      -inkey "${tmp}/key.pem" -in "${tmp}/cert.pem" \
      -out "${tmp}/cert.p12" \
      -passout "file:${tmp}/pass" >/dev/null
  fi
  b64="$(base64 < "${tmp}/cert.p12" | tr -d '\n')"
  if DECODED_P12="${tmp}/decoded.p12" DIST_CERT_P12="${b64}" decode_p12; then
    if ! cmp -s "${tmp}/cert.p12" "${tmp}/decoded.p12"; then
      echo "self-test failed: decoded p12 did not match" >&2
      exit 1
    fi
  else
    echo "self-test failed: valid p12 was rejected" >&2
    exit 1
  fi
  echo "p12 decode ok"

  if ! command -v security >/dev/null 2>&1; then
    rm -rf "${tmp}"
    echo "keychain import self-test skipped: security is not available"
    exit 0
  fi

  local state="${tmp}/state" default_before default_after
  default_before="$(security default-keychain || true)"
  set +e
  out="$(
    env -u GITHUB_ENV \
      SIGNING_STATE_DIR="${state}" \
      DIST_CERT_P12="${b64}" \
      DIST_CERT_PASSWORD="${password}" \
      bash "${SCRIPT_DIR}/import-dist-cert.sh" --self-test-import 2>&1
  )"
  local import_status=$?
  set -e
  if printf '%s' "${out}" | grep -q -F "${password}"; then
    echo "self-test failed: import printed the password" >&2
    SIGNING_STATE_DIR="${state}" bash "${SCRIPT_DIR}/import-dist-cert.sh" --cleanup || true
    exit 1
  fi
  if printf '%s' "${out}" | grep -q -F "${b64}"; then
    echo "self-test failed: import printed the certificate" >&2
    SIGNING_STATE_DIR="${state}" bash "${SCRIPT_DIR}/import-dist-cert.sh" --cleanup || true
    exit 1
  fi
  if [[ "${import_status}" -ne 0 ]]; then
    local redacted="${out//${password}/REDACTED}"
    redacted="${redacted//${b64}/REDACTED}"
    printf '%s\n' "${redacted}" >&2
    echo "self-test failed: import did not succeed" >&2
    SIGNING_STATE_DIR="${state}" bash "${SCRIPT_DIR}/import-dist-cert.sh" --cleanup || true
    exit 1
  fi
  if [[ ! -f "${state}/keychain.path" ]]; then
    echo "self-test failed: keychain path was not recorded" >&2
    exit 1
  fi
  local keychain
  keychain="$(cat "${state}/keychain.path")"
  if ! security list-keychains -d user | grep -q -F "${keychain}"; then
    echo "self-test failed: keychain is not on the search list" >&2
    SIGNING_STATE_DIR="${state}" bash "${SCRIPT_DIR}/import-dist-cert.sh" --cleanup || true
    exit 1
  fi
  SIGNING_STATE_DIR="${state}" bash "${SCRIPT_DIR}/import-dist-cert.sh" --cleanup
  if [[ -d "${state}" ]]; then
    echo "self-test failed: cleanup left the signing directory" >&2
    exit 1
  fi
  if security list-keychains -d user | grep -q -F "${keychain}"; then
    echo "self-test failed: cleanup left the keychain on the search list" >&2
    exit 1
  fi
  default_after="$(security default-keychain || true)"
  if [[ "${default_before}" != "${default_after}" ]]; then
    echo "self-test failed: cleanup did not restore the default keychain" >&2
    exit 1
  fi
  rm -rf "${tmp}"
  echo "keychain import ok"
}

if [[ "${1:-}" == "--cleanup" ]]; then
  cleanup_keychain
  exit 0
fi

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit 0
fi

if [[ "${1:-}" == "--self-test-import" ]]; then
  import_certificate 0
  exit 0
fi

if [[ "${1:-}" == "--import" || -z "${1:-}" ]]; then
  import_certificate 1
  exit 0
fi

echo "Usage: import-dist-cert.sh [--import | --cleanup | --self-test]" >&2
exit 1
