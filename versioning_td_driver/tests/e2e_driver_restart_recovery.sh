#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib_defaults.sh"
test_lib_init_shared_defaults "$SCRIPT_DIR"
source "$TESTS_DIR/test_lib_common.sh"
source "$TESTS_DIR/test_lib_transport.sh"
TMP_DIR="$(mktemp -d)"
test_lib_init_tmp_artifact_defaults "$TMP_DIR"

BLOCK_SIZE=4096
LOG_TAIL_START=$(((BLOCK_SIZE - (3 * 4)) / 4 - 2))
LOG_TAIL_ONE=$((LOG_TAIL_START * 2))
LOG_TAIL_TWO=$((LOG_TAIL_START * 3))
TARGET_PBA="${TARGET_PBA:-2000}"
TEST_BLOCK="${TEST_BLOCK:-2620500}"
LOG_CURRENT_TIME="${LOG_CURRENT_TIME:-100}"
CASE_FILTER="${CASE_FILTER:-}"
DRIVER_ARGS="${DRIVER_ARGS:-}"
GK_TRACE_IO="${GK_TRACE_IO:-1}"
DRIVER_TRACE_FILE="${DRIVER_TRACE_FILE:-/tmp/timelockdriver.log}"

test_lib_setup_transport_from_env

gatekeeper_pid=""
gatekeeper_listener_pid=""
driver_pid=""
bdus_device=""
phase=""
test_succeeded=0
zero_block="$TMP_DIR/zero_block.bin"

log() {
    printf '[e2e_driver_restart] %s\n' "$*" >&2
}

dump_phase_diagnostics() {
    local label="${1:-$phase}"
    log "Diagnostics for phase=$label"

    if [[ -f "$TMP_DIR/gatekeeper_${label}.log" ]]; then
        echo "--- gatekeeper_${label}.log (tail) ---"
        tail -n 120 "$TMP_DIR/gatekeeper_${label}.log" || true
    fi

    if [[ -f "$TMP_DIR/driver_${label}.log" ]]; then
        echo "--- driver_${label}.log (tail) ---"
        tail -n 120 "$TMP_DIR/driver_${label}.log" || true
    fi

    if [[ -f "$TMP_DIR/client_${label}.log" ]]; then
        echo "--- client_${label}.log (tail) ---"
        tail -n 120 "$TMP_DIR/client_${label}.log" || true
    fi

    if [[ -f "$DRIVER_TRACE_FILE" ]]; then
        echo "--- $(basename "$DRIVER_TRACE_FILE") (tail) ---"
        tail -n 120 "$DRIVER_TRACE_FILE" || true
    fi
}

clean_gk_shutdown() {
    test_lib_clean_gk_shutdown gatekeeper_pid "" driver_pid bdus_device "$IO_TIMEOUT_SECS" log
    gatekeeper_listener_pid=""
}

# Cleanup is handled by test_lib_setup_cleanup_trap

get_driver_process_pid() {
    pgrep -f '(^|/| )versioning_td_driver( |$)' | head -n 1
}



wait_for_gatekeeper_listener() {
    if [[ "$E2E_USE_IPC" == "1" ]]; then
        test_lib_wait_for_gatekeeper_ready "ipc" "$GDIR/gatekeeper/main-rust/target/release/main" "10107" "/dev/shm/timelocked_ipc" gatekeeper_listener_pid 50 0.1
        return $?
    fi

    test_lib_wait_for_gatekeeper_ready "socket" "$GDIR/gatekeeper/main-rust/target/release/main" "10107" "/dev/shm/timelocked_ipc" gatekeeper_listener_pid 50 0.1
}

start_gatekeeper() {
    local phase_name="$1"
    shift

    phase="$phase_name"
    log "Starting gatekeeper ($phase)"
    : >"$TMP_DIR/client_${phase}.log"
    sudo env RUST_BACKTRACE=1 GK_TRACE_IO="$GK_TRACE_IO" "$GDIR/gatekeeper/main-rust/target/release/main" --timelockdrive "$GK_TRANSPORT_ARG" "$@" >"$TMP_DIR/gatekeeper_${phase}.log" 2>&1 &
    gatekeeper_pid=$!
    gatekeeper_listener_pid=""

    if ! wait_for_gatekeeper_listener; then
        log "Gatekeeper failed to start in phase $phase"
        dump_phase_diagnostics "$phase"
        return 1
    fi
}

start_driver() {
    : >"$CURRENT_BDUS_FILE"
    : >"$TMP_DIR/driver_${phase}.log"
    sudo sh -c ": > '$DRIVER_TRACE_FILE'"

    log "Starting versioning driver ($phase)"
    (
        sudo "$VDIR/bin/versioning_td_driver" $DRIVER_TRANSPORT_ARG $DRIVER_ARGS >"$CURRENT_BDUS_FILE" 2>"$TMP_DIR/driver_${phase}.log"
    ) &
    driver_pid=$!

    if ! test_lib_wait_for_bdus_device "$CURRENT_BDUS_FILE" bdus_device "${DRIVER_WAIT_ATTEMPTS:-50}" "${DRIVER_WAIT_DELAY_SECS:-0.2}"; then
        log "Driver did not expose a BDUS device in phase $phase"
        dump_phase_diagnostics "$phase"
        return 1
    fi

    local live_pid=""
    live_pid="$(get_driver_process_pid || true)"
    if [[ -n "$live_pid" ]]; then
        driver_pid="$live_pid"
    fi

    log "Driver exposed $bdus_device in phase $phase"
}

stop_stack() {
    clean_gk_shutdown

    if [[ -n "$driver_pid" ]]; then
        test_lib_terminate_process_tree "$driver_pid" "driver"
        driver_pid=""
    fi

    if [[ "$E2E_USE_IPC" == "1" ]]; then
        sudo rm -f /dev/shm/timelocked_ipc >/dev/null 2>&1 || true
    fi
}

parse_identify_output() {
    local output="$1"
    local expected_head="$2"
    local expected_tail="$3"

    local actual_head actual_tail
    actual_head="$(echo "$output" | sed -n 's/^IDENTIFY head=\([0-9][0-9]*\) tail=.*/\1/p')"
    actual_tail="$(echo "$output" | sed -n 's/^IDENTIFY head=[0-9][0-9]* tail=\([0-9][0-9]*\)$/\1/p')"

    if [[ -z "$actual_head" || -z "$actual_tail" ]]; then
        log "Unable to parse IDENTIFY output: $output"
        return 1
    fi

    if [[ "$actual_head" != "$expected_head" || "$actual_tail" != "$expected_tail" ]]; then
        log "Unexpected IDENTIFY state: got head=$actual_head tail=$actual_tail expected head=$expected_head tail=$expected_tail"
        return 1
    fi
}

assert_zero_read() {
    local label="$1"
    local output_file="$TMP_DIR/${label}_zero.bin"

    set +e
    test_lib_run_with_timeout "$IO_TIMEOUT_SECS" \
        sudo dd if="$bdus_device" of="$output_file" bs=$BLOCK_SIZE skip="$TEST_BLOCK" count=1 status=none
    local rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
        log "$label zero-read failed with exit code $rc"
        return 1
    fi

    if ! cmp -s "$zero_block" "$output_file"; then
        log "$label zero-read returned unexpected data"
        return 1
    fi
}

run_client_action() {
    local client_cmd=("$CLIENT_BIN" "$@")
    local client_out=""

    if [[ "$E2E_USE_IPC" == "1" ]]; then
        client_cmd=(sudo env E2E_USE_IPC=1 "$CLIENT_BIN" "$@")
    fi

    log "Client action ($phase): ${*}"
    set +e
    client_out="$(test_lib_run_with_timeout "$IO_TIMEOUT_SECS" "${client_cmd[@]}" 2>>"$TMP_DIR/client_${phase}.log")"
    local rc=$?
    set -e

    if [[ -n "$client_out" ]]; then
        printf '%s\n' "$client_out" >>"$TMP_DIR/client_${phase}.log"
    fi

    if [[ "$rc" -ne 0 ]]; then
        log "Client action failed rc=$rc phase=$phase cmd=$*"
        dump_phase_diagnostics "$phase"
        return "$rc"
    fi

    if [[ -n "$client_out" ]]; then
        printf '%s\n' "$client_out"
    fi

    if [[ "$E2E_USE_IPC" == "1" ]]; then
        :
    fi
    if [[ -n "$gatekeeper_pid" ]]; then
        if ! test_lib_wait_for_process_exit "$gatekeeper_pid" 50 0.2; then
            log "Gatekeeper did not exit after client action in phase $phase"
            dump_phase_diagnostics "$phase"
            return 1
        fi
        gatekeeper_pid=""
        gatekeeper_listener_pid=""
    fi
}

prepare_case_state() {
    local case_label="$1"

    case "$case_label" in
        no_growth)
            start_gatekeeper "${case_label}_seed"
            local identify_out
            identify_out="$(run_client_action identify 0)"
            parse_identify_output "$identify_out" "$LOG_TAIL_START" "$LOG_TAIL_START"
            ;;
        one_growth)
            start_gatekeeper "${case_label}_seed"
            run_client_action write-hdlog "$TARGET_PBA" "$LOG_TAIL_START" 1 "$LOG_CURRENT_TIME" "$LOG_TAIL_ONE" >/dev/null
            ;;
        two_growth)
            start_gatekeeper "${case_label}_seed1"
            run_client_action write-hdlog "$TARGET_PBA" "$LOG_TAIL_START" 1 "$LOG_CURRENT_TIME" "$LOG_TAIL_ONE" >/dev/null
            start_gatekeeper "${case_label}_seed2" --no-init --no-zero
            run_client_action write-hdlog "$TARGET_PBA" "$LOG_TAIL_ONE" 1 "$((LOG_CURRENT_TIME + 1))" "$LOG_TAIL_TWO" >/dev/null
            ;;
        *)
            log "Unknown case $case_label"
            return 1
            ;;
    esac
}

verify_persisted_state() {
    local case_label="$1"
    local expected_tail="$2"

    start_gatekeeper "${case_label}_verify" --no-init --no-zero
    local identify_out
    identify_out="$(run_client_action identify 0)"
    parse_identify_output "$identify_out" "$LOG_TAIL_START" "$expected_tail"
}

run_restart_case() {
    local case_label="$1"
    local expected_tail="$2"

    if [[ -n "$CASE_FILTER" && "$CASE_FILTER" != "$case_label" ]]; then
        return 0
    fi

    log "Running case $case_label: expected_tail=$expected_tail"

    prepare_case_state "$case_label"
    verify_persisted_state "$case_label" "$expected_tail"

    start_gatekeeper "${case_label}_recovery" --no-init --no-zero
    start_driver
    # Do not run standalone client protocol checks after driver start: the
    # active driver connection can serialize/consume the checker interface and
    # cause client-side hangs. Recovery state is already verified in
    # verify_persisted_state before starting the driver.
    assert_zero_read "${case_label}_recovery"
    stop_stack
}

test_lib_preflight_cleanup_full "$IO_TIMEOUT_SECS" log
log "Building gatekeeper, host driver, and protocol test client"
test_lib_build_gatekeeper_if_needed 'make -C "$GDIR" build >/dev/null'
make -C "$VDIR" versioning_td_driver >/dev/null
gcc -O2 -g -I "$ROOT_DIR/shared/include" -I "$VDIR/include" "$CLIENT_SRC" "$VDIR/src/ipc_transport.c" -lrt -o "$CLIENT_BIN"
head -c "$BLOCK_SIZE" /dev/zero >"$zero_block"

run_restart_case no_growth "$LOG_TAIL_START"
run_restart_case one_growth "$LOG_TAIL_ONE"
run_restart_case two_growth "$LOG_TAIL_TWO"

test_succeeded=1
log "Driver restart recovery test passed"