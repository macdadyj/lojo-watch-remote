#!/usr/bin/env bash
# Runs the iPhone chat UI tests. TestFlight waits for this script.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

UDID="$(python3 - <<'PY'
import json, subprocess
raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True)
data = json.loads(raw)
chosen = ""
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device.get("name", "").startswith("iPhone") and device.get("isAvailable", True):
            chosen = device["udid"]
if not chosen:
    raise SystemExit("No available iPhone simulator")
print(chosen)
PY
)"

mkdir -p build/phone-ui-screenshots
run_phone() {
  xcodebuild test \
    -project WatchRemote.xcodeproj \
    -scheme WatchRemoteUI \
    -destination "platform=iOS Simulator,id=${UDID}" \
    -clonedSourcePackagesDirPath build/SourcePackages \
    -derivedDataPath build/DerivedDataUI \
    -resultBundlePath build/phone-ui-screenshots/PhoneChat.xcresult \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="-" \
    DEVELOPMENT_TEAM=""
}

set +e
run_phone
status=$?
set -e
if [[ "${status}" -ne 0 ]]; then
  echo "Phone UI tests failed (status ${status}). Rebooting the simulator and trying once more." >&2
  xcrun simctl shutdown "${UDID}" || true
  sleep 2
  xcrun simctl boot "${UDID}" || true
  xcrun simctl bootstatus "${UDID}" -b || true
  rm -rf build/phone-ui-screenshots/PhoneChat.xcresult
  run_phone
fi
