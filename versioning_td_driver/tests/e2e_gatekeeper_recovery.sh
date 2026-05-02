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
TRACE_BLOCKS="${TRACE_BLOCKS:-384}"
DRIVER_ARGS="${DRIVER_ARGS:---verbose-cache}"
LONG_TRACE_TIMEOUT_SECS="${LONG_TRACE_TIMEOUT_SECS:-20}"

test_lib_setup_transport_from_env

# Recovery test block layout
BLOCK_A="$TEST_BLOCK"
BLOCK_B="$((TEST_BLOCK + 1))"
BLOCK_C="$((TEST_BLOCK + 2))"

# Runtime state
phase=""
gatekeeper_pid=""
driver_pid=""
bdus_device=""
test_succeeded=0
GATEKEEPER_LOG=""
DRIVER_LOG=""

test_lib_setup_cleanup_trap

log() {
    printf '[e2e_recovery] %s\n' "$*"
}

clean_gk_shutdown() {
    test_lib_clean_gk_shutdown gatekeeper_pid "" driver_pid bdus_device "$IO_TIMEOUT_SECS" log
}

cleanup() {
    set +e

    clean_gk_shutdown

    if [[ -n "$driver_pid" ]]; then
        test_lib_terminate_process_tree "$driver_pid" "driver"
    fi

    if [[ "$test_succeeded" -eq 1 ]]; then
        rm -rf "$TMP_DIR"
    else
        log "Preserving logs and artifacts in $TMP_DIR"
    fi
}

trap cleanup EXIT

start_gatekeeper() {
    local phase_name="$1"; shift
    phase="$phase_name"
    GATEKEEPER_LOG="$TMP_DIR/gatekeeper_${phase}.log"
    test_lib_start_gatekeeper_raw "$phase_name" "$@"
}

start_driver() {
    DRIVER_LOG="$TMP_DIR/driver_${phase}.log"

    : >"$CURRENT_BDUS_FILE"
    : >"$DRIVER_LOG"

    log "Starting versioning driver ($phase)"
    (
        cd "$VDIR"
        sudo ./bin/versioning_td_driver $DRIVER_TRANSPORT_ARG $DRIVER_ARGS >"$CURRENT_BDUS_FILE" 2>"$DRIVER_LOG"
    ) &
    driver_pid=$!

    if ! test_lib_wait_for_bdus_device "$CURRENT_BDUS_FILE" bdus_device "${DRIVER_WAIT_ATTEMPTS:-50}" "${DRIVER_WAIT_DELAY_SECS:-0.2}"; then
        log "Driver did not expose a BDUS device in phase $phase"
        return 1
    fi

    log "Driver exposed $bdus_device in phase $phase"
}

extract_payload_block() {
    local payload_file="$1"
    local block_offset="$2"
    local output_file="$3"
    dd if="$payload_file" of="$output_file" bs=4096 skip="$block_offset" count=1 status=none
}

write_trace_at() {
    local start_block="$1"
    local input_file="$2"
    local block_count="$3"
    log "Writing long trace: start=$start_block blocks=$block_count"

    set +e
    test_lib_run_with_timeout "$LONG_TRACE_TIMEOUT_SECS" \
        sudo dd if="$input_file" of="$bdus_device" bs=4096 seek="$start_block" count="$block_count" status=none
    local rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
        if [[ "$rc" -eq 124 ]]; then
            log "Long trace write timed out after ${LONG_TRACE_TIMEOUT_SECS}s"
        else
            log "Long trace write failed with exit code $rc"
        fi
        return 1
    fi
}

stop_stack() {
    clean_gk_shutdown

    if [[ -n "$driver_pid" ]]; then
        test_lib_terminate_process_tree "$driver_pid" "driver"
        driver_pid=""
    fi

    bdus_device=""
}

write_block_at() {
    local block="$1"
    local input_file="$2"
    log "Writing payload to logical block $block"
    set +e
    test_lib_run_with_timeout "$IO_TIMEOUT_SECS" \
        sudo dd if="$input_file" of="$bdus_device" bs=4096 seek="$block" count=1 status=none
    local rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
        if [[ "$rc" -eq 124 ]]; then
            log "Write timed out at block $block after ${IO_TIMEOUT_SECS}s"
        else
            log "Write failed at block $block with exit code $rc"
        fi
        return 1
    fi
}

read_block_at() {
    local block="$1"
    local output_file="$2"
    log "Reading logical block $block"
    set +e
    test_lib_run_with_timeout "$IO_TIMEOUT_SECS" \
        sudo dd if="$bdus_device" of="$output_file" bs=4096 skip="$block" count=1 status=none
    local rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
        if [[ "$rc" -eq 124 ]]; then
            log "Read timed out at block $block after ${IO_TIMEOUT_SECS}s"
        else
            log "Read failed at block $block with exit code $rc"
        fi
        return 1
    fi
}

assert_files_equal() {
    local expected="$1"
    local actual="$2"
    local label="$3"

    if ! cmp -s "$expected" "$actual"; then
        log "$label failed"
        return 1
    fi
}

query_identify_state() {
    local output=""
    output="$(test_lib_run_client_cmd "$CLIENT_BIN" "$IO_TIMEOUT_SECS" peek-identify 0 2>/dev/null || true)"
    local head=""
    local tail=""
    head="$(echo "$output" | sed -n 's/^IDENTIFY head=\([0-9][0-9]*\) tail=.*/\1/p')"
    tail="$(echo "$output" | sed -n 's/^IDENTIFY head=[0-9][0-9]* tail=\([0-9][0-9]*\)$/\1/p')"
    if [[ -z "$head" || -z "$tail" ]]; then
        log "Unable to parse IDENTIFY output: $output"
        return 1
    fi
    echo "$head $tail"
}

test_lib_preflight_cleanup_full "$IO_TIMEOUT_SECS" log
log "Building gatekeeper, host driver, and protocol test client"
test_lib_build_gatekeeper_if_needed 'make -C "$GDIR" build >/dev/null'
make -C "$VDIR" versioning_td_driver >/dev/null
gcc -O2 -g -I "$ROOT_DIR/shared/include" -I "$VDIR/include" "$CLIENT_SRC" "$VDIR/src/ipc_transport.c" -lrt -o "$CLIENT_BIN"

# Payloads and expected sample blocks
payload_trace="$TMP_DIR/payload_trace.bin"

expected_first="$TMP_DIR/expected_first.bin"
expected_mid="$TMP_DIR/expected_mid.bin"
expected_last="$TMP_DIR/expected_last.bin"

recovered_first_1="$TMP_DIR/recovered_first_recovery1.bin"
recovered_mid_1="$TMP_DIR/recovered_mid_recovery1.bin"
recovered_last_1="$TMP_DIR/recovered_last_recovery1.bin"

recovered_first_2="$TMP_DIR/recovered_first_recovery2.bin"
recovered_mid_2="$TMP_DIR/recovered_mid_recovery2.bin"
recovered_last_2="$TMP_DIR/recovered_last_recovery2.bin"

trace_mid_offset="$((TRACE_BLOCKS / 2))"
trace_last_offset="$((TRACE_BLOCKS - 1))"

head -c "$((TRACE_BLOCKS * 4096))" /dev/urandom >"$payload_trace"

extract_payload_block "$payload_trace" 0 "$expected_first"
extract_payload_block "$payload_trace" "$trace_mid_offset" "$expected_mid"
extract_payload_block "$payload_trace" "$trace_last_offset" "$expected_last"

# Phase 1: write a longer trace and verify in-session reads
start_gatekeeper initial
start_driver

log "Phase 1: writing long trace workload"
if ! write_trace_at "$BLOCK_A" "$payload_trace" "$TRACE_BLOCKS"; then
    log "Phase 1 long trace write failed"
    exit 1
fi

read_block_at "$BLOCK_A" "$recovered_first_1"
read_block_at "$((BLOCK_A + trace_mid_offset))" "$recovered_mid_1"
read_block_at "$((BLOCK_A + trace_last_offset))" "$recovered_last_1"

assert_files_equal "$expected_first" "$recovered_first_1" "Phase 1 first block roundtrip"
assert_files_equal "$expected_mid" "$recovered_mid_1" "Phase 1 middle block roundtrip"
assert_files_equal "$expected_last" "$recovered_last_1" "Phase 1 last block roundtrip"

stop_stack

# Phase 2: first recovery - verify long-trace data and capture rebuilt cache contents
start_gatekeeper recovery1 --no-init --no-zero
read -r recovery1_head recovery1_tail < <(query_identify_state)
start_driver

log "Phase 2: verify recovered long-trace samples"
read_block_at "$BLOCK_A" "$recovered_first_1"
read_block_at "$((BLOCK_A + trace_mid_offset))" "$recovered_mid_1"
read_block_at "$((BLOCK_A + trace_last_offset))" "$recovered_last_1"

assert_files_equal "$expected_first" "$recovered_first_1" "Recovery 1 first block"
assert_files_equal "$expected_mid" "$recovered_mid_1" "Recovery 1 middle block"
assert_files_equal "$expected_last" "$recovered_last_1" "Recovery 1 last block"

stop_stack

# Phase 3: second recovery - rebuilt cache map should be identical to phase 2
start_gatekeeper recovery2 --no-init --no-zero
read -r recovery2_head recovery2_tail < <(query_identify_state)
start_driver
if [[ "$recovery2_head" != "$recovery1_head" || "$recovery2_tail" != "$recovery1_tail" ]]; then
    log "Recovery 2 IDENTIFY state differs from Recovery 1: recovery1 head=$recovery1_head tail=$recovery1_tail recovery2 head=$recovery2_head tail=$recovery2_tail"
    exit 1
fi

log "Phase 3: verify long-trace samples after second restart"
read_block_at "$BLOCK_A" "$recovered_first_2"
read_block_at "$((BLOCK_A + trace_mid_offset))" "$recovered_mid_2"
read_block_at "$((BLOCK_A + trace_last_offset))" "$recovered_last_2"

assert_files_equal "$expected_first" "$recovered_first_2" "Recovery 2 first block"
assert_files_equal "$expected_mid" "$recovered_mid_2" "Recovery 2 middle block"
assert_files_equal "$expected_last" "$recovered_last_2" "Recovery 2 last block"

stop_stack

test_succeeded=1
log "Recovery test passed (long trace data integrity + IDENTIFY state stability across two restarts)"