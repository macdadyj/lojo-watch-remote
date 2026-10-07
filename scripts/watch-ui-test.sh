#!/usr/bin/env bash
# Runs the Watch UI scaffold on a 41/42 mm-class simulator and a 45/49 mm-class simulator.
# Screenshots land in build/watch-ui-screenshots. The microphone is not used.
# Bash 3.2 safe: GitHub's macOS runners still ship that as /bin/bash.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

if [[ "${1:-}" == "--self-test" ]]; then
  python3 "${ROOT}/scripts/watch_ui_devices.py" --self-test
  python3 "${ROOT}/scripts/make-speech-fixtures.py" --check
  python3 "${ROOT}/scripts/watch_ui_vision.py" --self-test
  python3 -m py_compile "${ROOT}/scripts/watch_ui_devices.py" "${ROOT}/scripts/make-speech-fixtures.py" "${ROOT}/scripts/watch_ui_vision.py"
  echo "watch ui test script: ok"
  exit 0
fi

OUT="${ROOT}/build/watch-ui-screenshots"
RESULT="${ROOT}/build/watch-ui-results"
mkdir -p "${OUT}" "${RESULT}"

python3 "${ROOT}/scripts/make-speech-fixtures.py"

SMALL_UDID=""
SMALL_NAME=""
LARGE_UDID=""
LARGE_NAME=""
PHONE_UDID=""
PHONE_NAME=""
while IFS="$(printf '\t')" read -r kind udid name; do
  case "${kind}" in
    small)
      SMALL_UDID="${udid}"
      SMALL_NAME="${name}"
      ;;
    large)
      LARGE_UDID="${udid}"
      LARGE_NAME="${name}"
      ;;
    phone)
      PHONE_UDID="${udid}"
      PHONE_NAME="${name}"
      ;;
    *)
      echo "Unknown simulator row: ${kind}" >&2
      exit 1
      ;;
  esac
done <<EOF
$(python3 "${ROOT}/scripts/watch_ui_devices.py")
EOF

echo "simulator small: ${SMALL_NAME} ${SMALL_UDID}"
echo "simulator large: ${LARGE_NAME} ${LARGE_UDID}"
echo "simulator phone: ${PHONE_NAME} ${PHONE_UDID}"

xcrun simctl boot "${PHONE_UDID}" || true
xcrun simctl bootstatus "${PHONE_UDID}" -b

export_shots() {
  local result="$1"
  local dest="$2"
  mkdir -p "${dest}"
  if xcrun xcresulttool export attachments --path "${result}" --output-path "${dest}"; then
    return 0
  fi
  echo "xcresulttool export attachments failed for ${result}. Trying the legacy exporter." >&2
  if xcrun xcresulttool export --type directory --path "${result}" --output-path "${dest}" --legacy; then
    return 0
  fi
  find "${result}" -name '*.png' -exec cp {} "${dest}/" \; || true
}

run_class() {
  local kind="$1"
  local udid="$2"
  local label="$3"
  local result="${RESULT}/${kind}.xcresult"
  local log="${RESULT}/${kind}.log"
  local status
  rm -rf "${result}"
  xcrun simctl boot "${udid}" || true
  xcrun simctl bootstatus "${udid}" -b || true
  xcrun simctl pair "${udid}" "${PHONE_UDID}" || true
  set +e
  xcodebuild test \
    -project WatchRemote.xcodeproj \
    -scheme WatchRemoteWatch \
    -destination "platform=watchOS Simulator,id=${udid}" \
    -only-testing:WatchRemoteWatchUITests \
    -resultBundlePath "${result}" \
    -clonedSourcePackagesDirPath "${ROOT}/build/SourcePackages" \
    -derivedDataPath "${ROOT}/build/DerivedDataWatch" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="-" \
    DEVELOPMENT_TEAM="" \
    | tee "${log}"
  status=${PIPESTATUS[0]}
  set -e
  if [[ "${status}" -ne 0 ]]; then
    echo "Watch UI test failed on ${kind} (${label}). Rebooting the simulator and trying once more." >&2
    xcrun simctl shutdown "${udid}" || true
    sleep 2
    xcrun simctl boot "${udid}" || true
    xcrun simctl bootstatus "${udid}" -b || true
    xcrun simctl pair "${udid}" "${PHONE_UDID}" || true
    rm -rf "${result}"
    set +e
    xcodebuild test \
      -project WatchRemote.xcodeproj \
      -scheme WatchRemoteWatch \
      -destination "platform=watchOS Simulator,id=${udid}" \
      -only-testing:WatchRemoteWatchUITests \
      -resultBundlePath "${result}" \
      -clonedSourcePackagesDirPath "${ROOT}/build/SourcePackages" \
      -derivedDataPath "${ROOT}/build/DerivedDataWatch" \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      CODE_SIGN_IDENTITY="-" \
      DEVELOPMENT_TEAM="" \
      | tee -a "${log}"
    status=${PIPESTATUS[0]}
    set -e
  fi
  export_shots "${result}" "${OUT}/${kind}" || true
  python3 - "${OUT}/${kind}" <<'PY'
import json
import sys
from pathlib import Path
dest = Path(sys.argv[1])
manifest = dest / "manifest.json"
if not manifest.is_file():
    raise SystemExit(0)
groups = json.loads(manifest.read_text(encoding="utf-8"))
for group in groups:
    for item in group.get("attachments", []):
        exported = item.get("exportedFileName") or ""
        suggested = item.get("suggestedHumanReadableName") or ""
        src = dest / exported
        stem = suggested.split("_0_")[0]
        if not stem or not src.is_file():
            continue
        if not stem.endswith(".png"):
            stem += ".png"
        target = dest / stem
        if target != src:
            src.replace(target)
            item["exportedFileName"] = stem
manifest.write_text(json.dumps(groups, indent=2) + "\n", encoding="utf-8")
PY
  xcrun simctl io "${udid}" screenshot "${OUT}/${kind}/simulator-${kind}.png" || true
  if [[ "${status}" -ne 0 ]]; then
    echo "Watch UI test failed on ${kind} (${label})." >&2
    return "${status}"
  fi
  if ! find "${OUT}/${kind}" -name '*.png' -size +100c | grep -q .; then
    echo "No screenshots were written for ${kind}." >&2
    return 1
  fi
}

run_class small "${SMALL_UDID}" "${SMALL_NAME}"
run_class large "${LARGE_UDID}" "${LARGE_NAME}"
python3 "${ROOT}/scripts/watch_ui_vision.py" "${OUT}"
echo "watch ui tests: ok"
