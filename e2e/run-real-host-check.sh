#!/usr/bin/env bash
# Real end-to-end check on the computer the iPhone and the Watch talk to.
#
#   e2e/run-real-host-check.sh            install this checkout's host code, restart, run every scenario
#   e2e/run-real-host-check.sh --no-install [real_host_check.py options]
#   e2e/run-real-host-check.sh --only watch-alone
#
# watch and watch-alone are the same phone-free path: a Watch client polls the paired relay,
# sends a prompt, and checks that the reply comes back after the prompt. No iPhone is involved.
# fresh is that path with no iPhone key yet: the Watch still gets an auto-approved answer, then
# the computer authorizes a new key over the relay. The test key is removed afterward.
#
# Installs host/agentdoor.py, outbound.py, pairing.py, qrcodegen.py, relaybox.py, miniws.py,
# watch-remote-agent, and watch-remote-outbound into ~/.local/bin (the old copies go to a dated
# backup folder), restarts
# the watch-remote-agent and watch-remote-outbound user services, waits for the door on
# 127.0.0.1:2419, then runs e2e/real_host_check.py against real Grok Build and the paired relay.
# Restarting watch-remote-agent restarts `grok agent serve`, which ends any turn running now.
#
# Exit status is real_host_check.py's: 0 only when every scenario passed.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
bin_dir="${HOME}/.local/bin"
install_code=1
args=()
for arg in "$@"; do
  case "${arg}" in
    --no-install) install_code=0 ;;
    *) args+=("${arg}") ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required." >&2
  exit 2
fi

if [[ "${install_code}" == 1 ]]; then
  backup="${bin_dir}/watch-remote-backup-$(date +%Y%m%d-%H%M%S)"
  install -d -m 755 "${bin_dir}" "${backup}"
  for name in agentdoor.py outbound.py pairing.py qrcodegen.py relaybox.py miniws.py watch-remote-agent watch-remote-outbound; do
    if [[ -f "${bin_dir}/${name}" ]]; then
      cp -p "${bin_dir}/${name}" "${backup}/${name}"
    fi
  done
  install -m 644 "${root}/host/agentdoor.py" "${root}/host/outbound.py" "${root}/host/pairing.py" "${root}/host/qrcodegen.py" "${root}/host/relaybox.py" "${root}/host/miniws.py" "${bin_dir}/"
  install -m 755 "${root}/host/watch-remote-agent" "${root}/host/watch-remote-outbound" "${bin_dir}/"
  echo "Installed this checkout's host code into ${bin_dir}. Previous copies: ${backup}"
  echo "To put them back: cp -p ${backup}/* ${bin_dir}/ && systemctl --user restart watch-remote-agent watch-remote-outbound"

  if command -v systemctl >/dev/null 2>&1 && systemctl --user cat watch-remote-agent.service >/dev/null 2>&1; then
    systemctl --user restart watch-remote-agent.service
    if systemctl --user cat watch-remote-outbound.service >/dev/null 2>&1; then
      systemctl --user restart watch-remote-outbound.service
    fi
  else
    echo "No watch-remote-agent user service here. Restart the agent door and the outbound service yourself, then rerun with --no-install." >&2
    exit 2
  fi
fi

port="${WATCHREMOTE_DOOR_PORT:-2419}"
for _ in $(seq 1 60); do
  if python3 -c "import socket,sys; socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=1).close()" "${port}" 2>/dev/null; then
    break
  fi
  sleep 0.5
done

exec python3 "${root}/e2e/real_host_check.py" "${args[@]+"${args[@]}"}"
