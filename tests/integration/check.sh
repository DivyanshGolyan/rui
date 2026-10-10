#!/bin/sh
set -eu

directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
release_safe=$1
debug=$2
printf 'Actual native platform: %s %s\n' "$(uname -s)" "$(uname -m)"

if [ "${3:-}" = parallel ] || [ "${8:-all}" = callers ]; then
    if [ "${3:-}" = parallel ]; then
        test_binary=$4
        host_status_actor=$5
        session_list_client=$6
        proposal_client=$7
        activity_client=$8
        preference_policy_actor=$9
    else
        host_status_actor=$3
        session_list_client=$4
        proposal_client=$5
        activity_client=$6
        preference_policy_actor=$7
    fi
    output=$(mktemp -d "${TMPDIR:-/tmp}/rui-check.XXXXXX")
    trap 'rm -rf "$output"' EXIT
    pids=
    names=
    run_case() {
        name=$1
        shift
        "$@" >"$output/$name.log" 2>&1 &
        pids="$pids $!"
        names="$names $name"
    }

    if [ "${3:-}" = parallel ]; then
        run_case native env RUI_TEST_EXACT_INACTIVITY=0 "$test_binary"
        run_case admission sh "$directory/admission_integration.sh" "$release_safe"
        run_case dispatch python3 "$directory/dispatch_integration.py" "$release_safe"
        run_case bash-owner python3 "$directory/bash_owner_integration.py" "$release_safe"
        run_case bash python3 "$directory/bash_integration.py" "$release_safe"
        run_case bash-lifecycle python3 "$directory/bash_lifecycle_integration.py" "$release_safe"
        run_case bash-recovery python3 "$directory/bash_recovery_integration.py" "$release_safe"
        run_case codex python3 "$directory/codex_integration.py" "$release_safe"
        run_case control python3 "$directory/control_integration.py" "$release_safe"
        run_case descriptor-capacity python3 "$directory/descriptor_capacity_integration.py" "$release_safe"
    fi
    # These callers already share the ordinary parallel gate. Each fixture owns
    # its private Store/HOME, endpoint and Host; census never spans the worker.
    run_case human-cli python3 "$directory/human_cli_integration.py" "$release_safe"
    run_case preference-policy python3 "$directory/preference_policy_integration.py" "$preference_policy_actor"
    run_case session-list python3 "$directory/session_list_integration.py" "$release_safe" "$session_list_client"
    run_case conversation-page python3 "$directory/conversation_page_integration.py" "$release_safe"
    run_case proposal python3 "$directory/proposal_integration.py" "$release_safe" "$proposal_client"
    run_case activity python3 "$directory/activity_integration.py" "$release_safe" "$activity_client"
    run_case host-status python3 "$directory/host_status_integration.py" "$release_safe" "$host_status_actor"
    run_case host-stop python3 "$directory/host_stop_integration.py" "$release_safe" "$host_status_actor"

    set -- $pids
    failed=0
    for name in $names; do
        pid=$1
        shift
        if wait "$pid"; then
            printf '%s passed\n' "$name"
            cat "$output/$name.log"
        else
            printf '%s failed:\n' "$name" >&2
            cat "$output/$name.log" >&2
            failed=1
        fi
    done
    # Host startup and Debug capture have short deadlines. Test them after the
    # parallel load so those deadlines observe behavior rather than CPU share.
    run_isolated_case() {
        name=$1
        shift
        if "$@" >"$output/$name.log" 2>&1; then
            printf '%s passed\n' "$name"
            cat "$output/$name.log"
        else
            printf '%s failed:\n' "$name" >&2
            cat "$output/$name.log" >&2
            failed=1
        fi
    }
    run_isolated_case host-process python3 "$directory/host_process_test.py"
    run_isolated_case host-allocator python3 "$directory/host_allocator_test.py" "$release_safe"
    run_isolated_case host-launch python3 "$directory/host_launch_integration.py" "$release_safe"
    run_isolated_case admission-debug sh "$directory/admission_integration.sh" "$debug" artifact-smoke
    if [ "$failed" -eq 0 ] && [ -f "$output/native.log" ]; then
        tail -n 1 "$output/native.log"
    fi
    exit "$failed"
fi

host_status_actor=$3
session_list_client=$4
proposal_client=$5
activity_client=$6
preference_policy_actor=$7
part=${8:-all}
case "$part" in
    all|execution|callers) ;;
    *) printf 'Unknown full-check part: %s\n' "$part" >&2; exit 2 ;;
esac
# The execution part stays serial. The callers part above uses the existing
# parallel-safe batch; default all preserves the complete serial gate and order.
if [ "$part" != callers ]; then
    sh "$directory/admission_integration.sh" "$release_safe"
    python3 "$directory/dispatch_integration.py" "$release_safe"
    python3 "$directory/bash_owner_integration.py" "$release_safe"
    python3 "$directory/bash_integration.py" "$release_safe"
fi
if [ "$part" != execution ]; then
    python3 "$directory/human_cli_integration.py" "$release_safe"
    python3 "$directory/preference_policy_integration.py" "$preference_policy_actor"
fi
if [ "$part" != callers ]; then
    python3 "$directory/bash_lifecycle_integration.py" "$release_safe"
    python3 "$directory/bash_recovery_integration.py" "$release_safe"
    python3 "$directory/codex_integration.py" "$release_safe"
    python3 "$directory/control_integration.py" "$release_safe"
fi
if [ "$part" != execution ]; then
    python3 "$directory/session_list_integration.py" "$release_safe" "$session_list_client"
    python3 "$directory/conversation_page_integration.py" "$release_safe"
    python3 "$directory/proposal_integration.py" "$release_safe" "$proposal_client"
    python3 "$directory/activity_integration.py" "$release_safe" "$activity_client"
fi
if [ "$part" != callers ]; then
    python3 "$directory/descriptor_capacity_integration.py" "$release_safe"
fi
if [ "$part" != execution ]; then
    python3 "$directory/host_status_integration.py" "$release_safe" "$host_status_actor"
    python3 "$directory/host_launch_integration.py" "$release_safe"
    python3 "$directory/host_stop_integration.py" "$release_safe" "$host_status_actor"
    sh "$directory/admission_integration.sh" "$debug" artifact-smoke
    python3 "$directory/host_process_test.py"
    python3 "$directory/host_allocator_test.py" "$release_safe"
fi
