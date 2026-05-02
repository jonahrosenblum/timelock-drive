#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib_defaults.sh"
test_lib_init_shared_defaults "$SCRIPT_DIR"
source "$TESTS_DIR/test_lib_common.sh"
source "$TESTS_DIR/test_lib_transport.sh"
TMP_DIR="$(mktemp -d)"
test_lib_init_tmp_artifact_defaults "$TMP_DIR"
TEST_BLOCK="${TEST_BLOCK:-250000}"
DRIVER_ARGS="${DRIVER_ARGS:-}"

test_lib_setup_transport_from_env

gatekeeper_pid=""
driver_pid=""
bdus_device=""
test_succeeded=0

test_lib_setup_cleanup_trap

log() {
    printf '[e2e_sync] %s\n' "$*"
}

clean_gk_shutdown() {
    test_lib_clean_gk_shutdown gatekeeper_pid "" driver_pid bdus_device "$IO_TIMEOUT_SECS" log
}

# Cleanup is handled by test_lib_setup_cleanup_trap

cleanup_gatekeeper_port() {
    test_lib_cleanup_gatekeeper_port_ipc_aware
}

start_gatekeeper() {
    local phase_name="$1"; shift
    if ! cleanup_gatekeeper_port; then
        log "Gatekeeper port $GATEKEEPER_PORT did not clear before phase $phase_name"
        return 1
    fi
    test_lib_start_gatekeeper_raw "$phase_name" "$@"
}

check_sync_plumbing() {
    local constants_h="$ROOT_DIR/shared/include/constants.h"
    local driver_c="$VDIR/src/versioning_td_driver.c"

    grep -Eq "\\.flush[[:space:]]*=" "$driver_c"
    grep -Eq "disk_cmd[[:space:]]*=[[:space:]]*SYNC" "$driver_c"
    grep -Eq "\\bSYNC\\b" "$constants_h"
}

kill_stack_uncleanly() {
    test_lib_kill_stack_uncleanly gatekeeper_pid driver_pid bdus_device
}

test_lib_preflight_cleanup_full "$IO_TIMEOUT_SECS" log
log "Building gatekeeper and host driver"
test_lib_build_gatekeeper_if_needed 'make -C "$GDIR" build >/dev/null'
make -C "$VDIR" versioning_td_driver >/dev/null

payload_file="$TMP_DIR/payload.bin"
recovered_file="$TMP_DIR/recovered.bin"

head -c 4096 /dev/urandom >"$payload_file"

if ! check_sync_plumbing; then
    log "Required SYNC plumbing is missing"
    exit 1
fi

if ! start_gatekeeper initial; then
    log "Gatekeeper did not start cleanly for initial sync-durability phase"
    exit 1
fi
if ! test_lib_start_driver "initial"; then
    log "Driver did not start cleanly for initial sync-durability phase"
    exit 1
fi

log "Writing one block and requesting explicit flush"
sudo dd if="$payload_file" of="$bdus_device" bs=4096 seek="$TEST_BLOCK" count=1 conv=fsync status=none
sudo sync "$bdus_device" >/dev/null 2>&1 || true
sudo sync

log "Simulating crash (unclean stop)"
kill_stack_uncleanly

if ! start_gatekeeper recovery --no-init --no-zero; then
    log "Gatekeeper did not restart cleanly after crash+restart sequence"
    exit 1
fi
if ! test_lib_start_driver "recovery"; then
    log "Driver did not restart cleanly after crash+restart sequence"
    exit 1
fi

log "Reading block after crash+restart"
sudo dd if="$bdus_device" of="$recovered_file" bs=4096 skip="$TEST_BLOCK" count=1 status=none

if ! cmp -s "$payload_file" "$recovered_file"; then
    log "Sync durability check failed after crash+restart"
    exit 1
fi

log "PASS: sync durability preserved data across crash+restart"
test_succeeded=1
