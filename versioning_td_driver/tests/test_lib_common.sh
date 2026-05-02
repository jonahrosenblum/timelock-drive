#!/usr/bin/env bash

# Shared helpers for test scripts. These functions assume Bash.

test_lib_run_with_timeout() {
    local timeout_secs="$1"
    shift
    local kill_after_secs="${TIMEOUT_KILL_AFTER_SECS:-5}"
    timeout --foreground -k "${kill_after_secs}s" "${timeout_secs}s" "$@"
}

test_lib_pid_is_alive() {
    local pid="$1"

    [[ -n "$pid" ]] || return 1

    if kill -0 "$pid" >/dev/null 2>&1; then
        return 0
    fi

    sudo kill -0 "$pid" >/dev/null 2>&1
}

test_lib_terminate_process_tree() {
    local pid="$1"
    local label="$2"
    local io_timeout_secs="${3:-${IO_TIMEOUT_SECS:-20}}"
    local log_func="${4:-}"

    if [[ -z "$pid" ]]; then
        return 0
    fi

    local children=""
    children="$(pgrep -P "$pid" 2>/dev/null || true)"

    local targets="$pid"
    if [[ -n "$children" ]]; then
        targets="$targets $children"
    fi

    test_lib_run_with_timeout "$io_timeout_secs" sudo kill $targets >/dev/null 2>&1 || true

    local remaining=1
    for _ in $(seq 1 50); do
        remaining=0
        for t in $targets; do
            if test_lib_pid_is_alive "$t"; then
                remaining=1
                break
            fi
        done
        if [[ "$remaining" -eq 0 ]]; then
            return 0
        fi
        sleep 0.2
    done

    if [[ -n "$log_func" ]] && declare -F "$log_func" >/dev/null; then
        "$log_func" "$label process tree did not exit after SIGTERM; sending SIGKILL"
    fi
    test_lib_run_with_timeout "$io_timeout_secs" sudo kill -9 $targets >/dev/null 2>&1 || true

    for _ in $(seq 1 25); do
        remaining=0
        for t in $targets; do
            if test_lib_pid_is_alive "$t"; then
                remaining=1
                break
            fi
        done
        if [[ "$remaining" -eq 0 ]]; then
            return 0
        fi
        sleep 0.2
    done

    if [[ -n "$log_func" ]] && declare -F "$log_func" >/dev/null; then
        "$log_func" "$label process tree still appears alive after SIGKILL"
    fi
    return 1
}

test_lib_cleanup_ipc_shm() {
    local shm_path="${1:-/dev/shm/timelocked_ipc}"
    sudo rm -f "$shm_path" >/dev/null 2>&1 || true
}

test_lib_preflight_cleanup_full() {
    local io_timeout_secs="$1"
    local log_func="${2:-}"
    local stale_pattern="${3:-gatekeeper/main-rust/target/release/main|sudo ./bin/versioning_td_driver|/bin/versioning_td_driver}"

    if [[ -n "$log_func" ]] && declare -F "$log_func" >/dev/null; then
        "$log_func" "Preflight cleanup of stale gatekeeper/driver processes and BDUS devices"
    fi

    if [[ "${E2E_USE_IPC:-0}" == "1" ]]; then
        test_lib_cleanup_ipc_shm "${IPC_SHM_PATH:-/dev/shm/timelocked_ipc}"
    fi

    local d_state=""
    d_state="$(ps -eo stat,cmd | awk '/^[D]/ && ($0 ~ /dd if=.*of=\/dev\/bdus-|bdus destroy/) {print}' || true)"
    if [[ -n "$d_state" ]]; then
        if [[ -n "$log_func" ]] && declare -F "$log_func" >/dev/null; then
            "$log_func" "Detected uninterruptible D-state I/O from previous run; cannot be force-killed"
            "$log_func" "Please clear stuck BDUS I/O (typically reboot) before re-running this test"
        fi
        echo "$d_state"
        return 1
    fi

    local stale_pids=""
    stale_pids="$(ps -eo pid,cmd | grep -E "$stale_pattern" | grep -v grep | awk '{print $1}' || true)"
    if [[ -n "$stale_pids" ]]; then
        test_lib_run_with_timeout "$io_timeout_secs" sudo kill $stale_pids >/dev/null 2>&1 || true
        sleep 1
    fi

    for dev in /dev/bdus-*; do
        [[ "$dev" == "/dev/bdus-control" ]] && continue
        if [[ -b "$dev" ]]; then
            test_lib_run_with_timeout "$io_timeout_secs" sudo bdus destroy --no-flush "$dev" >/dev/null 2>&1 || true
        fi
    done
}

test_lib_wait_for_bdus_device() {
    local current_bdus_file="$1"
    local out_var_name="$2"
    local attempts="${3:-50}"
    local delay_secs="${4:-0.2}"
    local out_var

    declare -n out_var="$out_var_name"

    for _ in $(seq 1 "$attempts"); do
        if [[ -s "$current_bdus_file" ]]; then
            out_var="$(tr -d '[:space:]' <"$current_bdus_file")"
            if [[ -n "$out_var" && -b "$out_var" ]]; then
                return 0
            fi
        fi
        sleep "$delay_secs"
    done

    return 1
}

test_lib_cleanup_gatekeeper_port() {
    local gatekeeper_port="$1"
    local log_func="${2:-}"
    local pids

    pids="$(sudo ss -ltnp | awk -v port=":$gatekeeper_port" '
        $4 ~ port && /pid=/ {
            split($NF, parts, "pid=");
            split(parts[2], pid_parts, ",");
            print pid_parts[1];
        }
    ' | sort -u)"

    if [[ -z "$pids" ]]; then
        return 0
    fi

    if [[ -n "$log_func" ]] && declare -F "$log_func" >/dev/null; then
        "$log_func" "Cleaning stale gatekeeper listener(s) on port $gatekeeper_port: $(echo "$pids" | tr '\n' ' ')"
    fi

    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        sudo kill "$pid" >/dev/null 2>&1 || true
    done <<<"$pids"

    for _ in $(seq 1 20); do
        if ! sudo ss -ltnp | grep -q ":$gatekeeper_port "; then
            return 0
        fi
        sleep 0.2
    done

    return 1
}

test_lib_get_gatekeeper_listener_pid() {
    local gatekeeper_port="$1"
    sudo ss -ltnp | awk -v port=":$gatekeeper_port" '
        $4 ~ port && /pid=/ {
            split($NF, parts, "pid=");
            split(parts[2], pid_parts, ",");
            print pid_parts[1];
            exit;
        }
    '
}

test_lib_get_gatekeeper_process_pid() {
    local gatekeeper_bin="$1"
    pgrep -f "^$gatekeeper_bin" | head -n 1
}

test_lib_wait_for_gatekeeper_ready() {
    local mode="$1"
    local gatekeeper_bin="$2"
    local gatekeeper_port="$3"
    local ipc_shm_path="$4"
    local out_var_name="$5"
    local attempts="${6:-50}"
    local delay_secs="${7:-0.1}"
    local launcher_pid="${8:-}"
    local out_var

    declare -n out_var="$out_var_name"

    if [[ "$mode" == "ipc" ]]; then
        for attempt in $(seq 1 "$attempts"); do
            if [[ -n "$launcher_pid" ]] && ! test_lib_pid_is_alive "$launcher_pid"; then
                return 1
            fi

            local live_pid=""
            live_pid="$(test_lib_get_gatekeeper_process_pid "$gatekeeper_bin" || true)"
            if [[ -e "$ipc_shm_path" && -n "$live_pid" ]]; then
                out_var="$live_pid"
                return 0
            fi
            sleep "$delay_secs"
        done
        return 1
    fi

    for attempt in $(seq 1 "$attempts"); do
        if [[ -n "$launcher_pid" ]] && ! test_lib_pid_is_alive "$launcher_pid"; then
            return 1
        fi

        local live_pid=""
        live_pid="$(test_lib_get_gatekeeper_listener_pid "$gatekeeper_port" || true)"
        if [[ -n "$live_pid" ]]; then
            out_var="$live_pid"
            return 0
        fi
        sleep "$delay_secs"
    done

    return 1
}

# Standardized cleanup trap for test scripts.
# Scripts source this and call it at the end of their setup phase to register the cleanup handler.
# Parameters: none (uses globals: test_succeeded, TMP_DIR, E2E_USE_IPC, gatekeeper_pid, gatekeeper_launcher_pid, driver_pid, bdus_device, IO_TIMEOUT_SECS, log_func)
# Optional: override test_lib_script_cleanup_handler() in script to customize cleanup logic.
test_lib_setup_cleanup_trap() {
    trap 'test_lib_script_cleanup_handler' EXIT
}

test_lib_resolve_gatekeeper_bin() {
    if [[ -n "${GATEKEEPER_BIN:-}" ]]; then
        printf '%s\n' "$GATEKEEPER_BIN"
        return 0
    fi

    if [[ -n "${GDIR:-}" ]]; then
        printf '%s\n' "$GDIR/gatekeeper/main-rust/target/release/main"
        return 0
    fi

    if [[ -n "${ROOT_DIR:-}" ]]; then
        printf '%s\n' "$ROOT_DIR/gatekeeper/gatekeeper/main-rust/target/release/main"
        return 0
    fi

    local tests_dir=""
    tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    printf '%s\n' "$(cd "$tests_dir/../.." && pwd)/gatekeeper/gatekeeper/main-rust/target/release/main"
}

# Build gatekeeper only when needed.
# Controls:
#   FORCE_GATEKEEPER_BUILD=1  -> always build
#   SKIP_GATEKEEPER_BUILD=1   -> never build
# Parameter:
#   $1 optional shell command string to run for build.
#      Defaults to: make -C "$GDIR" build >/dev/null
test_lib_build_gatekeeper_if_needed() {
    local log_func="${log_func:-log}"
    if ! declare -F "$log_func" >/dev/null; then
        log_func=""
    fi

    if [[ "${SKIP_GATEKEEPER_BUILD:-0}" == "1" ]]; then
        [[ -n "$log_func" ]] && "$log_func" "Skipping gatekeeper build (SKIP_GATEKEEPER_BUILD=1)"
        return 0
    fi

    local gatekeeper_bin=""
    gatekeeper_bin="$(test_lib_resolve_gatekeeper_bin)"
    if [[ "${FORCE_GATEKEEPER_BUILD:-0}" != "1" && -x "$gatekeeper_bin" ]]; then
        [[ -n "$log_func" ]] && "$log_func" "Reusing existing gatekeeper binary ($gatekeeper_bin)"
        return 0
    fi

    local build_cmd="${1:-make -C \"$GDIR\" build >/dev/null}"
    # shellcheck disable=SC2016
    eval "$build_cmd"
}

# Default cleanup handler; scripts can override.
# Core behavior: set +e, IPC cleanup, gatekeeper shutdown, driver shutdown, artifact preservation.
test_lib_script_cleanup_handler() {
    set +e

    # Optional IPC cleanup
    if [[ "${E2E_USE_IPC:-0}" == "1" ]]; then
        sudo rm -f /dev/shm/timelocked_ipc >/dev/null 2>&1 || true
    fi

    # Gatekeeper shutdown (pass variable names, not values)
    if [[ -n "${gatekeeper_pid:-}" || -n "${gatekeeper_launcher_pid:-}" ]]; then
        test_lib_clean_gk_shutdown \
            "gatekeeper_pid" \
            "gatekeeper_launcher_pid" \
            "driver_pid" \
            "bdus_device" \
            "${IO_TIMEOUT_SECS:-10}" \
            "${log_func:-log}" || true
    fi

    # Artifact preservation
    if [[ "${test_succeeded:-0}" -eq 1 ]]; then
        [[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR" 2>/dev/null || true
    else
        [[ -n "${TMP_DIR:-}" ]] && [[ -n "${log_func:-}" ]] && $log_func "Preserving artifacts in $TMP_DIR"
    fi
}

# Standardized gatekeeper startup with readiness polling.
# Sets: gatekeeper_pid (the listener process), gatekeeper_launcher_pid (the background job)
# Parameters: [cleanup_port=1] [cleanup_ipc=1] [wait_ready=1] [extra_env_vars...]
# Uses globals: GATEKEEPER_BIN, GATEKEEPER_PORT, GK_TRANSPORT_ARG, GATEKEEPER_LOG, E2E_USE_IPC, IO_TIMEOUT_SECS, GK_TRACE_WRITES (optional), log_func
test_lib_start_gatekeeper() {
    local cleanup_port="${1:-1}"
    local cleanup_ipc="${2:-1}"
    local wait_ready="${3:-1}"
    shift 3 || true

    local log_func="${log_func:-log}"
    local gatekeeper_bin=""
    gatekeeper_bin="$(test_lib_resolve_gatekeeper_bin)"

    # Port cleanup if requested and socket mode
    if [[ "$cleanup_port" == "1" ]] && [[ "${E2E_USE_IPC:-0}" != "1" ]]; then
        test_lib_cleanup_gatekeeper_port "${GATEKEEPER_PORT:-10107}" "$log_func" || true
    fi

    # IPC cleanup if requested
    if [[ "$cleanup_ipc" == "1" ]] && [[ "${E2E_USE_IPC:-0}" == "1" ]]; then
        test_lib_cleanup_ipc_shm "${IPC_SHM_PATH:-/dev/shm/timelocked_ipc}"
    fi

    # Ensure log file exists
    : >"${GATEKEEPER_LOG:-.}"

    # Launch gatekeeper with optional environment variables
    $log_func "Starting gatekeeper"
    sudo env RUST_BACKTRACE=1 ${GK_TRACE_WRITES:+GK_TRACE_WRITES="$GK_TRACE_WRITES"} "$gatekeeper_bin" --timelockdrive "${GK_TRANSPORT_ARG:-}" "$@" \
        >"${GATEKEEPER_LOG:-.}" 2>&1 &
    gatekeeper_launcher_pid=$!

    # Wait for readiness if requested
    if [[ "$wait_ready" == "1" ]]; then
        local mode="socket"
        [[ "${E2E_USE_IPC:-0}" == "1" ]] && mode="ipc"
        if ! test_lib_wait_for_gatekeeper_ready \
            "$mode" \
            "$gatekeeper_bin" \
            "${GATEKEEPER_PORT:-10107}" \
            "${IPC_SHM_PATH:-/dev/shm/timelocked_ipc}" \
            gatekeeper_pid \
            "${GK_WAIT_ATTEMPTS:-50}" \
            "${GK_WAIT_DELAY_SECS:-0.1}" \
            "$gatekeeper_launcher_pid"; then
            $log_func "Gatekeeper failed to start"
            if [[ -s "${GATEKEEPER_LOG:-.}" ]]; then
                tail -n 60 "${GATEKEEPER_LOG:-.}"
            fi
            return 1
        fi
        $log_func "Gatekeeper ready (pid $gatekeeper_pid)"
    else
        # Fallback: just assume gatekeeper_pid is the launcher (backward compat for simple scripts)
        gatekeeper_pid=$gatekeeper_launcher_pid
    fi
}

# Standardized driver startup with BDUS device wait.
# Sets: driver_pid, bdus_device
# Parameters: [phase_name=default]
# Uses globals: VDIR, DRIVER_TRANSPORT_ARG, DRIVER_ARGS, CURRENT_BDUS_FILE, DRIVER_LOG, IO_TIMEOUT_SECS, log_func
test_lib_start_driver() {
    local phase_name="${1:-default}"
    local extra_args="${2:-}"
    local log_func="${log_func:-log}"
    local wait_attempts="${DRIVER_WAIT_ATTEMPTS:-50}"
    local wait_delay_secs="${DRIVER_WAIT_DELAY_SECS:-0.2}"

    # Reset BDUS and driver log files
    : >"${CURRENT_BDUS_FILE:-.}"
    : >"${DRIVER_LOG:-.}"

    # Launch driver
    $log_func "Starting versioning driver (${phase_name})"
    (
        cd "${VDIR:-.}" || exit 1
        # shellcheck disable=SC2086
        sudo ./bin/versioning_td_driver ${DRIVER_TRANSPORT_ARG:-} ${DRIVER_ARGS:-} \
            $extra_args \
            >"${CURRENT_BDUS_FILE:-.}" 2>"${DRIVER_LOG:-.}"
    ) &
    driver_pid=$!

    # Wait for BDUS device exposure
    if ! test_lib_wait_for_bdus_device "${CURRENT_BDUS_FILE:-.}" bdus_device "$wait_attempts" "$wait_delay_secs"; then
        $log_func "Driver did not expose a BDUS device"
        return 1
    fi

    $log_func "Driver exposed $bdus_device"
}

# Wait for a process to exit.
# Parameters: pid [attempts=50] [delay_secs=0.2]
# Returns 0 if the process exited within attempts, 1 otherwise.
test_lib_wait_for_process_exit() {
    local pid="$1"
    local attempts="${2:-50}"
    local delay_secs="${3:-0.2}"

    for _ in $(seq 1 "$attempts"); do
        if ! test_lib_pid_is_alive "$pid"; then
            return 0
        fi
        sleep "$delay_secs"
    done

    return 1
}

# Kill gatekeeper + driver uncleanly (simulates power failure / crash).
# Parameters: gatekeeper_pid_varname driver_pid_varname bdus_device_varname
# Calls clean_gk_shutdown (must be defined in the calling script) for gatekeeper.
test_lib_kill_stack_uncleanly() {
    local -n _ksu_gk_pid="$1"
    local -n _ksu_drv_pid="$2"
    local -n _ksu_bdus="$3"

    if [[ -n "${_ksu_drv_pid:-}" ]]; then
        test_lib_terminate_process_tree "$_ksu_drv_pid" "driver"
        _ksu_drv_pid=""
    fi

    if [[ -n "${_ksu_gk_pid:-}" ]]; then
        clean_gk_shutdown
    fi

    _ksu_bdus=""
}

# Start gatekeeper with a simple sleep-1 readiness wait.
# Respects GATEKEEPER_VERBOSE: when != 1, stdout goes to /dev/null (stderr still to log).
# Respects GK_TRACE_WRITES: when set, injects as env var passed to sudo env.
# Updates: gatekeeper_pid
# Uses globals: GATEKEEPER_BIN (falls back to test_lib_resolve_gatekeeper_bin),
#               GK_TRANSPORT_ARG, GATEKEEPER_LOG, GATEKEEPER_VERBOSE, GK_TRACE_WRITES, log_func
# Parameters: phase_name [extra_args_for_gatekeeper...]
test_lib_start_gatekeeper_raw() {
    local phase_name="$1"
    shift
    local log_func="${log_func:-log}"
    local gatekeeper_bin="${GATEKEEPER_BIN:-}"
    [[ -z "$gatekeeper_bin" ]] && gatekeeper_bin="$(test_lib_resolve_gatekeeper_bin)"

    $log_func "Starting gatekeeper${phase_name:+ ($phase_name)}"
    if [[ "${GATEKEEPER_VERBOSE:-1}" != "1" ]]; then
        # Suppress per-block stdout churn; errors on stderr still reach the log.
        # shellcheck disable=SC2086
        sudo env RUST_BACKTRACE=1 ${GK_TRACE_WRITES:+GK_TRACE_WRITES="$GK_TRACE_WRITES"} \
            "$gatekeeper_bin" --timelockdrive "${GK_TRANSPORT_ARG:-}" "$@" \
            >/dev/null 2>"${GATEKEEPER_LOG:-/dev/null}" &
    else
        # shellcheck disable=SC2086
        sudo env RUST_BACKTRACE=1 ${GK_TRACE_WRITES:+GK_TRACE_WRITES="$GK_TRACE_WRITES"} \
            "$gatekeeper_bin" --timelockdrive "${GK_TRANSPORT_ARG:-}" "$@" \
            >"${GATEKEEPER_LOG:-/dev/null}" 2>&1 &
    fi
    gatekeeper_pid=$!
    sleep 1
}

# Wrapper for test_lib_cleanup_gatekeeper_port that skips when IPC is active.
# Falls back to GATEKEEPER_PORT. Intended to replace per-script cleanup_gatekeeper_port
# wrappers.
# Parameters: [port=$GATEKEEPER_PORT] [log_func=log]
test_lib_cleanup_gatekeeper_port_ipc_aware() {
    if [[ "${E2E_USE_IPC:-0}" == "1" ]]; then
        return 0
    fi
    local port="${1:-${GATEKEEPER_PORT:-10107}}"
    local log_func="${2:-log}"
    test_lib_cleanup_gatekeeper_port "$port" "$log_func"
}
