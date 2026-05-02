#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib_defaults.sh"
test_lib_init_shared_defaults "$SCRIPT_DIR"
source "$TESTS_DIR/test_lib_common.sh"
source "$TESTS_DIR/test_lib_transport.sh"
TMP_DIR="$(mktemp -d)"
test_lib_init_tmp_artifact_defaults "$TMP_DIR"
SRC_DIR="$TMP_DIR/src_payload"
DRIVER_ARGS="${DRIVER_ARGS:-}"
IO_TIMEOUT_SECS="${IO_TIMEOUT_SECS:-40}"
FORMAT_TIMEOUT_SECS="${FORMAT_TIMEOUT_SECS:-240}"
TIMEOUT_KILL_AFTER_SECS="${TIMEOUT_KILL_AFTER_SECS:-8}"
DRIVER_WAIT_ATTEMPTS="${DRIVER_WAIT_ATTEMPTS:-70}"

test_lib_setup_transport_from_env
# Filesystem size in 4 KiB blocks (default: 128 MiB = 32768 blocks)
FS_SIZE_BLOCKS="${FS_SIZE_BLOCKS:-32768}"
RECOVERY_SETTLE_SECS="${RECOVERY_SETTLE_SECS:-0}"
RECOVERY_RETRY_SETTLE_SECS="${RECOVERY_RETRY_SETTLE_SECS:-65}"
SKIP_RECOVERY_FSCK="${SKIP_RECOVERY_FSCK:-1}"
RECOVERY_FSCK_ON_MOUNT_FAIL="${RECOVERY_FSCK_ON_MOUNT_FAIL:-1}"
GATEKEEPER_VERBOSE="${GATEKEEPER_VERBOSE:-1}"

EXPECTED_MANIFEST="$TMP_DIR/expected_manifest.sha256"
RECOVERED_MANIFEST="$TMP_DIR/recovered_manifest.sha256"
EXPECTED_TREE="$TMP_DIR/expected_tree.txt"
RECOVERED_TREE="$TMP_DIR/recovered_tree.txt"

gatekeeper_pid=""
driver_pid=""
bdus_device=""
mounted=0
test_succeeded=0
KEEP_TMP_DIR="${KEEP_TMP_DIR:-0}"

cleanup() {
    set +e

    if [[ "$mounted" -eq 1 ]]; then
        test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo umount -f "$MOUNT_DIR" >/dev/null 2>&1 || true
        mounted=0
    fi

    # Call the standard shared cleanup handler
    test_lib_script_cleanup_handler
}

trap cleanup EXIT

log() {
    printf '[e2e_fs_recovery] %s\n' "$*"
}

force_flush_before_crash() {
    # Force filesystem-level writeback for the mounted fs and flush via sync(device).
    # sync -f uses syncfs(2) for the target filesystem and is stronger than global sync alone.
    test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo sync
    test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo sync -f "$MOUNT_DIR" >/dev/null 2>&1 || true

    # Optional: freeze/unfreeze to quiesce filesystem state before the simulated crash.
    # Controlled by FORCE_FREEZE_FLUSH=1 to avoid making it mandatory on all systems.
    if [[ "${FORCE_FREEZE_FLUSH:-0}" == "1" ]] && command -v fsfreeze >/dev/null 2>&1; then
        if test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo fsfreeze -f "$MOUNT_DIR"; then
            test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo fsfreeze -u "$MOUNT_DIR" || true
        else
            log "fsfreeze failed on $MOUNT_DIR; continuing with syncfs/sync(device) flush path"
        fi
    fi

    test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo sync "$bdus_device" >/dev/null 2>&1 || true
}

clean_gk_shutdown() {
    test_lib_clean_gk_shutdown gatekeeper_pid "" driver_pid bdus_device "$IO_TIMEOUT_SECS" log
}

# Cleanup is handled above with mount-specific wrapper

ensure_recovery_device_present() {
    if [[ -n "$bdus_device" && -b "$bdus_device" ]]; then
        return 0
    fi

    log "Recovered BDUS device is missing before remount: ${bdus_device:-<empty>}"
    if [[ -f "$GATEKEEPER_LOG" ]]; then
        log "Last gatekeeper log lines:"
        tail -n 80 "$GATEKEEPER_LOG" | sed 's/^/[e2e_fs_recovery] gatekeeper: /'
    fi
    if [[ -f "$DRIVER_LOG" ]]; then
        log "Last driver log lines:"
        tail -n 80 "$DRIVER_LOG" | sed 's/^/[e2e_fs_recovery] driver: /'
    fi

    return 1
}

start_gatekeeper() {
    local phase_name="$1"; shift
    # GATEKEEPER_VERBOSE controls stdout routing; handled by test_lib_start_gatekeeper_raw.
    test_lib_start_gatekeeper_raw "$phase_name" "$@"
}

kill_stack_uncleanly() {
    test_lib_kill_stack_uncleanly gatekeeper_pid driver_pid bdus_device
}

create_payload_source() {
    mkdir -p "$SRC_DIR/docs" "$SRC_DIR/bin" "$SRC_DIR/deep/tree/a/b/c" "$SRC_DIR/empty"

    printf 'filesystem recovery e2e\n' >"$SRC_DIR/docs/readme.txt"
    printf 'one\ntwo\nthree\n' >"$SRC_DIR/docs/lines.txt"

    # Medium random binary payload.
    head -c $((1024 * 1024)) /dev/urandom >"$SRC_DIR/bin/random_1m.bin"

    # Sparse file with data near the end.
    truncate -s $((8 * 1024 * 1024)) "$SRC_DIR/bin/sparse.img"
    printf 'tail-marker' | dd of="$SRC_DIR/bin/sparse.img" bs=1 seek=$((8 * 1024 * 1024 - 10)) conv=notrunc status=none

    # Many tiny files exercise inode/dir metadata persistence.
    for i in $(seq 1 64); do
        printf 'file-%03d\n' "$i" >"$SRC_DIR/deep/tree/a/b/c/file_$i.txt"
    done

    ln -s ../docs/readme.txt "$SRC_DIR/deep/tree/a/readme_link"
}

create_expected_manifests() {
    (
        cd "$SRC_DIR"
        find . -mindepth 1 -printf '%y %P\n' | LC_ALL=C sort
    ) >"$EXPECTED_TREE"

    (
        cd "$SRC_DIR"
        find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
    ) >"$EXPECTED_MANIFEST"
}

create_recovered_manifests() {
    test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo bash -c "cd '$MOUNT_DIR' && find . -mindepth 1 ! -path './lost+found' ! -path './lost+found/*' -printf '%y %P\\n' | LC_ALL=C sort" >"$RECOVERED_TREE"

    test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo bash -c "cd '$MOUNT_DIR' && find . -type f ! -path './lost+found/*' -print0 | LC_ALL=C sort -z | xargs -0 sha256sum" >"$RECOVERED_MANIFEST"
}

log "Building gatekeeper and host driver"
test_lib_build_gatekeeper_if_needed 'make -C "$GDIR" build >/dev/null'
make -C "$VDIR" versioning_td_driver >/dev/null

mkdir -p "$MOUNT_DIR"
test_lib_preflight_cleanup_full "$IO_TIMEOUT_SECS" log
create_payload_source
create_expected_manifests

if ! command -v mkfs.ext4 >/dev/null 2>&1; then
    log "mkfs.ext4 is required for this test"
    exit 1
fi

# Phase 1: bring up stack, format+mount filesystem, write diverse files.
start_gatekeeper initial
test_lib_start_driver "initial"

log "Formatting $bdus_device as ext4 (nodiscard, non-interactive)"
test_lib_run_with_timeout "$FORMAT_TIMEOUT_SECS" sudo mkfs.ext4 -F -E nodiscard -q "$bdus_device" "$FS_SIZE_BLOCKS"

log "Mounting $bdus_device at $MOUNT_DIR"
test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo mount "$bdus_device" "$MOUNT_DIR"
mounted=1

log "Copying diverse payload tree into mounted filesystem"
test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo cp -a "$SRC_DIR/." "$MOUNT_DIR/"

log "Forcing filesystem and block flush"
force_flush_before_crash

log "Simulating driver+checker crash without clean unmount"
kill_stack_uncleanly
test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo umount -l "$MOUNT_DIR" >/dev/null 2>&1 || true
mounted=0

# Phase 2: restart in recovery mode and verify mounted filesystem contents.
start_gatekeeper recovery --no-init --no-zero
test_lib_start_driver "recovery"

if [[ "$RECOVERY_SETTLE_SECS" -gt 0 ]]; then
    log "Waiting ${RECOVERY_SETTLE_SECS}s before fsck/remount to allow metadata timelock expiry"
    sleep "$RECOVERY_SETTLE_SECS"
fi

# Optional proactive ext4 checks before first mount.
if [[ "$SKIP_RECOVERY_FSCK" != "1" ]]; then
    test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo fsck.ext4 -fy "$bdus_device" >/dev/null 2>&1 || true
else
    log "Skipping recovery fsck (SKIP_RECOVERY_FSCK=1)"
fi

if ! ensure_recovery_device_present; then
    exit 1
fi

log "Remounting recovered filesystem"
if ! test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo mount "$bdus_device" "$MOUNT_DIR"; then
    if [[ "$RECOVERY_FSCK_ON_MOUNT_FAIL" == "1" ]]; then
        log "Initial remount failed; running fsck and retrying mount"
        test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo fsck.ext4 -fy "$bdus_device" >/dev/null 2>&1 || true
        if ! test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo mount "$bdus_device" "$MOUNT_DIR"; then
            if [[ "$RECOVERY_RETRY_SETTLE_SECS" -gt 0 ]]; then
                log "Second remount failed; waiting ${RECOVERY_RETRY_SETTLE_SECS}s for timelock settle, then retrying"
                sleep "$RECOVERY_RETRY_SETTLE_SECS"
                test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo fsck.ext4 -fy "$bdus_device" >/dev/null 2>&1 || true
                test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo mount "$bdus_device" "$MOUNT_DIR"
            else
                exit 1
            fi
        fi
    else
        log "Initial remount failed and RECOVERY_FSCK_ON_MOUNT_FAIL=0"
        exit 1
    fi
fi
mounted=1

create_recovered_manifests

if ! cmp -s "$EXPECTED_TREE" "$RECOVERED_TREE"; then
    log "Recovered filesystem structure mismatch"
    exit 1
fi

if ! cmp -s "$EXPECTED_MANIFEST" "$RECOVERED_MANIFEST"; then
    log "Recovered filesystem file-content checksum mismatch"
    exit 1
fi

test_succeeded=1
log "PASS: filesystem reconstructed after driver/checker restart"
