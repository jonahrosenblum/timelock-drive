#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib_defaults.sh"
test_lib_init_shared_defaults "$SCRIPT_DIR"
source "$TESTS_DIR/test_lib_common.sh"
source "$TESTS_DIR/test_lib_transport.sh"

TMP_DIR="$(mktemp -d)"
test_lib_init_tmp_artifact_defaults "$TMP_DIR"

test_lib_setup_transport_from_env
LOG_TAIL_START=$(( (4096 - (3 * 4)) / 4 - 2 ))
TARGET_PBA="${TARGET_PBA:-2000}"
LOG_CURRENT_TIME="${LOG_CURRENT_TIME:-100}"

gatekeeper_pid=""
gatekeeper_launcher_pid=""
test_succeeded=0

log() {
    printf '[e2e_log_state] %s\n' "$*"
}

test_lib_setup_cleanup_trap

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

    return 0
}

log "Building gatekeeper"
test_lib_build_gatekeeper_if_needed '( cd "$GDIR" && make build >/dev/null )'

log "Building protocol test client"
gcc -O2 -g -I "$ROOT_DIR/shared/include" -I "$VDIR/include" "$CLIENT_SRC" "$VDIR/src/ipc_transport.c" -lrt -o "$CLIENT_BIN"

test_lib_preflight_cleanup_full "$IO_TIMEOUT_SECS" log

test_lib_start_gatekeeper 0 1 1 initial
identify_out="$(test_lib_run_client_cmd "$CLIENT_BIN" "$IO_TIMEOUT_SECS" identify 0)"
parse_identify_output "$identify_out" "$LOG_TAIL_START" "$LOG_TAIL_START"

test_lib_start_gatekeeper 0 1 1 advance
test_lib_run_client_cmd "$CLIENT_BIN" "$IO_TIMEOUT_SECS" write-hdlog "$TARGET_PBA" "$LOG_TAIL_START" 1 "$LOG_CURRENT_TIME" "$((LOG_TAIL_START + 1))" >/dev/null

test_lib_start_gatekeeper 0 1 1 recovery --no-init --no-zero
recovered_out="$(test_lib_run_client_cmd "$CLIENT_BIN" "$IO_TIMEOUT_SECS" identify 0)"
parse_identify_output "$recovered_out" "$LOG_TAIL_START" "$((LOG_TAIL_START + 1))"

test_succeeded=1
log "Persisted HD log head/tail recovery passed"