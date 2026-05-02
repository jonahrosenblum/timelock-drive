#!/usr/bin/env bash
set -euo pipefail

# Startup helper: ensure /dev/bdus-control exists for BDUS user-space tools.
# Manual command discussed during debugging:
#   sudo mknod -m 0660 /dev/bdus-control c 503 0
# This script auto-discovers major:minor from sysfs when available.

SYSFS_DEV="/sys/class/bdus-control/bdus-control/dev"
DEVNODE="/dev/bdus-control"

if [[ ! -e "$SYSFS_DEV" ]]; then
    echo "[bdus_startup] Missing $SYSFS_DEV. Is kbdus loaded?"
    echo "[bdus_startup] Try: sudo modprobe kbdus"
    exit 1
fi

if [[ -e "$DEVNODE" ]]; then
    echo "[bdus_startup] $DEVNODE already exists"
    exit 0
fi

major_minor="$(cat "$SYSFS_DEV")"
major="${major_minor%%:*}"
minor="${major_minor##*:}"

sudo mknod -m 0660 "$DEVNODE" c "$major" "$minor"
echo "[bdus_startup] Created $DEVNODE with major:minor ${major}:${minor}"
