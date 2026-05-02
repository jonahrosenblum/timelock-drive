#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib_defaults.sh"
test_lib_init_shared_defaults "$SCRIPT_DIR"
source "$TESTS_DIR/test_lib_common.sh"
source "$TESTS_DIR/test_lib_transport.sh"

TMP_DIR="$(mktemp -d)"
test_lib_init_tmp_artifact_defaults "$TMP_DIR"

DURATION_LIST="${DURATION_LIST:-2 4}"
MAX_RETRY="${MAX_RETRY:-80}"

test_lib_setup_transport_from_env

gatekeeper_pid=""
gatekeeper_launcher_pid=""
test_succeeded=0

test_lib_setup_cleanup_trap

log() {
    printf '[e2e_timelock_duration] %s\n' "$*"
}

clean_gk_shutdown() {
    test_lib_clean_gk_shutdown gatekeeper_pid gatekeeper_launcher_pid "" "" "$IO_TIMEOUT_SECS" log
}

# Cleanup is handled by test_lib_setup_cleanup_trap

cleanup_gatekeeper_port() {
    test_lib_cleanup_gatekeeper_port_ipc_aware
}

wait_for_gatekeeper_exit() {
    local pid="$1"
    local attempts="${2:-30}"
    local delay_secs="${3:-0.1}"

    for _ in $(seq 1 "$attempts"); do
        if ! kill -0 "$pid" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$delay_secs"
    done

    return 1
}

start_gatekeeper() {
    local phase_name="$1"; shift
    test_lib_start_gatekeeper 1 1 1 "$@"
}

stop_gatekeeper() {
    clean_gk_shutdown
}

run_client() {
    test_lib_run_client_cmd "$CLIENT_BIN" "$IO_TIMEOUT_SECS" "$@"
}

start_gatekeeper_for_phase() {
    local phase="$1"

    if [[ "$phase" == "initial" ]]; then
        start_gatekeeper initial
    else
        start_gatekeeper recovery --no-init --no-zero
    fi
}

run_client_fresh_for_phase() {
    local phase="$1"
    shift
    local rc=0

    start_gatekeeper_for_phase "$phase"
    run_client "$@" || rc=$?
    stop_gatekeeper

    return "$rc"
}

expect_client_success() {
    local phase="$1"
    shift

    if ! run_client_fresh_for_phase "$phase" "$@"; then
        log "Expected success but command failed in phase $phase: $*"
        return 1
    fi
}

expect_client_failure() {
    local phase="$1"
    shift

    if run_client_fresh_for_phase "$phase" "$@"; then
        log "Expected failure but command succeeded in phase $phase: $*"
        return 1
    fi
}

extract_field() {
    local line="$1"
    local key="$2"
    awk -v key="$key" 'BEGIN{FS="[ =]"} {for(i=1;i<=NF;i++){if($i==key){print $(i+1); exit}}}' <<<"$line"
}

inspect_line() {
    local phase="$1"
    run_client_fresh_for_phase "$phase" inspect "$TEST_PBA" | tail -n 1
}

get_tsc32() {
    local phase="$1"
    run_client_fresh_for_phase "$phase" tsc32 0 | tail -n 1
}

get_log_tail() {
    local phase="$1"
    run_client_fresh_for_phase "$phase" log-tail 0 | tail -n 1
}

pick_free_test_pba() {
    local base="$1"
    local span="$2"
    local candidate
    local line
    local state

    for candidate in $(seq "$base" "$((base + span - 1))"); do
        line="$(run_client_fresh_for_phase recovery inspect "$candidate" | tail -n 1)"
        state="$(extract_field "$line" STATE)"
        if [[ "$state" == "FREE" ]]; then
            TEST_PBA="$candidate"
            log "Selected free TEST_PBA=$TEST_PBA"
            return 0
        fi
    done

    return 1
}

pick_free_log_pba() {
    local start="$1"
    local span="$2"
    local skip="$3"
    local candidate
    local line
    local state

    for candidate in $(seq "$start" "$((start + span - 1))"); do
        if [[ "$candidate" == "$skip" ]]; then
            continue
        fi
        line="$(run_client_fresh_for_phase recovery inspect "$candidate" | tail -n 1)"
        state="$(extract_field "$line" STATE)"
        if [[ "$state" == "FREE" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

next_log_pair() {
    local tail="$1"
    local next_tail

    next_tail="$(pick_free_log_pba "$((tail + 1))" 256 "$tail" || true)"
    if [[ ! "$next_tail" =~ ^[0-9]+$ ]]; then
        next_tail="$((tail + 1))"
    fi

    echo "$tail $next_tail"
}

resolve_log_pba_pair() {
    local phase="$1"
    local active_tail

    active_tail="$(get_log_tail "$phase")"
    if [[ ! "$active_tail" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    next_log_pair "$active_tail"
}

ensure_gatekeeper_built() {
    test_lib_build_gatekeeper_if_needed 'make -C "$GDIR" build >/dev/null'
}

build_protocol_client_if_needed() {
    local constants_h="$ROOT_DIR/shared/include/constants.h"
    local ipc_h="$VDIR/include/ipc_transport.h"
    local ipc_c="$VDIR/src/ipc_transport.c"
    if [[ ! -x "$CLIENT_BIN" || "$CLIENT_SRC" -nt "$CLIENT_BIN" || "$constants_h" -nt "$CLIENT_BIN" || "$ipc_h" -nt "$CLIENT_BIN" || "$ipc_c" -nt "$CLIENT_BIN" ]]; then
        gcc -O2 -g -I "$ROOT_DIR/shared/include" -I "$VDIR/include" "$CLIENT_SRC" "$VDIR/src/ipc_transport.c" -lrt -o "$CLIENT_BIN"
    fi
}

run_duration_case() {
    local duration="$1"
    local freeze_current
    local unfreeze_current
    local tail0
    local next0
    local tail1
    local next1
    local pair
    local frozen_line
    local frozen_state
    local write_succeeded
    local freeze_ok
    local unfreeze_ok
    local candidate_log_pba
    local candidate_next_pba
    local countdown_line
    local countdown_state

    log "Duration case: ${duration}s"

    expect_client_success recovery write-data "$TEST_PBA" 23

    freeze_current="$(get_tsc32 recovery)"
    if (( freeze_current % 2 != 0 )); then
        freeze_current="$((freeze_current - 1))"
    fi

    freeze_ok=0
    for round in $(seq 1 "$PROBE_ROUNDS"); do
        if ! read -r tail0 next0 < <(resolve_log_pba_pair recovery); then
            continue
        fi
        for tail_offset in $PROBE_OFFSETS; do
            candidate_log_pba="$((tail0 + tail_offset))"
            if (( candidate_log_pba < 0 )); then
                continue
            fi
            candidate_line="$(run_client_fresh_for_phase recovery inspect "$candidate_log_pba" | tail -n 1)"
            candidate_state="$(extract_field "$candidate_line" STATE)"
            if [[ "$candidate_state" != "FREE" ]]; then
                continue
            fi
            candidate_next_pba="$((candidate_log_pba + 1))"

            if ! run_client_fresh_for_phase recovery write-hdlog "$TEST_PBA" "$candidate_log_pba" "$duration" "$freeze_current" "$candidate_next_pba"; then
                continue
            fi

            frozen_line="$(inspect_line recovery)"
            frozen_state="$(extract_field "$frozen_line" STATE)"
            if [[ "$frozen_state" == "FROZEN" ]]; then
                tail0="$candidate_log_pba"
                next0="$candidate_next_pba"
                freeze_ok=1
                break 2
            fi
        done
    done

    if [[ "$freeze_ok" -ne 1 ]]; then
        log "Expected FROZEN state after freeze transition for duration=$duration"
        exit 1
    fi

    expect_client_failure recovery write-data "$TEST_PBA" 24

    # Use a small safety margin so there is a stable blocked window after unfreeze.
    unfreeze_current="$(( $(get_tsc32 recovery) + duration + 4 ))"
    if (( unfreeze_current % 2 == 0 )); then
        unfreeze_current="$((unfreeze_current + 1))"
    fi

    unfreeze_ok=0
    for round in $(seq 1 "$PROBE_ROUNDS"); do
        if ! read -r tail1 next1 < <(resolve_log_pba_pair recovery); then
            continue
        fi
        for tail_offset in $PROBE_OFFSETS; do
            candidate_log_pba="$((tail1 + tail_offset))"
            if (( candidate_log_pba < 0 )); then
                continue
            fi
            candidate_line="$(run_client_fresh_for_phase recovery inspect "$candidate_log_pba" | tail -n 1)"
            candidate_state="$(extract_field "$candidate_line" STATE)"
            if [[ "$candidate_state" != "FREE" ]]; then
                continue
            fi
            candidate_next_pba="$((candidate_log_pba + 1))"

            if ! run_client_fresh_for_phase recovery write-hdlog "$TEST_PBA" "$candidate_log_pba" 0 "$unfreeze_current" "$candidate_next_pba"; then
                continue
            fi

            countdown_line="$(inspect_line recovery)"
            countdown_state="$(extract_field "$countdown_line" STATE)"
            if [[ "$countdown_state" != "FROZEN" ]]; then
                tail1="$candidate_log_pba"
                next1="$candidate_next_pba"
                unfreeze_ok=1
                break 2
            fi
        done
    done

    if [[ "$unfreeze_ok" -ne 1 ]]; then
        log "Unfreeze transition not confirmed via inspect for duration=$duration; failing fast"
        exit 1
    fi

    write_succeeded=0
    for attempt in $(seq 1 "$MAX_RETRY"); do
        if run_client_fresh_for_phase recovery write-data "$TEST_PBA" 26; then
            write_succeeded=1
            log "Write became free after ${duration}s window on retry $attempt"
            break
        fi
        sleep "$RETRY_DELAY_SECS"
    done

    if [[ "$write_succeeded" -ne 1 ]]; then
        log "Block did not become FREE after waiting for duration=$duration"
        exit 1
    fi
}

test_lib_preflight_cleanup_full "$IO_TIMEOUT_SECS" log
ensure_gatekeeper_built
build_protocol_client_if_needed

if [[ "$TEST_PBA" == "2048" ]]; then
    if ! pick_free_test_pba 2000 256; then
        log "Failed to find a FREE test block in default candidate window"
        exit 1
    fi
fi

expect_client_success initial write-data "$TEST_PBA" 17

for duration in $DURATION_LIST; do
    run_duration_case "$duration"
done

test_succeeded=1
log "Timelock duration e2e passed for durations: $DURATION_LIST"
