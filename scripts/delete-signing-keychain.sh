#!/usr/bin/env bash
# Delete the temporary signing keychain and the decoded distribution certificate.
# Safe to run more than once. Does not print secret values.
set -euo pipefail

base="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
keychain="${base}/watchremote-signing.keychain-db"
secret_dir="${base}/watchremote-signing"

if command -v security >/dev/null 2>&1; then
  listed="$(security list-keychains -d user 2>/dev/null || true)"
  if printf '%s\n' "${listed}" | grep -q "watchremote-signing.keychain-db"; then
    security delete-keychain "${keychain}" >/dev/null 2>&1 || true
    remaining="$(printf '%s\n' "${listed}" | sed 's/^[[:space:]]*"//;s/"[[:space:]]*$//' | grep -v 'watchremote-signing.keychain-db' || true)"
    if [[ -n "${remaining}" ]]; then
      # shellcheck disable=SC2086
      security list-keychains -d user -s ${remaining} >/dev/null 2>&1 || true
    fi
    security default-keychain -s login.keychain-db >/dev/null 2>&1 || true
  fi
fi
rm -f "${keychain}"
rm -rf "${secret_dir}"
