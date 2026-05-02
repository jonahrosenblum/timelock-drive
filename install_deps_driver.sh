#!/usr/bin/env bash
# install_deps_driver.sh
#
# Installs all dependencies required to build the Timelock Drive versioning
# driver (versioning_td_driver) and the shared library on Ubuntu 20.04.
#
# Run as root or with sudo.  Safe to re-run; individual steps are idempotent.
#
# Dependencies installed:
#   - build-essential   (gcc 9, make, etc.)
#   - linux-headers     (matching the running kernel, for kbdus kmodule)
#   - e2fsprogs         (mkfs.ext4, e2fsck – used by driver tests)
#   - libbdus / kbdus   (block-device userspace framework, built from source)
#
# bdus source: https://github.com/joydddd/bdus.git
# The script clones bdus into a sibling directory (../bdus) if it is not
# already present, then builds and installs the library, header, kernel
# module, and the `bdus` management command.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BDUS_DIR="${SCRIPT_DIR}/bdus"

# ── helpers ──────────────────────────────────────────────────────────────────

info()  { echo "[info]  $*"; }
die()   { echo "[error] $*" >&2; exit 1; }

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        die "This script must be run as root (use sudo)."
    fi
}

# ── 0. pre-flight ─────────────────────────────────────────────────────────────

require_root

KERNEL_RELEASE="$(uname -r)"
info "Running on kernel ${KERNEL_RELEASE}"

# ── 1. apt packages ───────────────────────────────────────────────────────────

info "Updating apt package lists..."
apt-get update -qq

info "Installing build-essential, linux-headers, e2fsprogs..."
apt-get install -y \
    build-essential \
    "linux-headers-${KERNEL_RELEASE}" \
    e2fsprogs \
    git

# ── 2. bdus ───────────────────────────────────────────────────────────────────

info "Updating git submodule for bdus..."
git -C "${SCRIPT_DIR}" submodule update --init -- bdus

info "Building bdus (kbdus kernel module + libbdus + bdus command)..."
make -C "${BDUS_DIR}" KBDUS_KDIR="/lib/modules/${KERNEL_RELEASE}/build" clean
make -C "${BDUS_DIR}" KBDUS_KDIR="/lib/modules/${KERNEL_RELEASE}/build"

info "Installing bdus..."
make -C "${BDUS_DIR}" KBDUS_KDIR="/lib/modules/${KERNEL_RELEASE}/build" install

info "Loading kbdus kernel module..."
modprobe kbdus || true    # non-fatal; may already be loaded

# ── 3. verify ────────────────────────────────────────────────────────────────

info "Verifying libbdus.so is visible to the linker..."
ldconfig -p | grep libbdus > /dev/null \
    || die "libbdus.so was installed but ldconfig cannot find it. Check /usr/local/lib."

info "Verifying bdus header..."
[[ -f /usr/local/include/bdus.h ]] \
    || die "bdus.h not found at /usr/local/include/bdus.h"

info "Verifying kbdus module..."
lsmod | grep -q kbdus \
    || die "kbdus module is not loaded after install."

# ── done ─────────────────────────────────────────────────────────────────────

info ""
info "All driver dependencies installed successfully."
info "You can now build the driver:"
info "  cd ${SCRIPT_DIR}/versioning_td_driver && make"
