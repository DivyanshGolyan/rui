#!/bin/sh
set -eu

directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
release_safe=$1
debug=$2

if [ "${3:-}" = parallel ]; then
    test_binary=$4
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

    set -- $pids
    failed=0
    for name in $names; do
        pid=$1
        shift
        if wait "$pid"; then
            printf '%s passed\n' "$name"
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
        else
            printf '%s failed:\n' "$name" >&2
            cat "$output/$name.log" >&2
            failed=1
        fi
    }
    run_isolated_case host-process python3 "$directory/host_process_test.py"
    run_isolated_case admission-debug sh "$directory/admission_integration.sh" "$debug"
    if [ "$failed" -eq 0 ]; then
        tail -n 1 "$output/native.log"
    fi
    exit "$failed"
fi

sh "$directory/admission_integration.sh" "$release_safe"
python3 "$directory/dispatch_integration.py" "$release_safe"
python3 "$directory/bash_owner_integration.py" "$release_safe"
python3 "$directory/bash_integration.py" "$release_safe"
python3 "$directory/bash_lifecycle_integration.py" "$release_safe"
python3 "$directory/bash_recovery_integration.py" "$release_safe"
python3 "$directory/codex_integration.py" "$release_safe"
python3 "$directory/control_integration.py" "$release_safe"
python3 "$directory/descriptor_capacity_integration.py" "$release_safe"
sh "$directory/admission_integration.sh" "$debug"
python3 "$directory/host_process_test.py"
