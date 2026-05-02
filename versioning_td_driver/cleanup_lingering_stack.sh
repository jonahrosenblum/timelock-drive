#!/usr/bin/env bash
set -u

# Kills lingering gatekeeper/driver processes and destroys lingering bdus block devices.
# Usage:
#   ./cleanup_lingering_stack.sh
#   ./cleanup_lingering_stack.sh --purge-nonblock
#
# --purge-nonblock: also removes non-block /dev/bdus-* paths (requires sudo).

PURGE_NONBLOCK=0
if [[ "${1:-}" == "--purge-nonblock" ]]; then
  PURGE_NONBLOCK=1
fi

PROC_PATTERN="gatekeeper/main-rust/target/release/main|/bin/versioning_td_driver|versioning_td_driver$|sudo ./bin/versioning_td_driver"

echo "[cleanup] Scanning for lingering processes..."
pids="$(pgrep -f "$PROC_PATTERN" || true)"
if [[ -n "$pids" ]]; then
  echo "[cleanup] Found process IDs: $pids"
  sudo kill $pids >/dev/null 2>&1 || true
  sleep 1
  still="$(pgrep -f "$PROC_PATTERN" || true)"
  if [[ -n "$still" ]]; then
    echo "[cleanup] Forcing process IDs: $still"
    sudo kill -9 $still >/dev/null 2>&1 || true
  fi
else
  echo "[cleanup] No matching processes found."
fi

echo "[cleanup] Scanning /dev/bdus-* entries..."
found_any=0
for dev in /dev/bdus-*; do
  [[ "$dev" == "/dev/bdus-*" ]] && break
  [[ "$dev" == "/dev/bdus-control" ]] && continue
  found_any=1

  if [[ -b "$dev" ]]; then
    echo "[cleanup] Destroying block device: $dev"
    sudo bdus destroy --no-flush "$dev" >/dev/null 2>&1 || true
    if [[ -b "$dev" ]]; then
      echo "[cleanup] Retry destroy (with flush): $dev"
      sudo bdus destroy "$dev" >/dev/null 2>&1 || true
    fi
  else
    echo "[cleanup] Found non-block path: $dev"
    if [[ "$PURGE_NONBLOCK" -eq 1 ]]; then
      echo "[cleanup] Removing non-block path: $dev"
      sudo rm -f "$dev" >/dev/null 2>&1 || true
    fi
  fi
done

if [[ "$found_any" -eq 0 ]]; then
  echo "[cleanup] No /dev/bdus-* entries besides control."
fi

echo "[cleanup] Final process check:"
pgrep -af "$PROC_PATTERN" || echo "[cleanup] None"

echo "[cleanup] Final /dev/bdus-* listing:"
ls /dev/bdus-* 2>/dev/null || echo "[cleanup] None"
