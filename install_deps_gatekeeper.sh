#!/usr/bin/env bash
# install_deps_gatekeeper.sh
#
# Installs all dependencies required to build the Timelock Drive gatekeeper
# on Ubuntu 20.04.  This covers:
#
#   1. .NET SDK 8.0   – runtime for the Dafny compiler
#   2. Dafny 4.10.0   – verification + Rust code generation
#   3. Rust (stable)  – compiles the Dafny-generated Rust output
#
# Run as root or with sudo for steps 1-2; step 3 (rustup) installs into the
# calling user's home directory and must NOT be run as root.  The script
# detects this and drops privileges for the rustup step.
#
# Safe to re-run; each step checks whether the tool is already present.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pinned versions
DAFNY_VERSION="4.10.0"
DAFNY_ARCHIVE="dafny-${DAFNY_VERSION}-x64-ubuntu-20.04.zip"
DAFNY_URL="https://github.com/dafny-lang/dafny/releases/download/v${DAFNY_VERSION}/${DAFNY_ARCHIVE}"
DAFNY_INSTALL_DIR="/opt/dafny"

DOTNET_SDK_VERSION="8.0"   # matches dotnet-sdk-8.0 package stream

# ── helpers ──────────────────────────────────────────────────────────────────

info()  { echo "[info]  $*"; }
warn()  { echo "[warn]  $*"; }
die()   { echo "[error] $*" >&2; exit 1; }

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        die "This script must be run as root (use sudo -E to preserve the user environment for rustup)."
    fi
}

# The user who invoked sudo (or root if run directly as root)
SUDO_USER="${SUDO_USER:-${USER}}"
SUDO_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"

# Run a command as the original (non-root) user
as_user() {
    if [[ "${SUDO_USER}" == "root" ]]; then
        "$@"
    else
        sudo -u "${SUDO_USER}" -H env HOME="${SUDO_HOME}" "$@"
    fi
}

# ── 0. pre-flight ─────────────────────────────────────────────────────────────

require_root
info "Non-root user for rustup / cargo steps: ${SUDO_USER} (home: ${SUDO_HOME})"

# ── 1. .NET SDK 8.0 ──────────────────────────────────────────────────────────

if dotnet --version 2>/dev/null | grep -q "^8\."; then
    info ".NET SDK 8.x already installed: $(dotnet --version)"
else
    info "Installing .NET SDK ${DOTNET_SDK_VERSION}..."

    apt-get update -qq
    apt-get install -y wget apt-transport-https

    # Microsoft's official Ubuntu 20.04 feed
    if [[ ! -f /etc/apt/sources.list.d/microsoft-prod.list ]]; then
        wget -qO /tmp/packages-microsoft-prod.deb \
            "https://packages.microsoft.com/config/ubuntu/20.04/packages-microsoft-prod.deb"
        dpkg -i /tmp/packages-microsoft-prod.deb
        rm -f /tmp/packages-microsoft-prod.deb
    fi

    apt-get update -qq
    apt-get install -y "dotnet-sdk-${DOTNET_SDK_VERSION}"
fi

# ── 2. Dafny 4.10.0 ──────────────────────────────────────────────────────────

if [[ -f "${DAFNY_INSTALL_DIR}/dafny" && -x "${DAFNY_INSTALL_DIR}/dafny" ]]; then
    INSTALLED_VER="$("${DAFNY_INSTALL_DIR}/dafny" --version 2>&1 | head -1 | cut -d+ -f1)"
    if [[ "${INSTALLED_VER}" == "${DAFNY_VERSION}" ]]; then
        info "Dafny ${DAFNY_VERSION} already installed at ${DAFNY_INSTALL_DIR}"
    else
        warn "A different Dafny version is present (${INSTALLED_VER}). Reinstalling ${DAFNY_VERSION}..."
        rm -rf "${DAFNY_INSTALL_DIR}"
    fi
else
    # Remove any broken install (e.g. a directory where the binary should be)
    rm -rf "${DAFNY_INSTALL_DIR}"
fi

if [[ ! -x "${DAFNY_INSTALL_DIR}/dafny" ]]; then
    info "Downloading Dafny ${DAFNY_VERSION}..."
    apt-get install -y unzip wget

    TMPDIR_DAFNY="$(mktemp -d)"
    wget -qO "${TMPDIR_DAFNY}/${DAFNY_ARCHIVE}" "${DAFNY_URL}"

    info "Extracting Dafny ${DAFNY_VERSION}..."
    TMPDIR_EXTRACT="$(mktemp -d)"
    unzip -q "${TMPDIR_DAFNY}/${DAFNY_ARCHIVE}" -d "${TMPDIR_EXTRACT}"

    # Locate the dafny binary regardless of how the zip is structured.
    # The ubuntu release zip contains a `dafny/` subdirectory with a `dafny`
    # binary inside (same name as the directory), so naive mv/flatten breaks.
    DAFNY_BIN="$(find "${TMPDIR_EXTRACT}" -type f -name "dafny" | head -1)"
    [[ -n "${DAFNY_BIN}" ]] || { echo "[error] dafny binary not found in archive" >&2; exit 1; }
    BUNDLE_DIR="$(dirname "${DAFNY_BIN}")"

    rm -rf "${DAFNY_INSTALL_DIR}"
    mv "${BUNDLE_DIR}" "${DAFNY_INSTALL_DIR}"
    # Ensure all files are world-readable/executable (extracted as root)
    chmod -R a+rX "${DAFNY_INSTALL_DIR}"
    chmod a+x "${DAFNY_INSTALL_DIR}/dafny"

    rm -rf "${TMPDIR_DAFNY}" "${TMPDIR_EXTRACT}"
fi

# Symlink into /usr/local/bin so it's on PATH for all users
if [[ ! -e /usr/local/bin/dafny ]]; then
    ln -sf "${DAFNY_INSTALL_DIR}/dafny" /usr/local/bin/dafny
    info "Created symlink: /usr/local/bin/dafny -> ${DAFNY_INSTALL_DIR}/dafny"
fi

info "Dafny version: $("${DAFNY_INSTALL_DIR}/dafny" --version 2>&1 | head -1)"

# ── 3. Rust (stable) via rustup ───────────────────────────────────────────────
#
# rustup must be installed as the target user, not root.

RUSTUP_PATH="${SUDO_HOME}/.cargo/bin/rustup"
RUSTC_PATH="${SUDO_HOME}/.cargo/bin/rustc"

if [[ -x "${RUSTC_PATH}" ]]; then
    info "Rust already installed for ${SUDO_USER}: $(as_user "${RUSTC_PATH}" --version)"
else
    info "Installing Rust (stable) for ${SUDO_USER} via rustup..."
    apt-get install -y curl

    TMPDIR_RUSTUP="$(mktemp -d)"
    curl -fsSL https://sh.rustup.rs -o "${TMPDIR_RUSTUP}/rustup-init.sh"
    chmod +x "${TMPDIR_RUSTUP}/rustup-init.sh"

    as_user sh "${TMPDIR_RUSTUP}/rustup-init.sh" \
        --no-modify-path \
        --default-toolchain stable \
        --profile minimal \
        -y

    rm -rf "${TMPDIR_RUSTUP}"
fi

# Ensure stable toolchain and x86_64 target are present
as_user "${RUSTUP_PATH}" toolchain install stable --no-self-update
as_user "${RUSTUP_PATH}" target add x86_64-unknown-linux-gnu

info "Rust version: $(as_user "${RUSTC_PATH}" --version)"
info "Cargo version: $(as_user "${SUDO_HOME}/.cargo/bin/cargo" --version)"

# ── 4. Verify the Makefile dafny_exec path expectation ───────────────────────
#
# The gatekeeper Makefile uses /opt/dafny/dafny. Warn if it differs.

MAKEFILE_DAFNY="$(grep 'dafny_exec\s*:=' "${SCRIPT_DIR}/gatekeeper/Makefile" 2>/dev/null | head -1 | sed 's/.*:= *//')"
if [[ -n "${MAKEFILE_DAFNY}" && "${MAKEFILE_DAFNY}" != "${DAFNY_INSTALL_DIR}/dafny" ]]; then
    warn "Makefile dafny_exec is set to '${MAKEFILE_DAFNY}'."
    warn "Installed Dafny is at '${DAFNY_INSTALL_DIR}/dafny'."
    warn "Either update the Makefile or create a symlink at '${MAKEFILE_DAFNY}'."
fi

# ── done ─────────────────────────────────────────────────────────────────────

info ""
info "All gatekeeper dependencies installed successfully."
info ""
info "To build the gatekeeper (Dafny → Rust → binary):"
info "  cd ${SCRIPT_DIR}/gatekeeper"
info "  make build          # compile Dafny, generate Rust, compile binary"
info "  make verify         # (optional) run Dafny verification proofs"
info ""
info "NOTE: Add Rust to your PATH if it is not already:"
info "  source ${SUDO_HOME}/.cargo/env"
