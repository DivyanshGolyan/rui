#!/bin/sh
set -eu

fixture=$1
root=$(mktemp -d "${TMPDIR:-/tmp}/onepage-relational-crash.XXXXXX")
trap 'rm -rf "$root"' EXIT HUP INT TERM

expect_crash() {
    database=$1
    mode=$2
    set +e
    "$fixture" "$database" "$mode"
    status=$?
    set -e
    test "$status" -eq 91
}

turn_database="$root/turn.sqlite3"
expect_crash "$turn_database" turn-before
"$fixture" "$turn_database" verify-empty
expect_crash "$turn_database" turn-after
"$fixture" "$turn_database" verify-turn

operation_database="$root/operation.sqlite3"
"$fixture" "$operation_database" seed-turn
expect_crash "$operation_database" operation-before
"$fixture" "$operation_database" verify-no-operation
expect_crash "$operation_database" operation-after
"$fixture" "$operation_database" verify-operation

attempt_database="$root/attempt.sqlite3"
"$fixture" "$attempt_database" seed-operation-only
expect_crash "$attempt_database" attempt-before
"$fixture" "$attempt_database" verify-no-attempt
expect_crash "$attempt_database" attempt-after
"$fixture" "$attempt_database" verify-attempt

resolution_database="$root/resolution.sqlite3"
"$fixture" "$resolution_database" seed-operation
expect_crash "$resolution_database" resolution-before
"$fixture" "$resolution_database" verify-unresolved
expect_crash "$resolution_database" resolution-after
"$fixture" "$resolution_database" verify-resolved

completion_database="$root/completion.sqlite3"
"$fixture" "$completion_database" seed-operation
expect_crash "$completion_database" completion-after
"$fixture" "$completion_database" verify-completion

final_database="$root/final.sqlite3"
"$fixture" "$final_database" seed-operation
expect_crash "$final_database" final-before
"$fixture" "$final_database" verify-final-uncommitted
expect_crash "$final_database" final-after
"$fixture" "$final_database" verify-final

failure_database="$root/failure.sqlite3"
"$fixture" "$failure_database" seed-operation
expect_crash "$failure_database" failure-before
"$fixture" "$failure_database" verify-failure-uncommitted
expect_crash "$failure_database" failure-after
"$fixture" "$failure_database" verify-failure

cancellation_database="$root/cancellation.sqlite3"
"$fixture" "$cancellation_database" seed-turn
expect_crash "$cancellation_database" cancel-before
"$fixture" "$cancellation_database" verify-cancel-uncommitted
expect_crash "$cancellation_database" cancel-after
"$fixture" "$cancellation_database" verify-cancelled
