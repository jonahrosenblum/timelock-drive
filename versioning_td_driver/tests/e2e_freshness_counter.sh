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

gatekeeper_pid=""
gatekeeper_launcher_pid=""
test_succeeded=0

log() {
    printf '[e2e_freshness] %s\n' "$*"
}

test_lib_setup_cleanup_trap

log "Building gatekeeper"
test_lib_build_gatekeeper_if_needed '( cd "$GDIR" && make build >/dev/null )'

log "Building protocol test client"
gcc -O2 -g -I "$ROOT_DIR/shared/include" -I "$VDIR/include" "$CLIENT_SRC" "$VDIR/src/ipc_transport.c" -lrt -o "$CLIENT_BIN"

test_lib_preflight_cleanup_full "$IO_TIMEOUT_SECS" log
test_lib_start_gatekeeper 1 1 1

log "Running stale-counter freshness replay scenario"
if ! test_lib_run_client_cmd "$CLIENT_BIN" "$IO_TIMEOUT_SECS" freshness-replay 0; then
    log "freshness-replay client action failed"
    tail -n 80 "$GATEKEEPER_LOG" || true
    exit 1
fi

# Behavior-based assertion: freshness-replay client already verifies
# 1) stale counter is rejected via protocol response code, and
# 2) checker remains alive via follow-up read.
# Keep checker-panic guard as a hard safety signal.

if grep -q "panic\|panicked at\|Halt" "$GATEKEEPER_LOG"; then
    log "Checker panicked during stale-counter rejection path"
    tail -n 80 "$GATEKEEPER_LOG" || true
    exit 1
fi

test_succeeded=1
log "Freshness counter stale-metadata e2e passed"
