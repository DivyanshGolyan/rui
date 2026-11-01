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

/// A client environment as the Host received it, checked and cleaned in
/// place: each entry is `NAME=VALUE\0` with a non-empty NAME, and no NAME
/// appears twice. Entries whose NAME starts with `RUI_` are removed, because
/// Rui's overlay owns that prefix; `RUIX`, `rui_x` and `XRUI_` are ordinary
/// names. `scratch` is borrowed for the duplicate check and freed before
/// return. The result is a prefix of `bytes`.
pub fn received(scratch: std.mem.Allocator, bytes: []u8) error{ OutOfMemory, InvalidEnvironment }!Value {
    if (bytes.len != 0 and bytes[bytes.len - 1] != 0) return error.InvalidEnvironment;
    var kept: usize = 0;
    var count: usize = 0;
    var start: usize = 0;
    while (start < bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, start, 0).?;
        const equals = std.mem.indexOfScalar(u8, bytes[start..end], '=') orelse return error.InvalidEnvironment;
        if (equals == 0) return error.InvalidEnvironment;
        if (!std.mem.startsWith(u8, bytes[start..end], "RUI_")) {
            std.mem.copyForwards(u8, bytes[kept..], bytes[start .. end + 1]);
            kept += end + 1 - start;
            count += 1;
        }
        start = end + 1;
    }
    const value = bytes[0..kept];
    // Sorted names put a repeat beside its first copy.
    const starts = try scratch.alloc(u32, count);
    defer scratch.free(starts);
    var next: usize = 0;
    for (starts) |*entry| {
        entry.* = @intCast(next);
        next = std.mem.indexOfScalarPos(u8, value, next, 0).? + 1;
    }
    std.mem.sort(u32, starts, value, nameLessThan);
    for (starts[0..count -| 1], starts[@min(1, count)..]) |left, right| {
        if (std.mem.eql(u8, entryName(value, left), entryName(value, right))) return error.InvalidEnvironment;
    }
    return value;
}

fn entryName(value: []const u8, start: u32) []const u8 {
    return value[start..std.mem.indexOfScalarPos(u8, value, start, '=').?];
}

fn nameLessThan(value: []const u8, left: u32, right: u32) bool {
    return std.mem.lessThan(u8, entryName(value, left), entryName(value, right));
}

/// Which Message an environment came with, to choose between two for one
/// Session. A person's outranks a peer Session's; between equal origins the
/// later Store admission wins. Admission positions are unique in a Store, so
/// two different Messages never tie.
pub const Rank = struct {
    origin: Origin,
    admission: u64,

    pub const Origin = enum(u8) { peer, person };

    pub fn outranks(self: Rank, other: Rank) bool {
        if (self.origin != other.origin) return @backingInt(self.origin) > @backingInt(other.origin);
        return self.admission > other.admission;
    }
};

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
        block[length] = (try variable(arena, "HOME", home)).ptr;
        length += 1;
    }
    block[0] = (try leadPath(arena, facts.executable_dir, path)).ptr;
    block[length] = (try variable(arena, "RUI_ADDRESS", identity.address)).ptr;
    block[length + 1] = (try variable(arena, "RUI_STORE", identity.store)).ptr;
    length += 2;
    if (identity.sender_handle.len != 0) {
        block[length] = (try variable(arena, "RUI_SENDER_HANDLE", identity.sender_handle)).ptr;
        length += 1;
    }
    block[length] = null;
    return block[0..length :null];
}

/// `PATH=` and `path` with `directory` as its first entry and no other
/// copy of it, so a bare `rui` is this build. `path` is unchanged when the
/// directory is unknown or contains ':' (it cannot be one entry). An empty
/// `path` becomes the directory alone, since a trailing ':' would search the
/// working directory.
pub fn leadPath(arena: std.mem.Allocator, directory: ?[]const u8, path: []const u8) error{OutOfMemory}![:0]const u8 {
    const prefix = "PATH=";
    const lead = directory orelse return variable(arena, "PATH", path);
    if (std.mem.indexOfScalar(u8, lead, ':') != null) return variable(arena, "PATH", path);
    const buffer = try arena.allocSentinel(u8, prefix.len + lead.len + 1 + path.len, 0);
    @memcpy(buffer[0..prefix.len], prefix);
    @memcpy(buffer[prefix.len..][0..lead.len], lead);
    var length = prefix.len + lead.len;
    if (path.len != 0) {
        var entries = std.mem.splitScalar(u8, path, ':');
        while (entries.next()) |entry| {
            if (std.mem.eql(u8, entry, lead)) continue;
            buffer[length] = ':';
            @memcpy(buffer[length + 1 ..][0..entry.len], entry);
            length += 1 + entry.len;
        }
    }
    buffer[length] = 0;
    return buffer[0..length :0];
}

fn variable(arena: std.mem.Allocator, name: []const u8, value: []const u8) error{OutOfMemory}![:0]const u8 {
    return std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ name, value }, 0);
}

test "childBlock over every base, directory, HOME and sender handle" {
    const system = "/usr/bin:/bin";
    const bases = [_]?Value{
        null,
        "LANG=C\x00",
        "LANG=C\x00PATH=\x00",
        "LANG=C\x00PATH=/client/bin:/bin\x00HOME=/home/client\x00",
        "PATH=/opt/rui:/client/bin\x00LANG=C\x00",
        "PATH=/bin:/opt/rui::/opt/rui/\x00",
    };
    const directories = [_]?[]const u8{ null, "/opt/a:b", "/opt/rui" };
    // PATH for each base (rows) and directory (columns), written out by hand.
    const paths = [bases.len][directories.len][]const u8{
        .{ system, system, "/opt/rui:" ++ system },
        .{ system, system, "/opt/rui:" ++ system },
        .{ "", "", "/opt/rui" },
        .{ "/client/bin:/bin", "/client/bin:/bin", "/opt/rui:/client/bin:/bin" },
        .{ "/opt/rui:/client/bin", "/opt/rui:/client/bin", "/opt/rui:/client/bin" },
        .{ "/bin:/opt/rui::/opt/rui/", "/bin:/opt/rui::/opt/rui/", "/opt/rui:/bin::/opt/rui/" },
    };
    // The base's entries other than PATH, in order.
    const others = [bases.len][]const []const u8{
        &.{},
        &.{"LANG=C"},
        &.{"LANG=C"},
        &.{ "LANG=C", "HOME=/home/client" },
        &.{"LANG=C"},
        &.{},
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

test "leadPath puts the directory first once and is idempotent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]?[]const u8{ null, "/opt/a:b", "/opt/rui", "/opt" }) |directory| {
        for ([_][]const u8{ "", "/bin", "/opt/rui", "/opt/rui:/bin", "/opt/ruin:/bin", "/bin:/opt/rui", ":", "/bin::/opt/rui:/opt/rui" }) |path| {
            const once = (try leadPath(arena, directory, path))["PATH=".len..];
            try std.testing.expectEqualStrings(once, (try leadPath(arena, directory, once))["PATH=".len..]);
        }
    }
    // A system PATH that already holds the directory keeps one copy, first.
    try std.testing.expectEqualStrings("PATH=/usr/local/bin:/usr/bin:/bin", try leadPath(arena, "/usr/local/bin", "/usr/bin:/usr/local/bin:/bin"));
    // A longer name that starts with the directory is another entry.
    try std.testing.expectEqualStrings("PATH=/opt/rui:/opt/ruin:/bin", try leadPath(arena, "/opt/rui", "/opt/ruin:/bin"));
    try std.testing.expectEqualStrings("PATH=/opt/rui", try leadPath(arena, "/opt/rui", ""));
}

test "received keeps well-formed entries in order and strips only RUI_ names" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "", "" },
        .{ "A=1\x00", "A=1\x00" },
        .{ "A=\x00", "A=\x00" },
        .{ "A==b=c\x00", "A==b=c\x00" },
        .{ "RUI_X=1\x00", "" },
        .{ "RUI_=1\x00", "" },
        .{ "B=2\x00RUI_STORE=/s\x00A=1\x00RUI_ADDRESS=k\x00", "B=2\x00A=1\x00" },
        .{ "RUIX=1\x00rui_x=2\x00XRUI_=3\x00RUI=4\x00Rui_X=5\x00", "RUIX=1\x00rui_x=2\x00XRUI_=3\x00RUI=4\x00Rui_X=5\x00" },
        // A repeat of a stripped name is no repeat: neither copy is kept.
        .{ "RUI_X=1\x00RUI_X=2\x00A=1\x00", "A=1\x00" },
        .{ "PATH=/bin\x00path=/usr/bin\x00", "PATH=/bin\x00path=/usr/bin\x00" },
        .{ "AB=1\x00A=1\x00B=1\x00", "AB=1\x00A=1\x00B=1\x00" },
    };
    for (cases) |case| {
        const bytes = try std.testing.allocator.dupe(u8, case[0]);
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings(case[1], try received(std.testing.allocator, bytes));
    }
}

test "received rejects every malformed shape" {
    const cases = [_][]const u8{
        "A=1",
        "A=1\x00B=2",
        "A\x00",
        "\x00",
        "=1\x00",
        "A=1\x00\x00",
        "A=1\x00A=2\x00",
        "A=1\x00B=1\x00A=1\x00",
        "RUI_X=1\x00A=1\x00A=1\x00",
        "A=1\x00RUI_X\x00",
    };
    for (cases) |case| {
        const bytes = try std.testing.allocator.dupe(u8, case);
        defer std.testing.allocator.free(bytes);
        try std.testing.expectError(error.InvalidEnvironment, received(std.testing.allocator, bytes));
    }
}

test "Rank.outranks is a strict total order: a person first, then the later admission" {
    var ranks: [2 * 3]Rank = undefined;
    for (&ranks, 0..) |*rank, index| rank.* = .{ .origin = @fromBackingInt(@intCast(index / 3)), .admission = index % 3 };
    for (ranks) |a| {
        try std.testing.expect(!a.outranks(a));
        for (ranks) |b| {
            const same = a.origin == b.origin and a.admission == b.admission;
            // Total and antisymmetric: exactly one of two different ranks outranks the other.
            if (!same) try std.testing.expect(a.outranks(b) != b.outranks(a));
            // The rule, read independently of `outranks`.
            const expected = if (a.origin != b.origin) a.origin == .person else a.admission > b.admission;
            try std.testing.expectEqual(expected, a.outranks(b));
            for (ranks) |c| if (a.outranks(b) and b.outranks(c)) try std.testing.expect(a.outranks(c));
        }
    }
}
