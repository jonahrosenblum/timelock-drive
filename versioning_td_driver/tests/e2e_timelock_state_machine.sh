#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib_defaults.sh"
test_lib_init_shared_defaults "$SCRIPT_DIR"
source "$TESTS_DIR/test_lib_common.sh"
source "$TESTS_DIR/test_lib_transport.sh"

TMP_DIR="$(mktemp -d)"
test_lib_init_tmp_artifact_defaults "$TMP_DIR"

LOG_PBA_0="${LOG_PBA_0:-1019}"
LOG_PBA_1="${LOG_PBA_1:-1019}"
LOG_PBA_2="${LOG_PBA_2:-1019}"
FREEZE_KEEP="${FREEZE_KEEP:-2}"
MAX_RETRY="${MAX_RETRY:-16}"

test_lib_setup_transport_from_env

gatekeeper_pid=""
gatekeeper_launcher_pid=""
test_succeeded=0

test_lib_setup_cleanup_trap

log() {
    printf '[e2e_timelock] %s\n' "$*"
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

get_tsc32() {
    local phase="$1"
    run_client_fresh_for_phase "$phase" tsc32 0 | tail -n 1
}

get_log_tail() {
    local phase="$1"
    run_client_fresh_for_phase "$phase" log-tail 0 | tail -n 1
}

inspect_line() {
    local phase="$1"
    run_client_fresh_for_phase "$phase" inspect "$TEST_PBA" | tail -n 1
}

inspect_pba_line() {
    local phase="$1"
    local pba="$2"
    run_client_fresh_for_phase "$phase" inspect "$pba" | tail -n 1
}

extract_field() {
    local line="$1"
    local key="$2"
    awk -v key="$key" 'BEGIN{FS="[ =]"} {for(i=1;i<=NF;i++){if($i==key){print $(i+1); exit}}}' <<<"$line"
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

ensure_gatekeeper_built() {
    test_lib_build_gatekeeper_if_needed 'make -C "$GDIR" build >/dev/null'
}

build_protocol_client_if_needed() {
    local constants_h="$ROOT_DIR/shared/include/constants.h"
    local ipc_h="$VDIR/include/ipc_transport.h"
    local ipc_c="$VDIR/src/ipc_transport.c"
    if [[ ! -x "$CLIENT_BIN" || "$CLIENT_SRC" -nt "$CLIENT_BIN" || "$constants_h" -nt "$CLIENT_BIN" || "$ipc_h" -nt "$CLIENT_BIN" || "$ipc_c" -nt "$CLIENT_BIN" ]]; then
        log "Building protocol test client"
        gcc -O2 -g -I "$ROOT_DIR/shared/include" -I "$VDIR/include" "$CLIENT_SRC" "$VDIR/src/ipc_transport.c" -lrt -o "$CLIENT_BIN"
    else
        log "Reusing existing protocol test client ($CLIENT_BIN)"
    fi
}

pick_free_test_pba() {
    local base="$1"
    local span="$2"
    local candidate
    local line
    local state

    for candidate in $(seq "$base" "$((base + span - 1))"); do
        line="$(inspect_pba_line recovery "$candidate")"
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
        line="$(inspect_pba_line recovery "$candidate")"
        state="$(extract_field "$line" STATE)"
        if [[ "$state" == "FREE" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

resolve_log_pba_pair() {
    local phase="$1"
    local active_tail
    local next_tail

    active_tail="$(get_log_tail "$phase")"
    if [[ ! "$active_tail" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    next_tail="$(pick_free_log_pba "$((active_tail + 1))" 256 "$active_tail" || true)"
    if [[ ! "$next_tail" =~ ^[0-9]+$ ]]; then
        next_tail="$((active_tail + 1))"
    fi

    echo "$active_tail $next_tail"
}

test_lib_preflight_cleanup_full "$IO_TIMEOUT_SECS" log
ensure_gatekeeper_built
build_protocol_client_if_needed

if [[ "${TEST_PBA}" == "2048" ]]; then
    if ! pick_free_test_pba 2000 256; then
        log "Failed to find a FREE test block in the default candidate window"
        exit 1
    fi
else
    log "Using user-specified TEST_PBA=$TEST_PBA"
fi

if ! read -r LOG_PBA_0 LOG_PBA_1 < <(resolve_log_pba_pair recovery); then
    log "Failed to discover active log tail before freeze transition"
    exit 1
fi
LOG_PBA_2="$((LOG_PBA_1 + 1))"
log "Initial LOG_PBA sequence: $LOG_PBA_0 -> $LOG_PBA_1 -> $LOG_PBA_2"

# Phase 1: repeatedly write in free state and force transition to frozen.
log "Phase 1: repeated writes should succeed while target block is free"
expect_client_success initial write-data "$TEST_PBA" 17
expect_client_success recovery write-data "$TEST_PBA" 34

freeze_current="$(get_tsc32 recovery)"
if (( freeze_current % 2 != 0 )); then
    freeze_current="$((freeze_current - 1))"
fi

if ! read -r LOG_PBA_0 LOG_PBA_1 < <(resolve_log_pba_pair recovery); then
    log "Failed to discover active log tail immediately before freeze transition"
    exit 1
fi
log "Phase 1: forcing Free -> Frozen via metadata-log write near tail seed $LOG_PBA_0"

freeze_ok=0
for round in $(seq 1 "$PROBE_ROUNDS"); do
    if ! read -r LOG_PBA_0 LOG_PBA_1 < <(resolve_log_pba_pair recovery); then
        continue
    fi
    for tail_offset in $PROBE_OFFSETS; do
        candidate_log_pba="$((LOG_PBA_0 + tail_offset))"
        if (( candidate_log_pba < 0 )); then
            continue
        fi
        candidate_line="$(inspect_pba_line recovery "$candidate_log_pba")"
        candidate_state="$(extract_field "$candidate_line" STATE)"
        if [[ "$candidate_state" != "FREE" ]]; then
            log "Freeze candidate log_pba=$candidate_log_pba is state=$candidate_state; skipping"
            continue
        fi
        candidate_next_pba="$((candidate_log_pba + 1))"

        log "Freeze attempt using log_pba=$candidate_log_pba pointer_next=$candidate_next_pba"
        if ! run_client_fresh_for_phase recovery write-hdlog "$TEST_PBA" "$candidate_log_pba" "$FREEZE_KEEP" "$freeze_current" "$candidate_next_pba"; then
            log "Freeze attempt failed for log_pba=$candidate_log_pba"
            continue
        fi

        frozen_line="$(inspect_line recovery)"
        frozen_state="$(extract_field "$frozen_line" STATE)"
        log "Frozen inspect: $frozen_line"

        if [[ "$frozen_state" == "FROZEN" ]]; then
            LOG_PBA_0="$candidate_log_pba"
            LOG_PBA_1="$candidate_next_pba"
            freeze_ok=1
            break 2
        fi
    done
done

if [[ "$freeze_ok" -ne 1 ]]; then
    log "Expected FROZEN state after first metadata transition"
    exit 1
fi

log "Phase 1: writes in frozen state must fail"
expect_client_failure recovery write-data "$TEST_PBA" 51

# Phase 2: verify recovered state, unfreeze, and wait for countdown to elapse.
recovered_frozen_line="$(inspect_line recovery)"
log "Recovered frozen inspect: $recovered_frozen_line"
recovered_state="$(extract_field "$recovered_frozen_line" STATE)"
if [[ "$recovered_state" != "FROZEN" ]]; then
    log "Expected recovered state to remain FROZEN before unfreeze"
    exit 1
fi

tsc_now="$(get_tsc32 recovery)"
unfreeze_current="$((tsc_now + 2))"
if (( unfreeze_current % 2 == 0 )); then
    unfreeze_current="$((unfreeze_current + 1))"
fi

if ! read -r LOG_PBA_1 LOG_PBA_2 < <(resolve_log_pba_pair recovery); then
    log "Failed to discover active log tail immediately before unfreeze transition"
    exit 1
fi
log "Phase 2: forcing Frozen -> Countdown via metadata-log write near tail seed $LOG_PBA_1"

unfreeze_ok=0
for round in $(seq 1 "$PROBE_ROUNDS"); do
    if ! read -r LOG_PBA_1 LOG_PBA_2 < <(resolve_log_pba_pair recovery); then
        continue
    fi
    for tail_offset in $PROBE_OFFSETS; do
        candidate_log_pba="$((LOG_PBA_1 + tail_offset))"
        if (( candidate_log_pba < 0 )); then
            continue
        fi
        candidate_line="$(inspect_pba_line recovery "$candidate_log_pba")"
        candidate_state="$(extract_field "$candidate_line" STATE)"
        if [[ "$candidate_state" != "FREE" ]]; then
            log "Unfreeze candidate log_pba=$candidate_log_pba is state=$candidate_state; skipping"
            continue
        fi
        candidate_next_pba="$((candidate_log_pba + 1))"

        log "Unfreeze attempt using log_pba=$candidate_log_pba pointer_next=$candidate_next_pba"
        if ! run_client_fresh_for_phase recovery write-hdlog "$TEST_PBA" "$candidate_log_pba" 0 "$unfreeze_current" "$candidate_next_pba"; then
            log "Unfreeze attempt failed for log_pba=$candidate_log_pba"
            continue
        fi

        countdown_line="$(inspect_line recovery)"
        countdown_state="$(extract_field "$countdown_line" STATE)"
        log "Countdown inspect: $countdown_line"

        if [[ "$countdown_state" != "FROZEN" ]]; then
            LOG_PBA_1="$candidate_log_pba"
            LOG_PBA_2="$candidate_next_pba"
            unfreeze_ok=1
            break 2
        fi
    done
done

if [[ "$unfreeze_ok" -ne 1 ]]; then
    log "Unfreeze transition could not be confirmed; failing fast to avoid long retry loop"
    exit 1
fi

log "Phase 2: retry writes until countdown elapses and block is free again"
write_succeeded=0
for attempt in $(seq 1 "$MAX_RETRY"); do
    if run_client_fresh_for_phase recovery write-data "$TEST_PBA" 68; then
        write_succeeded=1
        log "Write succeeded on retry $attempt"
        break
    fi

    log "Write still blocked on retry $attempt; waiting $RETRY_DELAY_SECS s"
    sleep "$RETRY_DELAY_SECS"
done

if [[ "$write_succeeded" -ne 1 ]]; then
    log "Write never became free within retry budget"
    exit 1
fi

final_line="$(inspect_line recovery)"
log "Final inspect: $final_line"
final_state="$(extract_field "$final_line" STATE)"
if [[ "$final_state" != "FREE" ]]; then
    log "Expected final state FREE after countdown elapsed"
    exit 1
fi

test_succeeded=1
log "Timelock state-machine e2e passed (Free write loop, Frozen reject, Unfreeze countdown, Free again)"
