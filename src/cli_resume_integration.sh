set -eu

fixture=$1
onepage=$2
state=$(mktemp -d "${TMPDIR:-/tmp}/onepage-cli-resume.XXXXXX")
trap 'rm -rf "$state"' EXIT

invalid_state="$state/invalid-model-state"
if "$onepage" --state "$invalid_state" --model codex: task >/dev/null 2>&1; then
    printf '%s\n' "empty Codex model unexpectedly succeeded" >&2
    exit 1
fi
if [ -e "$invalid_state" ]; then
    printf '%s\n' "invalid model created durable state before rejection" >&2
    exit 1
fi

session_id=$($fixture "$state")

if "$onepage" \
    --state "$state" \
    --resume "$session_id" \
    --model codex:gpt-5.6-sol >/dev/null 2>&1; then
    printf '%s\n' "cross-provider fixture-to-Codex resume unexpectedly succeeded" >&2
    exit 1
fi
if "$onepage" \
    --state "$state" \
    --resume "$session_id" \
    --model fixture:different \
    --fixture-response "wrong model" >/dev/null 2>&1; then
    printf '%s\n' "same-provider model mismatch unexpectedly succeeded" >&2
    exit 1
fi
output=$($onepage \
    --state "$state" \
    --resume "$session_id" \
    --model fixture:interrupted \
    --fixture-response "resumed through the CLI")

case "$output" in
    *"Final Answer:"*"resumed through the CLI"*) ;;
    *)
        printf '%s\n' "$output" >&2
        exit 1
        ;;
esac

codex_state="$state/codex-state"
codex_session_id=$($fixture "$codex_state" codex:gpt-5.6-sol)
if "$onepage" \
    --state "$codex_state" \
    --resume "$codex_session_id" \
    --model fixture:wrong-provider \
    --fixture-response "wrong provider" >/dev/null 2>&1; then
    printf '%s\n' "cross-provider Codex-to-fixture resume unexpectedly succeeded" >&2
    exit 1
fi
if "$onepage" \
    --state "$codex_state" \
    --resume "$codex_session_id" \
    --model codex:different >/dev/null 2>&1; then
    printf '%s\n' "same-provider Codex model mismatch unexpectedly succeeded" >&2
    exit 1
fi
