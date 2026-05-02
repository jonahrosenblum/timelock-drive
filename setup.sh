#!/usr/bin/env bash
# setup.sh
#
# One-shot setup for Timelock Drive on Ubuntu 20.04.
# Installs all dependencies, builds the driver and gatekeeper, and
# optionally initialises RAM-backed block devices for testing.
#
# Usage:
#   sudo -E ./setup.sh [--ramdisk] [--ramdisk-dev-mode] [--skip-verify] [--help]
#
# Options:
#   --ramdisk          After building, set up a 10 GiB RAM disk at /dev/ram0
#                      (requires ~10 GiB of free RAM).
#   --ramdisk-dev-mode After building, set up a 1 GiB RAM disk instead.
#                      Useful for quick smoke tests on RAM-constrained machines.
#   --skip-verify      Skip the Dafny verification step (make build instead of
#                      make all).  Speeds up the build significantly.
#   --help             Print this help and exit.
#
# The script must be run as root (sudo -E preserves the user env so that
# rustup installs under your home directory, not /root).
#
# After completion, running the full stack looks like:
#
#   # Terminal 1 – gatekeeper
#   source /tmp/td_ramdisk.env          # sets GK_DISK_PATH
#   sudo -E ./gatekeeper/gatekeeper/main-rust/target/release/main \
#       --timelockdrive --ipc
#
#   # Terminal 2 – driver
#   sudo ./versioning_td_driver/bin/versioning_td_driver --ipc

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── defaults ─────────────────────────────────────────────────────────────────
SETUP_RAMDISK=false
RAMDISK_DEV_MODE=false
SKIP_VERIFY=false

DAFNY_VERSION="4.10.0"
DAFNY_ARCHIVE="dafny-${DAFNY_VERSION}-x64-ubuntu-20.04.zip"
DAFNY_URL="https://github.com/dafny-lang/dafny/releases/download/v${DAFNY_VERSION}/${DAFNY_ARCHIVE}"
DAFNY_INSTALL_DIR="/opt/dafny"
DOTNET_SDK_VERSION="8.0"

# ── arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ramdisk)          SETUP_RAMDISK=true;                        shift ;;
        --ramdisk-dev-mode) SETUP_RAMDISK=true; RAMDISK_DEV_MODE=true; shift ;;
        --skip-verify)      SKIP_VERIFY=true;                          shift ;;
        --help)
            sed -n '/^# Usage:/,/^[^#]/{ /^#/s/^# \{0,1\}//p }' "$0"
            exit 0
            ;;
        *) echo "[setup] Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── helpers ──────────────────────────────────────────────────────────────────
info()    { echo "[setup] $*"; }
section() { echo; echo "[setup] ══════ $* ══════"; }
die()     { echo "[setup] ERROR: $*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || die "Run as root: sudo -E ./setup.sh"

SUDO_USER="${SUDO_USER:-${USER}}"
SUDO_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
info "Non-root user: ${SUDO_USER} (home: ${SUDO_HOME})"

as_user() {
    if [[ "${SUDO_USER}" == "root" ]]; then
        "$@"
    else
        sudo -u "${SUDO_USER}" -H env HOME="${SUDO_HOME}" \
             PATH="${SUDO_HOME}/.cargo/bin:${PATH}" "$@"
    fi
}

# ── step 0: git submodules ────────────────────────────────────────────────────

section "Git submodules"
info "Initialising submodules (bdus)..."
as_user git -C "${SCRIPT_DIR}" submodule update --init --recursive

# ── step 1: apt packages ─────────────────────────────────────────────────────

section "APT packages"
apt-get update -qq
apt-get install -y \
    build-essential \
    "linux-headers-$(uname -r)" \
    e2fsprogs \
    git \
    wget \
    curl \
    unzip \
    apt-transport-https

# ── step 2: .NET SDK 8.0 ─────────────────────────────────────────────────────

section ".NET SDK ${DOTNET_SDK_VERSION}"
if dotnet --version 2>/dev/null | grep -q "^8\."; then
    info ".NET SDK 8.x already installed: $(dotnet --version)"
else
    if [[ ! -f /etc/apt/sources.list.d/microsoft-prod.list ]]; then
        wget -qO /tmp/packages-microsoft-prod.deb \
            "https://packages.microsoft.com/config/ubuntu/20.04/packages-microsoft-prod.deb"
        dpkg -i /tmp/packages-microsoft-prod.deb
        rm -f /tmp/packages-microsoft-prod.deb
    fi
    apt-get update -qq
    apt-get install -y "dotnet-sdk-${DOTNET_SDK_VERSION}"
fi

# ── step 3: Dafny ────────────────────────────────────────────────────────────

section "Dafny ${DAFNY_VERSION}"
if [[ -f "${DAFNY_INSTALL_DIR}/dafny" && -x "${DAFNY_INSTALL_DIR}/dafny" ]]; then
    INSTALLED_VER="$("${DAFNY_INSTALL_DIR}/dafny" --version 2>&1 | head -1 | cut -d+ -f1)"
    if [[ "${INSTALLED_VER}" == "${DAFNY_VERSION}" ]]; then
        info "Dafny ${DAFNY_VERSION} already installed."
    else
        info "Replacing Dafny ${INSTALLED_VER} with ${DAFNY_VERSION}..."
        rm -rf "${DAFNY_INSTALL_DIR}"
    fi
else
    # Remove any broken install (e.g. a directory where the binary should be)
    rm -rf "${DAFNY_INSTALL_DIR}"
fi

if [[ ! -x "${DAFNY_INSTALL_DIR}/dafny" ]]; then
    TMP_DAFNY="$(mktemp -d)"
    wget -qO "${TMP_DAFNY}/${DAFNY_ARCHIVE}" "${DAFNY_URL}"

    # Locate the dafny binary regardless of how the zip is structured.
    # The ubuntu release zip contains a `dafny/` subdirectory with a `dafny`
    # binary inside (same name as directory), so naive flatten with mv breaks.
    TMP_EXTRACT="$(mktemp -d)"
    unzip -q "${TMP_DAFNY}/${DAFNY_ARCHIVE}" -d "${TMP_EXTRACT}"
    DAFNY_BIN="$(find "${TMP_EXTRACT}" -type f -name "dafny" | head -1)"
    [[ -n "${DAFNY_BIN}" ]] || die "dafny binary not found in archive"
    BUNDLE_DIR="$(dirname "${DAFNY_BIN}")"

    rm -rf "${DAFNY_INSTALL_DIR}"
    mv "${BUNDLE_DIR}" "${DAFNY_INSTALL_DIR}"
    # Ensure all files world-readable/executable (extracted as root)
    chmod -R a+rX "${DAFNY_INSTALL_DIR}"
    chmod a+x "${DAFNY_INSTALL_DIR}/dafny"

    rm -rf "${TMP_DAFNY}" "${TMP_EXTRACT}"
fi

if [[ ! -e /usr/local/bin/dafny ]]; then
    ln -sf "${DAFNY_INSTALL_DIR}/dafny" /usr/local/bin/dafny
fi
info "Dafny: $("${DAFNY_INSTALL_DIR}/dafny" --version 2>&1 | head -1)"

# ── step 4: Rust ─────────────────────────────────────────────────────────────

section "Rust (stable)"
RUSTUP_BIN="${SUDO_HOME}/.cargo/bin/rustup"
RUSTC_BIN="${SUDO_HOME}/.cargo/bin/rustc"

if [[ -x "${RUSTC_BIN}" ]]; then
    info "Rust already installed: $(as_user "${RUSTC_BIN}" --version)"
else
    TMP_RUSTUP="$(mktemp -d)"
    curl -fsSL https://sh.rustup.rs -o "${TMP_RUSTUP}/rustup-init.sh"
    chmod +x "${TMP_RUSTUP}/rustup-init.sh"
    as_user sh "${TMP_RUSTUP}/rustup-init.sh" \
        --no-modify-path --default-toolchain stable --profile minimal -y
    rm -rf "${TMP_RUSTUP}"
fi

as_user "${RUSTUP_BIN}" toolchain install stable --no-self-update
as_user "${RUSTUP_BIN}" target add x86_64-unknown-linux-gnu
info "rustc: $(as_user "${RUSTC_BIN}" --version)"

# ── step 5: bdus (kernel module + library) ───────────────────────────────────

section "bdus"
BDUS_DIR="${SCRIPT_DIR}/bdus"
KERNEL_RELEASE="$(uname -r)"

info "Building bdus in ${BDUS_DIR}..."
make -C "${BDUS_DIR}" KBDUS_KDIR="/lib/modules/${KERNEL_RELEASE}/build" clean
make -C "${BDUS_DIR}" KBDUS_KDIR="/lib/modules/${KERNEL_RELEASE}/build"

info "Installing bdus..."
make -C "${BDUS_DIR}" KBDUS_KDIR="/lib/modules/${KERNEL_RELEASE}/build" install

info "Loading kbdus kernel module..."
modprobe kbdus || true

ldconfig -p | grep libbdus > /dev/null \
    || die "libbdus.so installed but not found by ldconfig."
info "bdus installed and kbdus loaded."

section "gatekeeper config"
info "Installing /etc/timelockdrive/gatekeeper.toml..."
mkdir -p /etc/timelockdrive
if [[ ! -f /etc/timelockdrive/gatekeeper.toml ]]; then
    cp "${SCRIPT_DIR}/gatekeeper/gatekeeper.toml" /etc/timelockdrive/gatekeeper.toml
    info "Config installed. Edit /etc/timelockdrive/gatekeeper.toml to set disk_path."
else
    info "Config already present at /etc/timelockdrive/gatekeeper.toml – not overwriting."
fi

# ── step 6: build shared library + driver ────────────────────────────────────

section "versioning_td_driver (C)"
make -C "${SCRIPT_DIR}/versioning_td_driver" clean
make -C "${SCRIPT_DIR}/versioning_td_driver"
info "Driver binary: ${SCRIPT_DIR}/versioning_td_driver/bin/versioning_td_driver"

# ── step 7: build gatekeeper (Dafny → Rust → binary) ─────────────────────────

section "gatekeeper (Dafny → Rust)"
# Run cargo/dafny as the non-root user so that ~/.cargo is writable
if $SKIP_VERIFY; then
    info "Building gatekeeper (skipping verification)..."
    as_user env PATH="${SUDO_HOME}/.cargo/bin:${PATH}" \
        make -C "${SCRIPT_DIR}/gatekeeper" build
else
    info "Verifying and building gatekeeper..."
    as_user env PATH="${SUDO_HOME}/.cargo/bin:${PATH}" \
        make -C "${SCRIPT_DIR}/gatekeeper" all
fi
info "Gatekeeper binary: ${SCRIPT_DIR}/gatekeeper/gatekeeper/main-rust/target/release/main"

# ── step 8 (optional): RAM disks ─────────────────────────────────────────────

if $SETUP_RAMDISK; then
    section "RAM disk"
    RAMDISK_ARGS=""
    $RAMDISK_DEV_MODE && RAMDISK_ARGS="--dev-mode"
    bash "${SCRIPT_DIR}/setup_ramdisk.sh" $RAMDISK_ARGS
fi

# ── done ─────────────────────────────────────────────────────────────────────

section "Setup complete"
info ""
info "To run the full stack:"
info ""
if $SETUP_RAMDISK; then
    info "  # (RAM disk already set up)"
else
    info "  # 1. Set up a RAM disk (or use a physical disk at /dev/sdb):"
    info "  sudo ./setup_ramdisk.sh            # 10 GiB RAM disk"
    info "  sudo ./setup_ramdisk.sh --dev-mode # 1 GiB for quick tests"
fi
info ""
info "  # Terminal 1 - gatekeeper:"
info "  source /tmp/td_ramdisk.env"
info "  sudo -E ${SCRIPT_DIR}/gatekeeper/gatekeeper/main-rust/target/release/main \\"
info "      --timelockdrive"
info ""
info "  # Terminal 2 - driver:"
info "  sudo ${SCRIPT_DIR}/versioning_td_driver/bin/versioning_td_driver"
