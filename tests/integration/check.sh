#!/bin/sh
set -eu

python3 - <<'PY'
import sys
if sys.version_info < (3, 11):
    sys.exit(f"Rui integration checks require Python 3.11 or newer; found {sys.version.split()[0]} at {sys.executable}. Select a newer python3 on PATH before running checks.")
print(f"Integration Python: {sys.version.split()[0]} ({sys.executable})")
PY

directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python3 "$directory/host_process.py" exec true
release_safe=$1
pause_binary=${RUI_TEST_PAUSE_BINARY:-$release_safe}
pause_socket_binary=${RUI_TEST_PAUSE_SOCKET_BINARY:?pause socket fixture binary is required}
debug=$2
printf 'Actual native platform: %s %s\n' "$(uname -s)" "$(uname -m)"

if [ "${3:-}" = parallel ]; then
    part=parallel
    test_binary=$4
    host_status_actor=$5
    session_list_client=$6
    activity_client=$7
    preference_policy_actor=$8
    terminal_notice=$9
    mysql_launch_admin=${10}
    store_binary=${11:-}
else
    host_status_actor=$3
    session_list_client=$4
    activity_client=$5
    preference_policy_actor=$6
    part=${7:-all}
    terminal_notice=${8}
    mysql_launch_admin=${9}
    case "$part" in
        all|execution|callers) ;;
        *) printf 'Unknown full-check part: %s\n' "$part" >&2; exit 2 ;;
    esac
fi

cases() {
    run_case execution admission sh "$directory/admission_integration.sh" "$release_safe"
    run_case execution dispatch python3 "$directory/dispatch_integration.py" "$pause_binary"
    run_case execution read-image python3 "$directory/read_image_integration.py" "$release_safe"
    run_case execution bash-owner python3 "$directory/bash_owner_integration.py" "$release_safe"
    run_case execution bash python3 "$directory/bash_integration.py" "$pause_binary"
    run_case execution peer python3 "$directory/peer_integration.py" "$release_safe"
    run_case execution bash-environment python3 "$directory/bash_environment_integration.py" "$release_safe"
    if [ "$part" = all ]; then
        run_case callers human-cli env RUI_TEST_TERMINAL_NOTICE="$terminal_notice" python3 "$directory/human_cli_integration.py" "$release_safe"
    else
        run_case callers human-cli env RUI_TEST_TERMINAL_NOTICE="$terminal_notice" python3 "$directory/human_cli_integration.py" "$release_safe" callers
        run_case callers human-cli-renderer env RUI_TEST_TERMINAL_NOTICE="$terminal_notice" python3 "$directory/human_cli_integration.py" "$release_safe" renderer
        run_case callers terminal-restoration env RUI_TEST_TERMINAL_NOTICE="$terminal_notice" python3 "$directory/terminal_restoration_integration.py" "$release_safe"
        run_case callers canonical-failure env RUI_TEST_TERMINAL_NOTICE="$terminal_notice" python3 "$directory/canonical_failure_integration.py" "$release_safe"
    fi
    run_case callers model-picker python3 "$directory/model_picker_integration.py" "$release_safe"
    run_case callers model-picker-signin python3 "$directory/model_picker_signin_integration.py" "$release_safe"
    run_case callers model-picker-failure python3 "$directory/model_picker_failure_integration.py" "$release_safe"
    run_case callers pause-socket python3 "$directory/pause_socket_test.py" "$pause_socket_binary"
    run_case callers request-wait python3 "$directory/request_wait_integration.py" "$pause_binary"
    run_case callers preference-policy python3 "$directory/preference_policy_integration.py" "$preference_policy_actor"
    run_case execution bash-lifecycle python3 "$directory/bash_lifecycle_integration.py" "$release_safe"
    run_case execution bash-recovery python3 "$directory/bash_recovery_integration.py" "$pause_binary"
    run_case execution codex python3 "$directory/codex_integration.py" "$pause_binary"
    run_case execution control python3 "$directory/control_integration.py" "$pause_binary"
    run_case callers session-list python3 "$directory/session_list_integration.py" "$release_safe" "$session_list_client"
    run_case callers conversation-page python3 "$directory/conversation_page_integration.py" "$release_safe"
    run_case callers activity python3 "$directory/activity_integration.py" "$release_safe" "$activity_client"
    run_case execution descriptor-capacity python3 "$directory/descriptor_capacity_integration.py" "$pause_binary"
    run_case callers host-status python3 "$directory/host_status_integration.py" "$release_safe" "$host_status_actor" "$mysql_launch_admin"
    run_case isolated host-launch python3 "$directory/host_launch_integration.py" "$release_safe"
    run_case callers host-stop python3 "$directory/host_stop_integration.py" "$pause_binary" "$host_status_actor"
    run_case callers settings python3 "$directory/settings_integration.py" "$release_safe" --require-mcp-sdk
    run_case isolated admission-debug sh "$directory/admission_integration.sh" "$debug" artifact-smoke
    run_case isolated host-process python3 "$directory/host_process_test.py"
    run_case isolated host-allocator python3 "$directory/host_allocator_test.py" "$release_safe"
}

run_timed() (
    started=$(python3 - <<'PY'
import time
print(time.monotonic_ns())
PY
    ) || started=unavailable
    status=0
    # A hung case fails on its own deadline, naming itself, before the CI step limit.
    python3 "$directory/../ci/case_deadline.py" "${RUI_CASE_TIMEOUT_SECONDS:-900}" "$@" || status=$?
    verdict=passed
    if [ "$status" -ne 0 ]; then verdict=failed; fi
    record=$(python3 - "$name" "$verdict" "$status" "$started" <<'PY'
import sys
import time
finished = time.monotonic_ns()
name, verdict, status, started = sys.argv[1:]
elapsed = "unavailable" if started == "unavailable" else f"{(finished - int(started)) / 1_000_000_000:.3f}s"
print(f"{name} {verdict}: exit={status} elapsed={elapsed}")
PY
    ) || record="$name $verdict: exit=$status elapsed=unavailable"
    if [ "$phase" = serial ]; then
        printf '%s\n' "$record" >&2 || :
    else
        printf '%s\n' "$record" >"$output/$name.status" || :
    fi
    exit "$status"
)

run_case() {
    group=$1
    name=$2
    shift 2
    case "$part:$group" in
        execution:callers|execution:isolated|callers:execution) return ;;
    esac
    case "$phase:$group" in
        batch:isolated|isolated:execution|isolated:callers) return ;;
    esac
    if [ "$phase" = serial ]; then
        run_timed "$@"
    elif [ "$phase" = batch ]; then
        run_timed "$@" >"$output/$name.log" 2>&1 &
        pids="$pids $!"
        names="$names $name"
    else
        if run_timed "$@" >"$output/$name.log" 2>&1; then
            cat "$output/$name.status" || :
            cat "$output/$name.log"
        else
            cat "$output/$name.status" >&2 || :
            cat "$output/$name.log" >&2
            failed=1
        fi
    fi
}

if [ "$part" = parallel ] || [ "$part" = callers ]; then
    output=$(mktemp -d "${TMPDIR:-/tmp}/rui-check.XXXXXX")
    trap 'rm -rf "$output"' EXIT
    pids=
    names=
    phase=batch
    if [ "$part" = parallel ]; then
        unit_mode=aggregate
        if [ -n "$store_binary" ]; then unit_mode=native; fi
        # Give Store's exclusive prelude the first chance at the server lease.
        if [ -n "$store_binary" ]; then
            run_case execution store python3 "$directory/host_process.py" exec env RUI_TEST_EXACT_INACTIVITY=0 python3 "$directory/../ci/store_shards.py" run "$store_binary" --timeout 1200
        fi
        if [ -n "$test_binary" ]; then
            run_case execution native python3 "$directory/host_process.py" exec env RUI_TEST_EXACT_INACTIVITY=0 python3 "$directory/../ci/store_shards.py" "$unit_mode" "$test_binary" --timeout 1200
        fi
    fi
    cases
    set -- $pids
    failed=0
    for name in $names; do
        pid=$1
        shift
        if wait "$pid"; then
            cat "$output/$name.status" || :
            cat "$output/$name.log"
        else
            cat "$output/$name.status" >&2 || :
            cat "$output/$name.log" >&2
            failed=1
        fi
    done
    phase=isolated
    cases
    if [ "$failed" -eq 0 ] && [ -f "$output/native.log" ]; then
        tail -n 1 "$output/native.log"
    fi
    exit "$failed"
fi

phase=serial
cases
