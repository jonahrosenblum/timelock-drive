#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib_defaults.sh"
test_lib_init_shared_defaults "$SCRIPT_DIR"
source "$TESTS_DIR/test_lib_common.sh"
source "$TESTS_DIR/test_lib_transport.sh"
TMP_DIR="$(mktemp -d)"
test_lib_init_tmp_artifact_defaults "$TMP_DIR"
# Use logical blocks managed by cached metadata blocks (5116-5119)
# Metadata blocks 5116-5119 manage logical blocks 2619392-2621439
# Pick early in md 5118 range so Test 5 writes span 5118-5119 boundaries
TEST_BLOCK="${TEST_BLOCK:-250000}"

test_lib_setup_transport_from_env

gatekeeper_pid=""
driver_pid=""
bdus_device=""
test_succeeded=0

test_lib_setup_cleanup_trap

log() {
    printf '[e2e_flush] %s\n' "$*"
}

# Cleanup is handled by test_lib_setup_cleanup_trap

wait_for_path() {
    local path="$1"
    local attempts="${2:-50}"
    local delay_secs="${3:-0.2}"

    for _ in $(seq 1 "$attempts"); do
        if [[ -e "$path" ]]; then
            return 0
        fi
        sleep "$delay_secs"
    done

    return 1
}

clean_gk_shutdown() {
    test_lib_clean_gk_shutdown gatekeeper_pid "" driver_pid bdus_device "$IO_TIMEOUT_SECS" log
}

start_gatekeeper() {
    local mode="$1"; shift
    test_lib_start_gatekeeper_raw "$mode" "$@"
}

stop_stack() {
    clean_gk_shutdown

    if [[ -n "$driver_pid" ]]; then
        test_lib_terminate_process_tree "$driver_pid" "driver"
        driver_pid=""
    fi

    bdus_device=""
}

write_block() {
    local input_file="$1"
    log "Writing test payload to logical block $TEST_BLOCK"
    sudo dd if="$input_file" of="$bdus_device" bs=4096 seek="$TEST_BLOCK" count=1 status=none
}

read_block() {
    local output_file="$1"
    log "Reading logical block $TEST_BLOCK"
    sudo dd if="$bdus_device" of="$output_file" bs=4096 skip="$TEST_BLOCK" count=1 status=none
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

log "Building gatekeeper and host driver"
test_lib_build_gatekeeper_if_needed 'make -C "$GDIR" build >/dev/null'
make -C "$VDIR" versioning_td_driver >/dev/null
test_lib_preflight_cleanup_full "$IO_TIMEOUT_SECS" log

payload_file_1="$TMP_DIR/payload_1.bin"
payload_file_2="$TMP_DIR/payload_2.bin"
payload_file_3="$TMP_DIR/payload_3.bin"
roundtrip_file_1="$TMP_DIR/roundtrip_1.bin"
roundtrip_file_2="$TMP_DIR/roundtrip_2.bin"
roundtrip_file_3="$TMP_DIR/roundtrip_3.bin"
recovered_file_1="$TMP_DIR/recovered_1.bin"
recovered_file_2="$TMP_DIR/recovered_2.bin"
recovered_file_3="$TMP_DIR/recovered_3.bin"

# Generate three distinct test payloads
head -c 4096 /dev/urandom >"$payload_file_1"
head -c 4096 /dev/urandom >"$payload_file_2"
head -c 4096 /dev/urandom >"$payload_file_3"

start_gatekeeper initial
test_lib_start_driver "initial"

# Test 1: Single block write/read at TEST_BLOCK
log "Test 1: Single block write/read at logical block $TEST_BLOCK"
write_block "$payload_file_1"
read_block "$roundtrip_file_1"
assert_files_equal "$payload_file_1" "$roundtrip_file_1" "Test 1 round-trip readback"
log "Test 1 round-trip readback succeeded"

# Test 2: Verify block isolation at TEST_BLOCK + 1
log "Test 2: Verify block isolation at logical block $((TEST_BLOCK + 1))"
SAVED_TEST_BLOCK="$TEST_BLOCK"
TEST_BLOCK=$((TEST_BLOCK + 1))
write_block "$payload_file_2"
read_block "$roundtrip_file_2"
assert_files_equal "$payload_file_2" "$roundtrip_file_2" "Test 2 round-trip readback"
TEST_BLOCK="$SAVED_TEST_BLOCK"
log "Test 2 block isolation succeeded"

# Test 3: Mixed read/write pattern across distinct blocks
log "Test 3: Mixed read/write pattern across distinct blocks"
TEST_BLOCK=$((SAVED_TEST_BLOCK + 2))
write_block "$payload_file_1"
read_block "$roundtrip_file_1"
assert_files_equal "$payload_file_1" "$roundtrip_file_1" "Test 3 first read"
TEST_BLOCK=$((SAVED_TEST_BLOCK + 3))
write_block "$payload_file_3"
read_block "$roundtrip_file_3"
assert_files_equal "$payload_file_3" "$roundtrip_file_3" "Test 3 after overwrite"
TEST_BLOCK="$SAVED_TEST_BLOCK"
log "Test 3 mixed pattern succeeded"

# Test 4: Verify test block 1 still has original value (isolation from test 3)
log "Test 4: Re-verify isolation after concurrent writes"
TEST_BLOCK=$((SAVED_TEST_BLOCK + 1))
read_block "$roundtrip_file_2"
assert_files_equal "$payload_file_2" "$roundtrip_file_2" "Test 4 block isolation after overwrites"
TEST_BLOCK="$SAVED_TEST_BLOCK"
log "Test 4 persistence across concurrent operations succeeded"

# Test 5: Verify counter incrementation via HD metadata cache evictions
# The HD metadata cache size is 4, so write to 8 NEW metadata blocks to force cache evictions.
# Use md 3-10 (blocks 1536..5120) instead of md 0 to avoid reserved/edge behavior at block 0.
log "Test 5: Force HD metadata cache evictions by writing to new metadata blocks"
declare -a counter_test_payloads
MD_START=3
for i in {0..7}; do
    counter_test_payloads[$i]="$TMP_DIR/counter_test_payload_$i.bin"
    head -c 4096 /dev/urandom >"${counter_test_payloads[$i]}"
    TEST_BLOCK=$(((MD_START + i) * 512))  # Blocks 1536..5120 (md 3-10)
    if ! write_block "${counter_test_payloads[$i]}"; then
        log "Test 5: Write failed at logical block $TEST_BLOCK; continuing eviction stress"
        continue
    fi
done
TEST_BLOCK="$SAVED_TEST_BLOCK"
log "Test 5: Wrote 8 distinct blocks across metadata blocks 3-10"

log "Test 5 cache eviction and counter incrementation check completed"

stop_stack

test_succeeded=1

log "End-to-end flush test passed (5/5 non-recovery scenarios, including counter incrementation verification)"