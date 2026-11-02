"""The one fake `rui` both installer tests serve, and the saved work they install over."""
from pathlib import Path
import sqlite3


def script(version_line, wire, answer):
    """A build that prints version_line for --version, answers Host questions
    as a build speaking `wire` would, and prints `answer` for anything else.
    TEST_HOST names the running Host's wire, or `busy` for a Host that holds
    the Store but does not answer. TEST_REPORT_FAULT=1 makes defaults inspect
    and host status fail. The JSON mirrors cli.zig's writers;
    host_status_integration.py pins the installer's reader against them."""
    return f'''#!/bin/sh
store="$HOME/.local/share/rui/store"
state() {{
    case ${{TEST_HOST-}} in
        '') echo unavailable ;;
        busy) echo owned_unavailable ;;
        {wire}) echo ready ;;
        *) echo incompatible ;;
    esac
}}
case "$*" in
    --version) echo '{version_line}' ;;
    "defaults inspect")
        [ -z "${{TEST_REPORT_FAULT-}}" ] || exit 1
        host=$(state)
        if [ -z "${{TEST_HOST-}}" ] && [ ! -d "$store" ]; then host=store_unavailable; fi
        printf '{{"version":"1","type":"defaults","changed":false,"store":"%s","store_source":"home","store_available":false,"provider":null,"model":null,"local_credentials":{{"codex":"missing","openai":"missing"}},"next_session":{{"status":"choose_provider"}},"host":{{"status":"%s"}}}}\\n' "$store" "$host" ;;
    "host status")
        [ -z "${{TEST_REPORT_FAULT-}}" ] || exit 1
        printf '{{"version":"1","type":"host_status","status":"%s"}}\\n' "$(state)"
        [ "$(state)" != incompatible ] ;;
    *) echo '{answer}' ;;
esac
'''


def saved_work(home, schema, *, unwritten=False):
    """Create the default Store's database in home at `schema`. With
    `unwritten`, return its open WAL connection: until it closes, the file's
    header still says user_version 0, as under a Host that has not
    checkpointed."""
    path = Path(home) / ".local/share/rui/store/rui.sqlite3"
    path.parent.mkdir(parents=True, exist_ok=True)
    database = sqlite3.connect(path)
    if unwritten:
        database.execute("PRAGMA journal_mode=WAL")
    database.execute(f"PRAGMA user_version={schema}")
    database.commit()
    if unwritten:
        return database
    database.close()
    return None
