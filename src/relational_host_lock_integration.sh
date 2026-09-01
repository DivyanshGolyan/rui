set -eu

fixture=$1
root=$(mktemp -d "${TMPDIR:-/tmp}/onepage-relational-host-lock.XXXXXX")
database="$root/host.sqlite3"
control="$root/control"
ready="$root/ready"
mkfifo "$control"
pid=
trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi; rm -rf "$root"' EXIT HUP INT TERM

"$fixture" "$database" <"$control" >"$ready" &
pid=$!
exec 3>"$control"
while ! grep -q '^ready$' "$ready" 2>/dev/null; do
    kill -0 "$pid"
    sleep 0.01
done

if "$fixture" "$database" </dev/null >/dev/null 2>&1; then
    echo "second Host acquired the Store lifetime lock" >&2
    exit 1
fi

exec 3>&-
wait "$pid"
pid=
"$fixture" "$database" </dev/null >/dev/null
