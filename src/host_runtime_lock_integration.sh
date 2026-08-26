set -eu

fixture=$1
state=$(mktemp -d "${TMPDIR:-/tmp}/onepage-host-lock.XXXXXX")
control="$state/control"
ready="$state/ready"
mkfifo "$control"
pid=
trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi; rm -rf "$state"' EXIT

"$fixture" "$state" <"$control" >"$ready" &
pid=$!
exec 3>"$control"
while ! grep -q '^ready$' "$ready" 2>/dev/null; do
    kill -0 "$pid"
    sleep 0.01
done

if "$fixture" "$state" </dev/null >/dev/null 2>&1; then
    echo "second Host Runtime acquired the lifetime lock" >&2
    exit 1
fi

exec 3>&-
wait "$pid"
pid=
