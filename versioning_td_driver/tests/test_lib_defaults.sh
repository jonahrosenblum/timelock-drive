#!/usr/bin/env bash

# Shared defaults for e2e/perf scripts.
# Conservative defaults: universally reused path/bootstrap values.
# Broader defaults: common knobs and artifact paths that scripts can override.

test_lib_init_conservative_defaults() {
    local script_dir="${1:-$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)}"

    : "${TESTS_DIR:=$script_dir}"
    : "${ROOT_DIR:=$(cd "$TESTS_DIR/../.." && pwd)}"
    : "${VDIR:=$ROOT_DIR/versioning_td_driver}"
    : "${GDIR:=$ROOT_DIR/gatekeeper}"

    : "${CLIENT_SRC:=$VDIR/tests/timelock_state_client.c}"
    : "${CLIENT_BIN:=$VDIR/tests/timelock_state_client}"
    : "${CURRENT_BDUS_FILE:=$VDIR/current_bdus.txt}"
    : "${GATEKEEPER_BIN:=$GDIR/gatekeeper/main-rust/target/release/main}"
    : "${GK_MAIN_RS:=$GDIR/gatekeeper/main-rust/src/main.rs}"

    : "${E2E_USE_IPC:=0}"
    : "${GATEKEEPER_PORT:=10107}"
    : "${IO_TIMEOUT_SECS:=20}"
    : "${TIMEOUT_KILL_AFTER_SECS:=5}"
}

test_lib_init_broader_defaults() {
    : "${DRIVER_ARGS:=}"
    : "${FORMAT_TIMEOUT_SECS:=240}"
    : "${FS_SIZE_BLOCKS:=32768}"
    : "${SKIP_RECOVERY_FSCK:=1}"
    : "${RECOVERY_FSCK_ON_MOUNT_FAIL:=1}"
    : "${RECOVERY_SETTLE_SECS:=0}"
    : "${RECOVERY_RETRY_SETTLE_SECS:=65}"
    : "${GATEKEEPER_VERBOSE:=0}"
    : "${KEEP_TMP_DIR:=0}"

    : "${TEST_BLOCK:=250000}"
    : "${TEST_BLOCK_BASE:=250000}"
    : "${TEST_PBA:=2048}"
    : "${TARGET_PBA:=2000}"
    : "${LOG_CURRENT_TIME:=100}"
    : "${NUM_WRITES:=10000}"
    : "${WRITE_BATCH_MAX:=256}"
    : "${GK_TRACE_WRITES:=1}"
    : "${APPLY_GK_TRACE_PATCH:=1}"

    : "${PROBE_ROUNDS:=1}"
    : "${PROBE_OFFSETS:=0}"
    : "${MAX_RETRY:=16}"
    : "${RETRY_DELAY_SECS:=0.25}"

    : "${WARMUP_BLOCKS:=5}"
    : "${MEASURE_BLOCKS:=100000}"
    : "${GAP_BLOCKS:=1024}"
    : "${BLOCK_SIZE:=4096}"
    : "${SAMPLE_HZ:=4000}"
    : "${PERF_DURATION_SECS:=20}"
    : "${PERF_ARM_DELAY_SECS:=0.5}"
    : "${DD_TIMEOUT_SECS:=300}"
    : "${PERF_WAIT_TIMEOUT_SECS:=45}"
    : "${BUILD_STACK:=1}"
    : "${GATEKEEPER_ARGS:=--timelockdrive --ipc}"
    : "${IPC_SHM_PATH:=/dev/shm/timelocked_ipc}"
}

test_lib_init_tmp_artifact_defaults() {
    local tmp_dir="${1:-${TMP_DIR:-}}"
    if [[ -z "$tmp_dir" ]]; then
        return 0
    fi

    : "${MOUNT_DIR:=$tmp_dir/mnt}"
    : "${TRACE_FILE:=/tmp/timelockdriver.log}"

    : "${GATEKEEPER_LOG:=$tmp_dir/gatekeeper.log}"
    : "${DRIVER_LOG:=$tmp_dir/driver.log}"
    : "${WARMUP_LOG:=$tmp_dir/warmup_dd.log}"
    : "${MEASURE_LOG:=$tmp_dir/measured_dd.log}"
}

test_lib_init_shared_defaults() {
    test_lib_init_conservative_defaults "$@"
    test_lib_init_broader_defaults
}
