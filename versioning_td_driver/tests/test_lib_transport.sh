#!/usr/bin/env bash

# Transport-focused helpers used by e2e scripts.

test_lib_setup_transport_from_env() {
    local use_ipc="${E2E_USE_IPC:-0}"
    GK_TRANSPORT_ARG=""
    DRIVER_TRANSPORT_ARG=""
    if [[ "$use_ipc" == "1" ]]; then
        GK_TRANSPORT_ARG="--ipc"
        DRIVER_TRANSPORT_ARG="--ipc"
    fi
}

test_lib_run_client_cmd() {
    local client_bin="$1"
    local io_timeout_secs="$2"
    shift 2

    if [[ "${E2E_USE_IPC:-0}" == "1" ]]; then
        test_lib_run_with_timeout "$io_timeout_secs" sudo env E2E_USE_IPC=1 "$client_bin" "$@"
    else
        test_lib_run_with_timeout "$io_timeout_secs" "$client_bin" "$@"
    fi
}

test_lib_ensure_client_bin() {
    local client_bin="${1:-${CLIENT_BIN:-$VDIR/tests/timelock_state_client}}"
    local client_src="${2:-${CLIENT_SRC:-$VDIR/tests/timelock_state_client.c}}"
    local transport_src="$VDIR/src/ipc_transport.c"

    if [[ -x "$client_bin" && "$client_bin" -nt "$client_src" && "$client_bin" -nt "$transport_src" ]]; then
        return 0
    fi

    gcc -O2 -g -I "$ROOT_DIR/shared/include" -I "$VDIR/include" "$client_src" "$transport_src" -lrt -o "$client_bin"
}

test_lib_clean_gk_shutdown() {
    local gatekeeper_pid_var="$1"
    local launcher_pid_var="$2"
    local driver_pid_var="$3"
    local bdus_device_var="$4"
    local io_timeout_secs="$5"
    local log_func="${6:-}"
    local gatekeeper_pid_ref
    local launcher_pid_ref
    local driver_pid_ref
    local bdus_device_ref
    local current_gatekeeper_pid=""
    local current_launcher_pid=""
    local current_driver_pid=""
    local current_bdus_device=""
    local client_bin="${CLIENT_BIN:-$VDIR/tests/timelock_state_client}"

    declare -n gatekeeper_pid_ref="$gatekeeper_pid_var"
    current_gatekeeper_pid="${gatekeeper_pid_ref:-}"

    if [[ -n "$launcher_pid_var" ]]; then
        declare -n launcher_pid_ref="$launcher_pid_var"
        current_launcher_pid="${launcher_pid_ref:-}"
    fi

    if [[ -n "$driver_pid_var" ]]; then
        declare -n driver_pid_ref="$driver_pid_var"
        current_driver_pid="${driver_pid_ref:-}"
    fi

    if [[ -n "$bdus_device_var" ]]; then
        declare -n bdus_device_ref="$bdus_device_var"
        current_bdus_device="${bdus_device_ref:-}"
    fi

    if [[ -z "$current_gatekeeper_pid" && -z "$current_launcher_pid" ]]; then
        return 0
    fi

    if [[ -n "$current_bdus_device" && -b "$current_bdus_device" ]]; then
        if [[ -n "$log_func" ]] && declare -F "$log_func" >/dev/null; then
            "$log_func" "Stopping gatekeeper via clean bdus destroy of $current_bdus_device"
        fi
        test_lib_run_with_timeout "$io_timeout_secs" sudo sync "$current_bdus_device" >/dev/null 2>&1 || true
        test_lib_run_with_timeout "$io_timeout_secs" sudo bdus destroy "$current_bdus_device" >/dev/null 2>&1 || true
    fi

    if [[ -n "$current_driver_pid" ]]; then
        for _ in $(seq 1 50); do
            if ! sudo kill -0 "$current_driver_pid" >/dev/null 2>&1; then
                driver_pid_ref=""
                break
            fi
            sleep 0.2
        done
    fi

    if [[ -n "$current_bdus_device" && ! -b "$current_bdus_device" && -n "$bdus_device_var" ]]; then
        bdus_device_ref=""
    fi

    if [[ -n "$current_gatekeeper_pid" ]]; then
        if ! sudo kill -0 "$current_gatekeeper_pid" >/dev/null 2>&1; then
            gatekeeper_pid_ref=""
            if [[ -n "$launcher_pid_var" && -n "$current_launcher_pid" ]]; then
                if ! sudo kill -0 "$current_launcher_pid" >/dev/null 2>&1; then
                    launcher_pid_ref=""
                fi
            fi
            return 0
        fi
    fi

    if ! test_lib_ensure_client_bin "$client_bin"; then
        if [[ -n "$log_func" ]] && declare -F "$log_func" >/dev/null; then
            "$log_func" "Unable to build timelock_state_client for clean gatekeeper shutdown"
        fi
        return 1
    fi

    if ! test_lib_run_client_cmd "$client_bin" "$io_timeout_secs" finish 0 >/dev/null 2>&1; then
        if [[ -n "$current_gatekeeper_pid" ]]; then
            if ! sudo kill -0 "$current_gatekeeper_pid" >/dev/null 2>&1; then
                gatekeeper_pid_ref=""
                return 0
            fi
        fi
        if [[ -n "$log_func" ]] && declare -F "$log_func" >/dev/null; then
            "$log_func" "Failed to send FINISH to gatekeeper"
        fi
        return 1
    fi

    for _ in $(seq 1 50); do
        local gatekeeper_alive=0
        local launcher_alive=0
        if [[ -n "$current_gatekeeper_pid" ]]; then
            if sudo kill -0 "$current_gatekeeper_pid" >/dev/null 2>&1; then
                gatekeeper_alive=1
            fi
        fi
        if [[ -n "$current_launcher_pid" ]]; then
            if sudo kill -0 "$current_launcher_pid" >/dev/null 2>&1; then
                launcher_alive=1
            fi
        fi
        if [[ "$gatekeeper_alive" -eq 0 && "$launcher_alive" -eq 0 ]]; then
            gatekeeper_pid_ref=""
            if [[ -n "$launcher_pid_var" ]]; then
                launcher_pid_ref=""
            fi
            return 0
        fi
        sleep 0.2
    done

    if [[ -n "$log_func" ]] && declare -F "$log_func" >/dev/null; then
        "$log_func" "Gatekeeper did not exit after FINISH"
    fi
    return 1
}
