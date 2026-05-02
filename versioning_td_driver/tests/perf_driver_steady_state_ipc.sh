#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib_defaults.sh"
test_lib_init_shared_defaults "$SCRIPT_DIR"
source "$TESTS_DIR/test_lib_common.sh"

TMP_DIR="${TMP_DIR:-$(mktemp -d /tmp/driver_steady_state.XXXXXX)}"
test_lib_init_tmp_artifact_defaults "$TMP_DIR"
PERF_DATA="$TMP_DIR/driver.perf.data"
PERF_REPORT="$TMP_DIR/driver.perf.report.txt"
PERF_RECORD_LOG="$TMP_DIR/perf_record.log"

IO_TIMEOUT_SECS="${IO_TIMEOUT_SECS:-40}"
TIMEOUT_KILL_AFTER_SECS="${TIMEOUT_KILL_AFTER_SECS:-8}"
WARMUP_BLOCKS="${WARMUP_BLOCKS:-2048}"
MEASURE_BLOCKS="${MEASURE_BLOCKS:-4096}"
GAP_BLOCKS="${GAP_BLOCKS:-1024}"
BLOCK_SIZE="${BLOCK_SIZE:-4096}"
SAMPLE_HZ="${SAMPLE_HZ:-199}"
PERF_DURATION_SECS="${PERF_DURATION_SECS:-20}"
PERF_ARM_DELAY_SECS="${PERF_ARM_DELAY_SECS:-0.5}"
DD_TIMEOUT_SECS="${DD_TIMEOUT_SECS:-300}"
PERF_WAIT_TIMEOUT_SECS="${PERF_WAIT_TIMEOUT_SECS:-45}"
BUILD_STACK="${BUILD_STACK:-1}"
GATEKEEPER_ARGS="${GATEKEEPER_ARGS:---timelockdrive --ipc}"
DRIVER_ARGS="${DRIVER_ARGS:---ipc}"

gatekeeper_pid=""
gatekeeper_launcher_pid=""
driver_pid=""
perf_pid=""
dd_pid=""
bdus_device=""

log() {
    printf '[driver_steady_state] %s\n' "$*"
}

wait_for_pid_exit() {
    local pid="$1"
    local label="$2"
    local timeout_secs="$3"
    local waited=0

    if [[ -z "$pid" ]]; then
        return 0
    fi

    while sudo kill -0 "$pid" >/dev/null 2>&1; do
        if (( waited >= timeout_secs * 10 )); then
            log "${label} did not finish within ${timeout_secs}s; terminating"
            test_lib_terminate_process_tree "$pid" "$label"
            return 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done

    return 0
}

clean_gk_shutdown() {
    test_lib_clean_gk_shutdown gatekeeper_pid gatekeeper_launcher_pid driver_pid bdus_device "$IO_TIMEOUT_SECS" log
}

cleanup() {
    set +e

    sudo rm -f "$IPC_SHM_PATH" >/dev/null 2>&1 || true

    if [[ -n "$perf_pid" ]]; then
        test_lib_terminate_process_tree "$perf_pid" "perf"
    fi

    if [[ -n "$dd_pid" ]]; then
        test_lib_terminate_process_tree "$dd_pid" "dd"
    fi

    # Call standard cleanup handler for gatekeeper/driver/IPC/artifact cleanup
    test_lib_script_cleanup_handler
}

trap cleanup EXIT

get_driver_process_pid() {
    pgrep -f '(^|/| )versioning_td_driver( |$)' | head -n 1
}

wait_for_gatekeeper_ipc_ready() {
    test_lib_wait_for_gatekeeper_ready "ipc" "$GATEKEEPER_BIN" "$GATEKEEPER_PORT" "$IPC_SHM_PATH" gatekeeper_pid 80 0.1
}

wait_for_driver_ready() {
    for _ in $(seq 1 80); do
        local live_pid=""
        live_pid="$(get_driver_process_pid || true)"
        if [[ -n "$live_pid" ]]; then
            driver_pid="$live_pid"
            return 0
        fi
        sleep 0.1
    done
    return 1
}

build_stack() {
    if [[ "$BUILD_STACK" != "1" ]]; then
        return 0
    fi

    log "Building gatekeeper and host driver"
    test_lib_build_gatekeeper_if_needed 'make -C "$GDIR" build >/dev/null'
    make -C "$VDIR" versioning_td_driver >/dev/null
}

start_stack() {
    : > "$CURRENT_BDUS_FILE"
    : > "$GATEKEEPER_LOG"
    : > "$DRIVER_LOG"

    log "Starting gatekeeper"
    test_lib_cleanup_ipc_shm "$IPC_SHM_PATH"
    sudo env RUST_BACKTRACE=1 "$GATEKEEPER_BIN" $GATEKEEPER_ARGS > "$GATEKEEPER_LOG" 2>&1 &
    gatekeeper_launcher_pid=$!

    if ! wait_for_gatekeeper_ipc_ready; then
        log "Gatekeeper failed to initialize IPC transport"
        if [[ -s "$GATEKEEPER_LOG" ]]; then
            tail -n 80 "$GATEKEEPER_LOG"
        fi
        exit 1
    fi

    log "Gatekeeper IPC runtime PID is $gatekeeper_pid"

    log "Starting versioning driver"
    (
        cd "$VDIR"
        sudo ./bin/versioning_td_driver $DRIVER_ARGS > "$CURRENT_BDUS_FILE" 2> "$DRIVER_LOG"
    ) &
    driver_pid=$!

    if ! wait_for_driver_ready; then
        log "Driver process did not start"
        exit 1
    fi
    log "Driver PID is $driver_pid"

    if ! test_lib_wait_for_bdus_device "$CURRENT_BDUS_FILE" bdus_device 80 0.25; then
        log "Driver did not expose a BDUS device"
        exit 1
    fi

    log "Driver exposed $bdus_device"
}

run_dd() {
    local start_block="$1"
    local block_count="$2"
    local output_log="$3"

    test_lib_run_with_timeout "$DD_TIMEOUT_SECS" \
        sudo dd if=/dev/zero of="$bdus_device" bs="$BLOCK_SIZE" seek="$start_block" count="$block_count" status=progress oflag=direct 2> "$output_log"
}

warmup_phase() {
    log "Warm-up phase: writing ${WARMUP_BLOCKS} blocks starting at 0"
    run_dd 0 "$WARMUP_BLOCKS" "$WARMUP_LOG"
    sudo sync "$bdus_device" >/dev/null 2>&1 || true
    sudo sync
}

measure_phase() {
    local measure_start_block=$((WARMUP_BLOCKS + GAP_BLOCKS))

    log "Measured phase: writing ${MEASURE_BLOCKS} blocks starting at ${measure_start_block}"
    log "Starting sustained measured dd workload"

    (
        run_dd "$measure_start_block" "$MEASURE_BLOCKS" "$MEASURE_LOG"
    ) &
    dd_pid=$!

    sleep "$PERF_ARM_DELAY_SECS"

    log "Recording driver CPU profile for ${PERF_DURATION_SECS}s at ${SAMPLE_HZ} Hz (pid=${driver_pid})"
    : > "$PERF_RECORD_LOG"
    sudo perf record -F "$SAMPLE_HZ" -g -p "$driver_pid" -o "$PERF_DATA" -- sleep "$PERF_DURATION_SECS" >"$PERF_RECORD_LOG" 2>&1 &
    perf_pid=$!

    log "Waiting for perf recorder completion (timeout=${PERF_WAIT_TIMEOUT_SECS}s)"
    if ! wait_for_pid_exit "$perf_pid" "perf recorder" "$PERF_WAIT_TIMEOUT_SECS"; then
        test_lib_terminate_process_tree "$dd_pid" "measured dd"
        exit 1
    fi

    if ! wait "$perf_pid"; then
        log "perf record command failed"
        if [[ -s "$PERF_RECORD_LOG" ]]; then
            log "perf record stderr/stdout:"
            tail -n 80 "$PERF_RECORD_LOG"
        fi
        if sudo kill -0 "$driver_pid" >/dev/null 2>&1; then
            log "driver process is still alive after perf failure"
        else
            log "driver process exited before/during perf recording"
            if wait "$driver_pid" 2>/dev/null; then
                log "driver exit status: 0"
            else
                log "driver exit status: $?"
            fi
            if [[ -n "$gatekeeper_pid" ]]; then
                if sudo kill -0 "$gatekeeper_pid" >/dev/null 2>&1; then
                    log "gatekeeper process is still alive"
                else
                    if wait "$gatekeeper_launcher_pid" 2>/dev/null; then
                        log "gatekeeper launcher exit status: 0"
                    else
                        log "gatekeeper launcher exit status: $?"
                    fi
                fi
            fi
        fi
        test_lib_terminate_process_tree "$dd_pid" "measured dd"
        exit 1
    fi
    perf_pid=""

    log "Measured profiling window complete; stopping dd workload"
    test_lib_terminate_process_tree "$dd_pid" "measured dd"

    if ! wait "$dd_pid"; then
        log "Measured dd ended by cancellation after profiling window (expected)"
    fi
    dd_pid=""

    if ! sudo perf report --stdio -i "$PERF_DATA" > "$PERF_REPORT" 2>&1; then
        log "perf report failed"
        exit 1
    fi

    if grep -qi 'no samples' "$PERF_REPORT"; then
        log "Perf data has no samples for driver PID $driver_pid"
        exit 1
    fi
}

build_stack
test_lib_cleanup_ipc_shm "$IPC_SHM_PATH"
test_lib_preflight_cleanup_full "$IO_TIMEOUT_SECS" log 'gatekeeper/main-rust/target/release/main|/bin/versioning_td_driver|dd if=/dev/zero of=/dev/bdus-'
start_stack
warmup_phase
measure_phase

log "Steady-state benchmark complete"
log "Gatekeeper log: $GATEKEEPER_LOG"
log "Driver log: $DRIVER_LOG"
log "Warm-up dd log: $WARMUP_LOG"
log "Measured dd log: $MEASURE_LOG"
log "Perf data: $PERF_DATA"
log "Perf report: $PERF_REPORT"
log "Perf record log: $PERF_RECORD_LOG"
