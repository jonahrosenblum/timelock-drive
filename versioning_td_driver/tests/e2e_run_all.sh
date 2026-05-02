#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib_defaults.sh"
test_lib_init_conservative_defaults "$SCRIPT_DIR"
TEST_DIR="$ROOT_DIR/versioning_td_driver/tests"
RUNNER_NAME="$(basename "$0")"
PER_TEST_TIMEOUT_SECS="${PER_TEST_TIMEOUT_SECS:-240}"
TIMEOUT_KILL_AFTER_SECS="${TIMEOUT_KILL_AFTER_SECS:-10}"

# Output mode: verbose (default) streams each test's output live; silent
# captures it to a log file and only prints it on failure.
# Toggle via --silent / --verbose flag or E2E_SILENT=1 env var.
SILENT="${E2E_SILENT:-0}"

if [[ ! -d "$TEST_DIR" ]]; then
    echo "[e2e_runner] ERROR: tests directory not found: $TEST_DIR" >&2
    exit 2
fi

mapfile -t tests < <(find "$TEST_DIR" -maxdepth 1 -type f -name 'e2e_*.sh' ! -name "$RUNNER_NAME" | sort)

if [[ ${#tests[@]} -eq 0 ]]; then
    echo "[e2e_runner] ERROR: no e2e scripts found in $TEST_DIR" >&2
    exit 2
fi

# ── arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "${1:-}" in
        --list)
            printf '[e2e_runner] Discovered %d e2e scripts:\n' "${#tests[@]}"
            for t in "${tests[@]}"; do
                printf '  - %s\n' "$(basename "$t")"
            done
            exit 0
            ;;
        --silent)  SILENT=1; shift ;;
        --verbose) SILENT=0; shift ;;
        *) echo "[e2e_runner] Unknown option: $1" >&2; exit 1 ;;
    esac
done

LOG_DIR="$(mktemp -d)"
trap 'echo "[e2e_runner] Logs kept at $LOG_DIR"' EXIT

declare -a passed=()
declare -a failed=()

echo "[e2e_runner] Running ${#tests[@]} e2e scripts"
if [[ "${E2E_USE_IPC:-0}" == "1" ]]; then
    echo "[e2e_runner] Transport mode: IPC (--ipc for gatekeeper/driver where applicable)"
else
    echo "[e2e_runner] Transport mode: default"
fi
if [[ "$SILENT" == "1" ]]; then
    echo "[e2e_runner] Output mode: silent (per-test output captured; printed on failure)"
else
    echo "[e2e_runner] Output mode: verbose (per-test output streamed live)"
fi
echo "[e2e_runner] Per-test logs: $LOG_DIR"
echo "[e2e_runner] Per-test timeout: ${PER_TEST_TIMEOUT_SECS}s (kill-after ${TIMEOUT_KILL_AFTER_SECS}s)"

total=${#tests[@]}
idx=0

for test_script in "${tests[@]}"; do
    idx=$((idx + 1))
    test_name="$(basename "$test_script")"
    log_file="$LOG_DIR/${test_name%.sh}.log"

    printf '\n[e2e_runner] [%d/%d] START %s\n' "$idx" "$total" "$test_name"

    if [[ "$SILENT" == "1" ]]; then
        timeout -k "${TIMEOUT_KILL_AFTER_SECS}s" "${PER_TEST_TIMEOUT_SECS}s" \
            bash "$test_script" >"$log_file" 2>&1
        rc=$?
    else
        timeout -k "${TIMEOUT_KILL_AFTER_SECS}s" "${PER_TEST_TIMEOUT_SECS}s" \
            bash "$test_script" 2>&1 | tee "$log_file"
        rc=${PIPESTATUS[0]}
    fi

    if [[ "$rc" -eq 0 ]]; then
        echo "[e2e_runner] PASS  $test_name"
        passed+=("$test_name")
    else
        if [[ "$rc" -eq 124 ]]; then
            echo "[e2e_runner] FAIL  $test_name (timed out after ${PER_TEST_TIMEOUT_SECS}s)"
        else
            echo "[e2e_runner] FAIL  $test_name (exit=$rc)"
        fi
        failed+=("$test_name")
        if [[ "$SILENT" == "1" ]]; then
            echo "[e2e_runner] ---- tail: $test_name ----"
            tail -n 40 "$log_file" || true
            echo "[e2e_runner] ---- end tail ----"
        fi
    fi

done

printf '\n[e2e_runner] Summary: %d passed, %d failed, %d total\n' "${#passed[@]}" "${#failed[@]}" "$total"

if [[ ${#failed[@]} -gt 0 ]]; then
    echo "[e2e_runner] Failed tests:"
    for name in "${failed[@]}"; do
        echo "  - $name"
    done
    exit 1
fi

exit 0
