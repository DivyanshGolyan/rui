//! The environment a Bash child starts with, as a value.

const std = @import("std");

/// What the Host reads once at start.
pub const HostFacts = struct {
    /// The running `rui`'s directory, or null when it is unknown.
    executable_dir: ?[]const u8,
    /// The OS system PATH (`os/system_path.zig`).
    system_path: []const u8,
    /// The Host's HOME, only when it is absolute.
    home: ?[]const u8,
};

/// Rui's own variables for one Bash call. They always win.
pub const Identity = struct {
    address: []const u8,
    store: []const u8,
    /// Empty when the Action has no handle; the variable is then left out.
    sender_handle: []const u8,
};

/// A client environment: `"NAME=VALUE\0"` entries in client order, no name
/// repeated and none starting with `RUI_`.
pub const Value = []const u8;

pub const Block = [:null]?[*:0]const u8;

/// The child's `envp`. PATH comes first: the base's PATH, or the system PATH
/// when there is no base or the base has none, led by this `rui`'s
/// directory. Then the base's other entries, or, with no base, the Host's
/// HOME. Then RUI_ADDRESS, RUI_STORE and RUI_SENDER_HANDLE. Entries from
/// `base` are shared, not copied; the rest are allocated in `arena`.
pub fn childBlock(arena: std.mem.Allocator, base: ?Value, facts: HostFacts, identity: Identity) error{OutOfMemory}!Block {
    const inherited = if (base) |value| std.mem.count(u8, value, "\x00") else 0;
    // PATH, HOME and the three identity variables are the most added.
    const block = try arena.allocSentinel(?[*:0]const u8, inherited + 5, null);
    var length: usize = 1;
    var path = facts.system_path;
    if (base) |value| {
        var start: usize = 0;
        while (start < value.len) {
            const end = std.mem.indexOfScalarPos(u8, value, start, 0).?;
            const entry = value[start..end :0];
            std.debug.assert(!std.mem.startsWith(u8, entry, "RUI_"));
            if (std.mem.startsWith(u8, entry, "PATH=")) {
                path = entry["PATH=".len..];
            } else {
                block[length] = entry.ptr;
                length += 1;
            }
            start = end + 1;
        }
    } else if (facts.home) |home| {
        block[length] = try variable(arena, "HOME", home);
        length += 1;
    }
    block[0] = try variable(arena, "PATH", try leadPath(arena, facts.executable_dir, path));
    block[length] = try variable(arena, "RUI_ADDRESS", identity.address);
    block[length + 1] = try variable(arena, "RUI_STORE", identity.store);
    length += 2;
    if (identity.sender_handle.len != 0) {
        block[length] = try variable(arena, "RUI_SENDER_HANDLE", identity.sender_handle);
        length += 1;
    }
    block[length] = null;
    return block[0..length :null];
}

/// `path` with `directory` as its first entry, so a bare `rui` is this
/// build. Unchanged when the directory is unknown, contains ':' (it cannot be
/// one entry), or already leads.
pub fn leadPath(arena: std.mem.Allocator, directory: ?[]const u8, path: []const u8) error{OutOfMemory}![]const u8 {
    const lead = directory orelse return path;
    if (std.mem.indexOfScalar(u8, lead, ':') != null) return path;
    if (std.mem.startsWith(u8, path, lead) and (path.len == lead.len or path[lead.len] == ':')) return path;
    if (path.len == 0) return lead;
    return std.fmt.allocPrint(arena, "{s}:{s}", .{ lead, path });
}

fn variable(arena: std.mem.Allocator, name: []const u8, value: []const u8) error{OutOfMemory}![*:0]const u8 {
    return (try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ name, value }, 0)).ptr;
}

test "childBlock over every base, directory, HOME and sender handle" {
    const system = "/usr/bin:/bin";
    const bases = [_]?Value{
        null,
        "LANG=C\x00",
        "LANG=C\x00PATH=\x00",
        "LANG=C\x00PATH=/client/bin:/bin\x00TERM=x\x00",
        "PATH=/opt/rui:/client/bin\x00LANG=C\x00",
    };
    const directories = [_]?[]const u8{ null, "/opt/a:b", "/opt/rui" };
    // PATH for each base (rows) and directory (columns), written out by hand.
    const paths = [bases.len][directories.len][]const u8{
        .{ system, system, "/opt/rui:" ++ system },
        .{ system, system, "/opt/rui:" ++ system },
        .{ "", "", "/opt/rui" },
        .{ "/client/bin:/bin", "/client/bin:/bin", "/opt/rui:/client/bin:/bin" },
        .{ "/opt/rui:/client/bin", "/opt/rui:/client/bin", "/opt/rui:/client/bin" },
    };
    // The base's entries other than PATH, in order.
    const others = [bases.len][]const []const u8{
        &.{},
        &.{"LANG=C"},
        &.{"LANG=C"},
        &.{ "LANG=C", "TERM=x" },
        &.{"LANG=C"},
    };
    for (bases, paths, others) |base, row, kept| for (directories, row) |directory, path| {
        for ([_]?[]const u8{ null, "/home/peer" }) |home| for ([_][]const u8{ "", "handle-1" }) |handle| {
            var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const facts: HostFacts = .{ .executable_dir = directory, .system_path = system, .home = home };
            const block = try childBlock(arena, base, facts, .{ .address = "k7m2qx", .store = "/store \"q\"", .sender_handle = handle });
            var expected: [8][]const u8 = undefined;
            var count: usize = 0;
            expected[count] = try std.fmt.allocPrint(arena, "PATH={s}", .{path});
            count += 1;
            for (kept) |entry| {
                expected[count] = entry;
                count += 1;
            }
            // Only the fallback brings the Host's HOME; a client's own HOME is its entry.
            if (base == null) if (home) |value| {
                expected[count] = try std.fmt.allocPrint(arena, "HOME={s}", .{value});
                count += 1;
            };
            expected[count] = "RUI_ADDRESS=k7m2qx";
            expected[count + 1] = "RUI_STORE=/store \"q\"";
            count += 2;
            if (handle.len != 0) {
                expected[count] = "RUI_SENDER_HANDLE=handle-1";
                count += 1;
            }
            try std.testing.expectEqual(count, block.len);
            for (expected[0..count], block) |want, got| try std.testing.expectEqualStrings(want, std.mem.span(got.?));
        };
    };
}

test "childBlock with no base matches the Host map it replaces" {
    // The block the base commit's `bash.toolEnvironment` built over
    // `bash.environment("/home/peer")`, as `createPosixBlock` ordered it.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const block = try childBlock(arena_state.allocator(), null, .{
        .executable_dir = "/opt/rui/bin",
        .system_path = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        .home = "/home/peer",
    }, .{ .address = "k7m2qx", .store = "/store \"q\"", .sender_handle = "test-action-handle" });
    const expected = [_][]const u8{
        "PATH=/opt/rui/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME=/home/peer",
        "RUI_ADDRESS=k7m2qx",
        "RUI_STORE=/store \"q\"",
        "RUI_SENDER_HANDLE=test-action-handle",
    };
    try std.testing.expectEqual(expected.len, block.len);
    for (expected, block) |want, got| try std.testing.expectEqualStrings(want, std.mem.span(got.?));
}

test "leadPath is idempotent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]?[]const u8{ null, "/opt/a:b", "/opt/rui", "/opt" }) |directory| {
        for ([_][]const u8{ "", "/bin", "/opt/rui", "/opt/rui:/bin", "/opt/ruin:/bin", "/bin:/opt/rui", ":" }) |path| {
            const once = try leadPath(arena, directory, path);
            try std.testing.expectEqualStrings(once, try leadPath(arena, directory, once));
        }
    }
    // A longer name that starts with the directory is not the directory.
    try std.testing.expectEqualStrings("/opt/rui:/opt/ruin:/bin", try leadPath(arena, "/opt/rui", "/opt/ruin:/bin"));
}
