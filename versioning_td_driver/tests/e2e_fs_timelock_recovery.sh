#!/usr/bin/env bash
# e2e_fs_timelock_recovery.sh
#
# End-to-end test for TSC-timestamp-based (timelock) recovery.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib_defaults.sh"
test_lib_init_shared_defaults "$SCRIPT_DIR"
source "$TESTS_DIR/test_lib_common.sh"
source "$TESTS_DIR/test_lib_transport.sh"
TMP_DIR="$(mktemp -d)"
test_lib_init_tmp_artifact_defaults "$TMP_DIR"
DRIVER_ARGS_BASE="${DRIVER_ARGS:-}"
IO_TIMEOUT_SECS="${IO_TIMEOUT_SECS:-40}"
FORMAT_TIMEOUT_SECS="${FORMAT_TIMEOUT_SECS:-600}"
TIMEOUT_KILL_AFTER_SECS="${TIMEOUT_KILL_AFTER_SECS:-8}"

test_lib_setup_transport_from_env
FS_SIZE_BLOCKS="${FS_SIZE_BLOCKS:-32768}"
SKIP_RECOVERY_FSCK="${SKIP_RECOVERY_FSCK:-1}"
RECOVERY_FSCK_ON_MOUNT_FAIL="${RECOVERY_FSCK_ON_MOUNT_FAIL:-1}"
RECOVERY_SETTLE_SECS="${RECOVERY_SETTLE_SECS:-0}"
RECOVERY_RETRY_SETTLE_SECS="${RECOVERY_RETRY_SETTLE_SECS:-65}"
GATEKEEPER_VERBOSE="${GATEKEEPER_VERBOSE:-0}"
# Timing windows for timestamp anchor capture.
SNAPSHOT_PRE_WAIT_SECS="${SNAPSHOT_PRE_WAIT_SECS:-2}"
SNAPSHOT_POST_WAIT_SECS="${SNAPSHOT_POST_WAIT_SECS:-2}"
# Number of 4 KiB blocks written per phase to force at least one complete HD log
# flush.  HD log holds 1021 entries; a VMD block contributes 1 entry when it fills
# at 511 mappings.  1100 × 4 KiB = 4.4 MiB; well above the 1021 threshold even
# when the partial HD log carries up to ~200 prior entries from mkfs tail.
BULK_BLOCKS="${BULK_BLOCKS:-1100}"


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

TRACE_DIAGNOSTICS="${TRACE_DIAGNOSTICS:-1}"
TRACE_CHAIN_LIMIT="${TRACE_CHAIN_LIMIT:-6}"

log() {
    printf '[e2e_fs_timelock] %s\n' "$*"
}

trace_gatekeeper_state() {
    local phase="$1"
    if [[ "$TRACE_DIAGNOSTICS" != "1" ]]; then
        return 0
    fi

    local identify_out=""
    identify_out="$(test_lib_run_client_cmd "$CLIENT_BIN" "$IO_TIMEOUT_SECS" peek-identify 0 2>/dev/null || true)"
    if [[ -z "$identify_out" ]]; then
        log "TRACE[$phase] identify unavailable"
        return 0
    fi

    log "TRACE[$phase] $identify_out"

    local head=""
    local tail=""
    head="$(echo "$identify_out" | sed -n 's/^IDENTIFY head=\([0-9][0-9]*\) tail=.*/\1/p')"
    tail="$(echo "$identify_out" | sed -n 's/^IDENTIFY head=[0-9][0-9]* tail=\([0-9][0-9]*\)$/\1/p')"
    if [[ -z "$head" || -z "$tail" ]]; then
        log "TRACE[$phase] unable to parse head/tail"
        return 0
    fi

    local curr="$head"
    local line=""
    local next=""
    local i=0
    while (( i < TRACE_CHAIN_LIMIT )); do
        line="$(test_lib_run_client_cmd "$CLIENT_BIN" "$IO_TIMEOUT_SECS" peek-hdlog "$curr" 2>/dev/null || true)"
        if [[ -z "$line" ]]; then
            log "TRACE[$phase] hdlog[$i] unavailable for pba=$curr"
            break
        fi
        log "TRACE[$phase] hdlog[$i] $line"

        next="$(echo "$line" | sed -n 's/^HDLOG pba=[0-9][0-9]* keep=[0-9][0-9]* current=[0-9][0-9]* next=\([0-9][0-9]*\)$/\1/p')"
        if [[ -z "$next" ]]; then
            break
        fi
        if [[ "$next" == "$tail" ]]; then
            log "TRACE[$phase] committed-chain stops before exclusive tail=$tail"
            break
        fi
        curr="$next"
        i=$((i + 1))
    done

    local tail_line=""
    tail_line="$(test_lib_run_client_cmd "$CLIENT_BIN" "$IO_TIMEOUT_SECS" peek-hdlog "$tail" 2>/dev/null || true)"
    if [[ -n "$tail_line" ]]; then
        log "TRACE[$phase] tail-cursor-slot $tail_line"
    fi
}

trace_latest_recovery_summary() {
    local phase="$1"
    if [[ "$TRACE_DIAGNOSTICS" != "1" ]]; then
        return 0
    fi

    local summary=""
    summary="$(tail -n 400 /tmp/timelockdriver.log 2>/dev/null | grep 'recovery summary ts=' | tail -n 1 || true)"
    if [[ -n "$summary" ]]; then
        log "TRACE[$phase] $summary"
    else
        log "TRACE[$phase] no recovery summary line found"
    fi
}

trace_recent_rejects() {
    local phase="$1"
    if [[ "$TRACE_DIAGNOSTICS" != "1" ]]; then
        return 0
    fi

    local reject=""
    reject="$(tail -n 400 /tmp/timelockdriver.log 2>/dev/null | grep -E 'write reject status=|WRITE_DENIED|FRESHNESS_REJECT' | tail -n 3 || true)"
    if [[ -n "$reject" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && log "TRACE[$phase] $line"
        done <<< "$reject"
    fi
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
        tail -n 80 "$GATEKEEPER_LOG" | sed 's/^/[e2e_fs_timelock] gatekeeper: /'
    fi
    if [[ -f "$DRIVER_LOG" ]]; then
        log "Last driver log lines:"
        tail -n 80 "$DRIVER_LOG" | sed 's/^/[e2e_fs_timelock] driver: /'
    fi

    return 1
}

start_gatekeeper() {
    local phase_name="$1"; shift
    test_lib_start_gatekeeper_raw "$phase_name" "$@"
}

start_driver() {
    local extra_args="${1:-}"
    : >"$CURRENT_BDUS_FILE"
    : >"$DRIVER_LOG"

    log "Starting versioning driver${extra_args:+ (args: $extra_args)}"
    (
        cd "$VDIR"
        # shellcheck disable=SC2086
        sudo ./bin/versioning_td_driver $DRIVER_TRANSPORT_ARG $DRIVER_ARGS_BASE $extra_args >"$CURRENT_BDUS_FILE" 2>"$DRIVER_LOG"
    ) &
    driver_pid=$!

    if ! test_lib_wait_for_bdus_device "$CURRENT_BDUS_FILE" bdus_device "${DRIVER_WAIT_ATTEMPTS:-70}" "${DRIVER_WAIT_DELAY_SECS:-0.2}"; then
        log "Driver did not expose a BDUS device"
        if [[ -f "$DRIVER_LOG" ]]; then
            log "Last driver log lines:"
            tail -n 40 "$DRIVER_LOG" | sed 's/^/[e2e_fs_timelock] driver: /'
        fi
        return 1
    fi

    log "Driver exposed $bdus_device"
}

kill_stack_uncleanly() {
    test_lib_kill_stack_uncleanly gatekeeper_pid driver_pid bdus_device
}

stop_stack_cleanly() {
    if [[ "$mounted" -eq 1 ]]; then
        log "Unmounting filesystem cleanly before restart"
        test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo umount "$MOUNT_DIR"
        mounted=0
    fi

    if [[ -n "$bdus_device" ]]; then
        log "Stopping driver via bdus destroy (triggers SYNC + FINISH)"
        test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo bdus destroy "$bdus_device"
        bdus_device=""
    fi

    if [[ -n "$driver_pid" ]]; then
        wait "$driver_pid" 2>/dev/null || true
        driver_pid=""
    fi

    if [[ -n "$gatekeeper_pid" ]]; then
        wait "$gatekeeper_pid" 2>/dev/null || true
        gatekeeper_pid=""
    fi
}

force_flush() {
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

# ---------------------------------------------------------------------------
# Compile the rdtsc helper.
# Prints (unsigned int)(__rdtsc() >> 32) — identical to what the driver and
# gatekeeper (INTERNAL_ReadTimestamp, TSC_OFFSET=32 on x86_64) use for
# MetadataEntry.time_written.
# ---------------------------------------------------------------------------
compile_rdtsc_helper() {
    local out="$TMP_DIR/get_rdtsc"
    gcc -O2 -o "$out" -x c - <<'CEOF'
#include <stdio.h>
#include <stdint.h>

static inline uint64_t rdtsc(void)
{
    unsigned int lo, hi;
    __asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi));
    return ((uint64_t)hi << 32) | (uint64_t)lo;
}

int main(void)
{
    printf("%u\n", (unsigned int)(rdtsc() >> 32));
    return 0;
}
CEOF
    echo "$out"
}


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
log "Building gatekeeper and host driver"
test_lib_build_gatekeeper_if_needed 'make -C "$GDIR" build >/dev/null'
make -C "$VDIR" versioning_td_driver >/dev/null
gcc -O2 -g -I "$ROOT_DIR/shared/include" -I "$VDIR/include" "$CLIENT_SRC" "$VDIR/src/ipc_transport.c" -lrt -o "$CLIENT_BIN"

mkdir -p "$MOUNT_DIR"
test_lib_preflight_cleanup_full "$IO_TIMEOUT_SECS" log

if ! command -v mkfs.ext4 >/dev/null 2>&1; then
    log "mkfs.ext4 is required"
    exit 1
fi

RDTSC_BIN="$(compile_rdtsc_helper)"

# Phase 1 — initial session: format ext4, mount, write v1 payload
start_gatekeeper "initial"
start_driver

log "Formatting $bdus_device as ext4"
test_lib_run_with_timeout "$FORMAT_TIMEOUT_SECS" sudo mkfs.ext4 -F -E nodiscard -q "$bdus_device" "$FS_SIZE_BLOCKS"

log "Mounting $bdus_device at $MOUNT_DIR"
test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo mount "$bdus_device" "$MOUNT_DIR"
mounted=1

log "Writing v1 payload"
sudo bash -c "
    mkdir -p '$MOUNT_DIR/docs' '$MOUNT_DIR/data'
    echo 'VERSION-1'       > '$MOUNT_DIR/marker.txt'
    echo 'v1-line-one'     > '$MOUNT_DIR/docs/notes.txt'
    echo 'v1-line-two'    >> '$MOUNT_DIR/docs/notes.txt'
    echo 'shared-file-v1' > '$MOUNT_DIR/docs/shared.txt'
    echo 'v1-only-file'   > '$MOUNT_DIR/v1_only.txt'
    dd if=/dev/urandom bs=4096 count=$BULK_BLOCKS of='$MOUNT_DIR/data/v1_bulk.bin' status=none
"

log "Flushing v1 payload"
force_flush

log "Waiting ${SNAPSHOT_PRE_WAIT_SECS}s after v1 sync before taking recovery anchor"
sleep "$SNAPSHOT_PRE_WAIT_SECS"

log "Stopping stack cleanly to persist log state before anchor probe"
stop_stack_cleanly

start_gatekeeper "anchor_probe" --no-init --no-zero
trace_gatekeeper_state "anchor_probe"
ANCHOR_OUT="$(test_lib_run_client_cmd "$CLIENT_BIN" "$IO_TIMEOUT_SECS" anchor-tail 0)"
log "Anchor probe output: $ANCHOR_OUT"
TIMESTAMP_DISK="$(echo "$ANCHOR_OUT" | sed -n 's/^ANCHOR head=[0-9][0-9]* tail=[0-9][0-9]* keep=[0-9][0-9]* current=\([0-9][0-9]*\) next=[0-9][0-9]*$/\1/p')"
if [[ -z "$TIMESTAMP_DISK" ]]; then
    log "FAIL: unable to parse ANCHOR output: $ANCHOR_OUT"
    exit 1
fi
if [[ "$TIMESTAMP_DISK" -eq 0 ]]; then
    log "FAIL: invalid zero anchor timestamp from probe output: $ANCHOR_OUT"
    exit 1
fi

TIMESTAMP_NOW="$($RDTSC_BIN)"
TIMESTAMP="$TIMESTAMP_DISK"
if [[ "$TIMESTAMP_NOW" -gt "$TIMESTAMP" ]]; then
    TIMESTAMP="$TIMESTAMP_NOW"
fi
log "Captured recovery timestamp anchor from last committed HD log block: $TIMESTAMP_DISK"
log "Using effective recovery timestamp anchor: $TIMESTAMP (disk=$TIMESTAMP_DISK, now=$TIMESTAMP_NOW)"

test_lib_run_client_cmd "$CLIENT_BIN" "$IO_TIMEOUT_SECS" finish 0 >/dev/null 2>&1 || true
if [[ -n "$gatekeeper_pid" ]]; then
    wait "$gatekeeper_pid" 2>/dev/null || true
    gatekeeper_pid=""
fi

log "Waiting ${SNAPSHOT_POST_WAIT_SECS}s after anchor before writing v2"
sleep "$SNAPSHOT_POST_WAIT_SECS"

# Snapshot — capture TSC anchor between two explicit waits.
# Recovery starts with -s TIMESTAMP and should reconstruct to the pre-v2 state.
log "Using recovery anchor timestamp: $TIMESTAMP"

# Bring the stack back up from persisted state, remount, then write v2.
start_gatekeeper "phase2" --no-init --no-zero
trace_gatekeeper_state "phase2_pre_driver"
start_driver
log "Mounting $bdus_device at $MOUNT_DIR for v2 writes"
if ! test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo mount "$bdus_device" "$MOUNT_DIR"; then
    log "Phase2 mount failed; running fsck and retrying"
    test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo fsck.ext4 -fy "$bdus_device" >/dev/null 2>&1 || true
    test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo mount "$bdus_device" "$MOUNT_DIR"
fi
mounted=1

# Phase 2 — overwrite with v2 payload (same running stack)
log "Writing v2 payload (overwriting v1)"
sudo bash -c "
    mkdir -p '$MOUNT_DIR/docs' '$MOUNT_DIR/data'
    echo 'VERSION-2'       > '$MOUNT_DIR/marker.txt'
    echo 'v2-line-one'     > '$MOUNT_DIR/docs/notes.txt'
    echo 'v2-line-two'    >> '$MOUNT_DIR/docs/notes.txt'
    echo 'shared-file-v2' > '$MOUNT_DIR/docs/shared.txt'
    echo 'v2-only-file'   > '$MOUNT_DIR/v2_only.txt'
    dd if=/dev/urandom bs=4096 count=$BULK_BLOCKS of='$MOUNT_DIR/data/v2_bulk.bin' status=none
"

log "Flushing v2 payload"
force_flush

TS_AFTER_V2_FLUSH="$("$RDTSC_BIN")"
log "Timestamp after v2 flush: $TS_AFTER_V2_FLUSH"

# Restart — shut down cleanly so gatekeeper persists log_head/log_tail via FINISH
log "Restarting stack via clean unmount + FINISH"
stop_stack_cleanly

# Phase 3 — timestamp recovery
start_gatekeeper "recovery" --no-init --no-zero
trace_gatekeeper_state "recovery_pre_driver"
start_driver "-s $TIMESTAMP --read-only"
trace_latest_recovery_summary "recovery_post_driver"
trace_recent_rejects "recovery_post_driver"

if [[ "$RECOVERY_SETTLE_SECS" -gt 0 ]]; then
    log "Waiting ${RECOVERY_SETTLE_SECS}s before fsck/remount to allow metadata timelock expiry"
    sleep "$RECOVERY_SETTLE_SECS"
fi

if [[ "$SKIP_RECOVERY_FSCK" != "1" ]]; then
    test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo fsck.ext4 -fy "$bdus_device" >/dev/null 2>&1 || true
else
    log "Skipping recovery fsck (SKIP_RECOVERY_FSCK=1)"
fi

if ! ensure_recovery_device_present; then
    exit 1
fi

log "Remounting recovered filesystem as read-only (no journal replay)"
if ! test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo mount -t ext4 -o ro,noload "$bdus_device" "$MOUNT_DIR"; then
    if [[ "$RECOVERY_FSCK_ON_MOUNT_FAIL" == "1" ]]; then
        log "Initial remount failed; running fsck and retrying"
        test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo fsck.ext4 -fy "$bdus_device" >/dev/null 2>&1 || true
        if ! test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo mount -t ext4 -o ro,noload "$bdus_device" "$MOUNT_DIR"; then
            if [[ "$RECOVERY_RETRY_SETTLE_SECS" -gt 0 ]]; then
                log "Second remount failed; waiting ${RECOVERY_RETRY_SETTLE_SECS}s for timelock settle, then retrying"
                sleep "$RECOVERY_RETRY_SETTLE_SECS"
                test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo fsck.ext4 -fy "$bdus_device" >/dev/null 2>&1 || true
                test_lib_run_with_timeout "$IO_TIMEOUT_SECS" sudo mount -t ext4 -o ro,noload "$bdus_device" "$MOUNT_DIR"
            else
                exit 1
            fi
        fi
    else
        log "Remount failed and RECOVERY_FSCK_ON_MOUNT_FAIL=0"
        exit 1
    fi
fi
mounted=1

# Verification
fail=0

check_file_contains() {
    local path="$1"
    local expected="$2"
    local actual
    actual="$(sudo cat "$MOUNT_DIR/$path" 2>/dev/null || echo "__MISSING__")"
    if [[ "$actual" != "$expected" ]]; then
        log "FAIL: $path: expected '$(printf '%s' "$expected" | head -c 80)' got '$(printf '%s' "$actual" | head -c 80)'"
        fail=1
    fi
}

check_file_absent() {
    local path="$1"
    if sudo test -e "$MOUNT_DIR/$path" 2>/dev/null; then
        log "FAIL: $path should not exist after timestamp recovery (it is v2-only)"
        fail=1
    fi
}

check_file_present() {
    local path="$1"
    if ! sudo test -e "$MOUNT_DIR/$path" 2>/dev/null; then
        log "FAIL: $path should exist after timestamp recovery (it is v1)"
        fail=1
    fi
}

log "Verifying v1 content is restored"

# Sentinel — v2 overwrote this with "VERSION-2"; recovery shows "VERSION-1"
check_file_contains "marker.txt"       "VERSION-1"
check_file_contains "docs/shared.txt"  "shared-file-v1"

# v1 notes — two lines written by v1
check_file_contains "docs/notes.txt"   "$(printf 'v1-line-one\nv1-line-two')"

# v1-only file must still be present
check_file_present "v1_only.txt"
check_file_contains "v1_only.txt" "v1-only-file"

# v1 bulk data must exist
check_file_present "data/v1_bulk.bin"

log "Verifying v2 content is absent"

# New files created by v2 must not exist (their LBAs were never in v1 l2pmap)
check_file_absent "v2_only.txt"

# v2 bulk data must not exist
check_file_absent "data/v2_bulk.bin"

if [[ "$fail" -ne 0 ]]; then
    log "FAIL: one or more checks failed (see above)"
    if [[ -f "$DRIVER_LOG" ]]; then
        log "Last driver log lines:"
        tail -n 60 "$DRIVER_LOG" | sed 's/^/[e2e_fs_timelock] driver: /'
    fi
    exit 1
fi

test_succeeded=1
log "PASS: filesystem recovered to v1 state using TSC snapshot $TIMESTAMP (v2 writes at TSC > $TIMESTAMP filtered out)"
