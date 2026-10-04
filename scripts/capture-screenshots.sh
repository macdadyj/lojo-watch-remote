#!/usr/bin/env bash
# Builds are already in build/DerivedData. Boots an iPhone and a paired Watch,
# installs the embedded watch app from Watch/, and writes PNGs to build/screenshots.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/screenshots"
mkdir -p "$OUT"

APP="$(find "$ROOT/build/DerivedData" -path '*Debug-iphonesimulator*' -name 'WatchRemote.app' -type d | head -1 || true)"
if [[ -z "${APP}" || ! -d "${APP}" ]]; then
  echo "WatchRemote.app was not found under build/DerivedData. Run the test build first." >&2
  exit 1
fi
python3 "${ROOT}/scripts/patch-watch-embed.py" --check-app "${APP}"
WATCH="${APP}/Watch/WatchRemoteWatch.app"

pick_device() {
  local family="$1"
  python3 - "$family" <<'PY'
import json, subprocess, sys
family = sys.argv[1]
raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True)
data = json.loads(raw)
best = ""
for runtime, devices in data.get("devices", {}).items():
    if family == "iPhone" and "iOS" not in runtime:
        continue
    if family == "Watch" and "watchOS" not in runtime:
        continue
    for device in devices:
        name = device.get("name", "")
        if family == "iPhone" and not name.startswith("iPhone"):
            continue
        if family == "Watch" and "Apple Watch" not in name:
            continue
        if not device.get("isAvailable", True):
            continue
        best = device["udid"] + "\t" + name
print(best)
PY
}

WATCH_SIM="$(pick_device Watch)"
if [[ -z "${PHONE_UDID:-}" ]]; then
  PHONE="$(pick_device iPhone)"
  if [[ -z "${PHONE}" ]]; then
    echo "Need an available iPhone simulator." >&2
    xcrun simctl list devices available >&2
    exit 1
  fi
  PHONE_UDID="${PHONE%%$'\t'*}"
  echo "iPhone ${PHONE}"
else
  echo "iPhone ${PHONE_UDID}"
fi
if [[ -z "${WATCH_SIM}" ]]; then
  echo "Need an available Apple Watch simulator." >&2
  xcrun simctl list devices available >&2
  exit 1
fi
WATCH_UDID="${WATCH_SIM%%$'\t'*}"
echo "Watch ${WATCH_SIM}"

xcrun simctl boot "${PHONE_UDID}" || true
xcrun simctl boot "${WATCH_UDID}" || true
xcrun simctl bootstatus "${PHONE_UDID}" -b
xcrun simctl bootstatus "${WATCH_UDID}" -b || true
xcrun simctl pair "${WATCH_UDID}" "${PHONE_UDID}" || true

xcrun simctl status_bar "${PHONE_UDID}" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularMode active --cellularBars 4 || true
xcrun simctl status_bar "${WATCH_UDID}" override --time "9:41" --batteryState charged --batteryLevel 100 >/dev/null 2>&1 || true

xcrun simctl install "${PHONE_UDID}" "${APP}"
xcrun simctl install "${WATCH_UDID}" "${WATCH}"

shoot() {
  local udid="$1"
  local bundle="$2"
  local screen="$3"
  local appearance="$4"
  local file="$5"
  local attempt
  for attempt in 1 2 3; do
    xcrun simctl terminate "${udid}" "${bundle}" >/dev/null 2>&1 || true
    sleep 2
    if SIMCTL_CHILD_WATCHREMOTE_SCREEN="${screen}" \
      SIMCTL_CHILD_WATCHREMOTE_APPEARANCE="${appearance}" \
      xcrun simctl launch "${udid}" "${bundle}" -WatchRemoteScreen "${screen}" -WatchRemoteAppearance "${appearance}"; then
      sleep 4
      xcrun simctl io "${udid}" screenshot "${OUT}/${file}"
      echo "wrote ${file}"
      return 0
    fi
    echo "Launch attempt ${attempt} failed for ${bundle} screen ${screen}." >&2
    sleep 3
  done
  if [[ "${bundle}" == *.watchkitapp ]]; then
    echo "Rebooting the Watch simulator before another launch of ${screen}." >&2
    xcrun simctl shutdown "${udid}" || true
    sleep 2
    xcrun simctl boot "${udid}" || true
    xcrun simctl bootstatus "${udid}" -b || true
    sleep 2
    if SIMCTL_CHILD_WATCHREMOTE_SCREEN="${screen}" \
      SIMCTL_CHILD_WATCHREMOTE_APPEARANCE="${appearance}" \
      xcrun simctl launch "${udid}" "${bundle}" -WatchRemoteScreen "${screen}" -WatchRemoteAppearance "${appearance}"; then
      sleep 4
      xcrun simctl io "${udid}" screenshot "${OUT}/${file}"
      echo "wrote ${file}"
      return 0
    fi
  fi
  echo "Launch failed for ${bundle} screen ${screen}." >&2
  xcrun simctl spawn "${udid}" log show --style compact --last 2m 2>/dev/null | tail -n 60 >&2 || true
  exit 1
}

# Manual and main runs skip the extra sizes and states. Pull requests keep every shot below.
if [[ "${WATCHREMOTE_SCREENSHOTS:-full}" == "dispatch" ]]; then
  shoot "${PHONE_UDID}" com.lojo.WatchRemote sessions dark iphone-sessions-dark.png
  shoot "${PHONE_UDID}" com.lojo.WatchRemote session dark iphone-session-dark.png
  shoot "${PHONE_UDID}" com.lojo.WatchRemote compose dark iphone-compose-dark.png
  shoot "${WATCH_UDID}" com.lojo.WatchRemote.watchkitapp compose dark watch-compose.png
  shoot "${WATCH_UDID}" com.lojo.WatchRemote.watchkitapp sessions dark watch-sessions.png
  shoot "${WATCH_UDID}" com.lojo.WatchRemote.watchkitapp session dark watch-session.png
  exit 0
fi

shoot "${PHONE_UDID}" com.lojo.WatchRemote sessions dark iphone-sessions-dark.png
shoot "${PHONE_UDID}" com.lojo.WatchRemote session dark iphone-session-dark.png
shoot "${PHONE_UDID}" com.lojo.WatchRemote hosts dark iphone-hosts-dark.png
shoot "${PHONE_UDID}" com.lojo.WatchRemote compose dark iphone-compose-dark.png
shoot "${PHONE_UDID}" com.lojo.WatchRemote settings dark iphone-settings-dark.png
shoot "${PHONE_UDID}" com.lojo.WatchRemote sessions light iphone-sessions-light.png
shoot "${PHONE_UDID}" com.lojo.WatchRemote empty dark iphone-empty-dark.png
shoot "${PHONE_UDID}" com.lojo.WatchRemote offline dark iphone-offline-dark.png
shoot "${PHONE_UDID}" com.lojo.WatchRemote error dark iphone-error-dark.png
shoot "${PHONE_UDID}" com.lojo.WatchRemote long dark iphone-long-dark.png

xcrun simctl ui "${PHONE_UDID}" content_size accessibility-extra-large
shoot "${PHONE_UDID}" com.lojo.WatchRemote long dark iphone-long-accessibility.png
xcrun simctl ui "${PHONE_UDID}" content_size large || true

# Compose is the launch the Watch simulator refuses after the other shots.
# Take it first, while the device is freshly booted.
shoot "${WATCH_UDID}" com.lojo.WatchRemote.watchkitapp compose dark watch-compose.png
shoot "${WATCH_UDID}" com.lojo.WatchRemote.watchkitapp sessions dark watch-sessions.png
shoot "${WATCH_UDID}" com.lojo.WatchRemote.watchkitapp session dark watch-session.png
shoot "${WATCH_UDID}" com.lojo.WatchRemote.watchkitapp empty dark watch-empty.png
shoot "${WATCH_UDID}" com.lojo.WatchRemote.watchkitapp offline dark watch-offline.png
shoot "${WATCH_UDID}" com.lojo.WatchRemote.watchkitapp long dark watch-long.png
xcrun simctl ui "${WATCH_UDID}" appearance light || true
shoot "${WATCH_UDID}" com.lojo.WatchRemote.watchkitapp sessions light watch-sessions-light.png
xcrun simctl ui "${WATCH_UDID}" appearance dark || true

OTHER_WATCH="$(python3 - "${WATCH_UDID}" <<'PY'
import json, re, subprocess, sys
current = sys.argv[1]
raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True)
data = json.loads(raw)
rows = []
for runtime, devices in data.get("devices", {}).items():
    if "watchOS" not in runtime:
        continue
    for device in devices:
        name = device.get("name", "")
        if "Apple Watch" not in name or not device.get("isAvailable", True):
            continue
        match = re.search(r"(\d+)\s*mm", name)
        if not match:
            continue
        rows.append((int(match.group(1)), device["udid"], name))
if len(rows) < 2:
    raise SystemExit(0)
rows.sort()
small, large = rows[0], rows[-1]
chosen = large if current == small[1] else small
if chosen[1] == current:
    raise SystemExit(0)
print(chosen[1] + "\t" + chosen[2])
PY
)"
if [[ -n "${OTHER_WATCH}" ]]; then
  OTHER_UDID="${OTHER_WATCH%%$'\t'*}"
  echo "Other Watch ${OTHER_WATCH}"
  xcrun simctl boot "${OTHER_UDID}" || true
  xcrun simctl bootstatus "${OTHER_UDID}" -b || true
  xcrun simctl pair "${OTHER_UDID}" "${PHONE_UDID}" || true
  xcrun simctl install "${OTHER_UDID}" "${WATCH}"
  shoot "${OTHER_UDID}" com.lojo.WatchRemote.watchkitapp sessions dark watch-sessions-other-size.png
fi
