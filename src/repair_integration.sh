set -eu

onepage=$1
root=$(mktemp -d "${TMPDIR:-/tmp}/onepage-repair.XXXXXX")
trap 'rm -rf "$root"' EXIT
root=$(cd "$root" && pwd -P)

prepare_repo() {
    case_name=$1
    repo="$root/$case_name/repo"
    state="$root/$case_name/state"
    mkdir -p "$repo" "$state"
    git -C "$repo" init -q
    git -C "$repo" config user.name "OnePage Fixture"
    git -C "$repo" config user.email "fixture@onepage.invalid"
    printf '#!/bin/sh\nprintf "red\\n"\n' > "$repo/answer.sh"
    printf '#!/bin/sh\nset -eu\ntest "$(./answer.sh)" = green\n' > "$repo/test.sh"
    chmod +x "$repo/answer.sh" "$repo/test.sh"
    git -C "$repo" add answer.sh test.sh
    git -C "$repo" commit -qm "Create failing repair fixture"
    if (cd "$repo" && ./test.sh); then
        return 1
    fi
    cat > "$root/$case_name/repair.patch" <<'PATCH'
diff --git a/answer.sh b/answer.sh
--- a/answer.sh
+++ b/answer.sh
@@ -1,2 +1,2 @@
 #!/bin/sh
-printf "red\n"
+printf "green\n"
PATCH
}

run_case() {
    case_name=$1
    permission_flag=$2
    prepare_repo "$case_name"
    repo="$root/$case_name/repo"
    state="$root/$case_name/state"
    patch="$root/$case_name/repair.patch"
    answer="Changed answer.sh; committed verification evidence: ./test.sh passed."
    if test -n "$permission_flag"; then
        output=$($onepage \
            --state "$state" \
            --repo "$repo" \
            --model fixture:repair \
            --fixture-response "$answer" \
            --fixture-bash-command ./test.sh \
            --fixture-patch "$patch" \
            "$permission_flag" \
            "Repair the failing executable test, then verify it.")
    else
        output=$(printf 'y\ny\ny\n' | $onepage \
            --state "$state" \
            --repo "$repo" \
            --model fixture:repair \
            --fixture-response "$answer" \
            --fixture-bash-command ./test.sh \
            --fixture-patch "$patch" \
            "Repair the failing executable test, then verify it.")
        approval_count=$(printf '%s\n' "$output" | grep -o 'Approval required' | wc -l | tr -d ' ')
        test "$approval_count" -eq 3
    fi
    printf '%s\n' "$output" | grep -F "Final Answer:" >/dev/null
    printf '%s\n' "$output" | grep -F "$answer" >/dev/null
    (cd "$repo" && ./test.sh)
    git -C "$repo" diff --check
    test "$(git -C "$repo" diff -- answer.sh | grep -c '^+printf "green')" -eq 1
}

run_case ask ""
run_case bypass --dangerously-bypass-permissions

run_permission_input_case() {
    case_name=$1
    decision=$2
    expected_error=$3
    prepare_repo "$case_name"
    repo="$root/$case_name/repo"
    state="$root/$case_name/state"
    if output=$(printf '%s' "$decision" | $onepage \
        --state "$state" \
        --repo "$repo" \
        --model fixture:bash \
        --fixture-response "must resume" \
        --fixture-bash-command ./test.sh \
        "Inspect the failing executable test." 2>&1); then
        return 1
    fi
    printf '%s\n' "$output" | grep -F "error: $expected_error" >/dev/null
    session_id=$(printf '%s\n' "$output" | sed -n 's/^Session: //p' | head -1)
    test -n "$session_id"
    resumed=$(printf 'y\n' | $onepage \
        --state "$state" \
        --resume "$session_id" \
        --model fixture:resume \
        --fixture-response "Approval remained durable and resumable.")
    printf '%s\n' "$resumed" | grep -F "Final Answer:" >/dev/null
    printf '%s\n' "$resumed" | grep -F "Approval remained durable and resumable." >/dev/null
}

run_permission_input_case overlong \
    xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx \
    PermissionDecisionLineTooLong
run_permission_input_case unterminated y PermissionDecisionLineUnterminated
