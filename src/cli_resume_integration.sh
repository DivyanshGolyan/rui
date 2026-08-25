set -eu

fixture=$1
onepage=$2
state=$(mktemp -d "${TMPDIR:-/tmp}/onepage-cli-resume.XXXXXX")
trap 'rm -rf "$state"' EXIT

session_id=$($fixture "$state")
output=$($onepage \
    --state "$state" \
    --resume "$session_id" \
    --model fixture:resume \
    --fixture-response "resumed through the CLI")

case "$output" in
    *"Final Answer:"*"resumed through the CLI"*) ;;
    *)
        printf '%s\n' "$output" >&2
        exit 1
        ;;
esac
