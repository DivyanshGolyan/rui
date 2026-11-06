"""The one fake `rui` both installer tests serve, and the saved work they install over."""
from pathlib import Path
import sqlite3
import atexit
import functools
import subprocess
import tempfile


def script(version_line, wire, answer, pause=False):
    """A build that prints version_line for --version, answers Host questions
    as a build speaking `wire` would, and prints `answer` for anything else.
    Only a `pause` build knows host pause; earlier builds called it host stop.
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
    --publish-install*) exec "$RUI_TEST_PUBLISH_HELPER" "$@" ;;
    --installation-path)
        [ -z "${{TEST_PATH_FAULT-}}" ] || exit 1
        exec "$RUI_TEST_PUBLISH_HELPER" "$@" ;;
    --installation-facts)
        [ -z "${{TEST_UNKNOWN_FACTS-}}" ] || exit 1
        if [ -n "${{TEST_FACTS-}}" ]; then printf '%s\\n' "$TEST_FACTS"; exit 0; fi
        printf '{{"schema_version":{wire},"minimum_schema_version":%s}}\\n' "${{TEST_MINIMUM_SCHEMA-{wire}}}" ;;
    --version) echo '{version_line}' ;;
    "defaults inspect")
        [ -z "${{TEST_REPORT_FAULT-}}" ] || exit 1
        host=$(state)
        if [ -z "${{TEST_HOST-}}" ] && [ ! -d "$store" ]; then host=store_unavailable; fi
        printf '{{"version":"1","type":"defaults","changed":false,"store":"%s","store_source":"home","store_available":false,"provider":null,"model":null,"local_credentials":{{"codex":"missing","openai":"missing"}},"next_session":{{"status":"choose_provider"}},"host":{{"status":"%s"}}}}\\n' "$store" "$host" ;;
    "host status"|"host status --store "*)
        if [ -n "${{TEST_STATUS_LOG-}}" ]; then printf '%s\\n' "$*" >>"$TEST_STATUS_LOG"; fi
        [ -z "${{TEST_REPORT_FAULT-}}" ] || exit 1
        printf '{{"version":"1","type":"host_status","status":"%s"}}\\n' "$(state)"
        [ "$(state)" != incompatible ] ;;
    "host pause --help") {'exit 0' if pause else 'exit 1'} ;;
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


@functools.lru_cache(maxsize=1)
def native_publisher():
    root = Path(__file__).resolve().parents[2]
    scratch = tempfile.TemporaryDirectory(prefix="rui-native-publisher-")
    atexit.register(scratch.cleanup)
    directory = Path(scratch.name)
    (directory / "src").symlink_to(root / "src", target_is_directory=True)
    main = directory / "publisher.zig"
    main.write_text("""const std = @import("std");
const Installation = @import("src/Installation.zig");
const path = @import("src/installation_path.zig");
pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--installation-path")) {
        const home = init.environ_map.get("HOME") orelse return error.InvalidArguments;
        var observed = try path.inspect(allocator, init.io, home, init.environ_map.get("PATH") orelse "");
        defer observed.deinit(allocator);
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try path.write(&output.writer, &observed, home);
        return std.Io.File.stdout().writeStreamingAll(init.io, output.written());
    }
    if (args.len != 5 or !std.mem.eql(u8, args[1], "--publish-install")) return error.InvalidArguments;
    const intent: Installation.Intent = if (std.mem.eql(u8, args[4], "intentional-source")) .intentional_source
        else if (std.mem.eql(u8, args[4], "released-install")) .released_install
        else if (std.mem.eql(u8, args[4], "released-upgrade")) .released_upgrade
        else return error.InvalidArguments;
    var outcome = try Installation.publishExisting(allocator, init.io, args[2], args[3], intent, null);
    defer outcome.deinit(allocator);
    const receipt = outcome.receipt();
    const json = try std.json.Stringify.valueAlloc(allocator, .{
        .outcome = @tagName(outcome), .operation_build = receipt.operation_build,
        .selected_after = receipt.selected_after,
    }, .{});
    try std.Io.File.stdout().writeStreamingAll(init.io, json);
}
""")
    binary = directory / "publisher"
    subprocess.run(["zig", "build-exe", "-lc", "--dep", "test_poll", f"-Mroot={main}",
                    f"-Mtest_poll={root / 'src/testing/poll.zig'}", f"-femit-bin={binary}"],
                   check=True, capture_output=True, text=True, timeout=60)
    return str(binary)
