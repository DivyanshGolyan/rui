//! One invocation's charged libvaxis grids and frozen frame bytes.
//! No terminal, input, scroll position, domain projection or delivery authority.
//! Initialize in final storage; every allocator points back to this owner.
const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const Self = @This();

pub const max_cells = 49_152;
pub const memory_limit = 32 * 1024 * 1024;
const frame_link_bytes = 128 * 1024;
const grid_link_bytes = 512 * 1024;
const postlude = vaxis.ctlseqs.osc8_clear ++ vaxis.ctlseqs.sgr_reset;

/// Appearance roles, day/night palettes and ASCII fallback belong to callers.
/// This policy is explicit: libvaxis capability detection never changes it.
pub const Policy = struct {
    width: vaxis.gwidth.Method = .wcwidth,
    depth: enum { none, indexed, direct } = .indexed,
};

const Phase = enum { cold, idle, painting, encoded, poisoned };
phase: Phase = .cold,
memory: Memory = .{},
policy_value: Policy = .{},
storage: ?Storage = null,

const Storage = struct {
    vx: vaxis.Vaxis,
    frame: std.Io.Writer.Allocating,
    prefix: std.Io.Writer.Allocating,
    scratch: std.heap.ArenaAllocator,
};

pub fn init(self: *Self, io: std.Io, environ: *std.process.Environ.Map, policy_value: Policy) !void {
    // Reinitializing a failed/disposed backend cannot authorize another diff.
    if (self.phase != .cold) return error.RenderBackendPoisoned;
    self.phase = .poisoned;
    const alloc = self.memory.allocator();
    // Evaluate the fallible initializer before publishing optional storage:
    // a partial aggregate assignment must not make disposal see an invalid grid.
    const vx = try vaxis.init(io, alloc, environ, .{});
    self.storage = .{
        .vx = vx,
        .frame = .init(alloc),
        .prefix = .init(alloc),
        .scratch = .init(alloc),
    };
    self.policy_value = policy_value;
    self.applyPolicy();
    // SessionTerminal, never Vaxis.Tty, owns modes and their restoration.
    self.storage.?.vx.state.alt_screen = true;
    self.phase = .idle;
}

/// Memory disposal only, after terminal restoration and all borrowers leave.
/// Idempotent, and poison stays sticky even after disposal or failed init.
pub fn deinit(self: *Self) void {
    self.phase = .poisoned;
    if (self.storage) |*s| {
        s.frame.deinit();
        s.prefix.deinit();
        s.scratch.deinit();
        s.vx.screen.deinit(self.memory.allocator());
        s.vx.screen_last.deinit(self.memory.allocator());
        self.storage = null;
    }
    std.debug.assert(self.memory.used == 0);
}

pub fn poison(self: *Self) void {
    self.phase = .poisoned;
}

pub fn policy(self: *const Self) Policy {
    return self.policy_value;
}

pub fn widthMethod(self: *const Self) vaxis.gwidth.Method {
    return self.policy_value.width;
}

/// Derived from the one current grid, not another stored geometry/offset.
pub fn geometry(self: *const Self) vaxis.Winsize {
    const screen = &self.storage.?.vx.screen;
    return .{ .cols = screen.width, .rows = screen.height, .x_pixel = screen.width_pix, .y_pixel = screen.height_pix };
}

pub const Usage = struct { used: usize, peak: usize };
pub fn usage(self: *const Self) Usage {
    return .{ .used = self.memory.used, .peak = self.memory.peak };
}

/// Healthy redraw only. NOT recovery from an encoding/partial-output failure.
pub fn invalidate(self: *Self) void {
    std.debug.assert(self.phase == .idle);
    self.storage.?.vx.queueRefresh();
}

/// Apply outside an in-flight frame. The domain captures/reflows its anchor
/// and invalidates its consent scope separately, before the next begin.
pub fn setPolicy(self: *Self, value: Policy) bool {
    std.debug.assert(self.phase == .idle);
    if (std.meta.eql(self.policy_value, value)) return false;
    self.policy_value = value;
    self.applyPolicy();
    self.invalidate();
    return true;
}

fn applyPolicy(self: *Self) void {
    const vx = &self.storage.?.vx;
    vx.caps.unicode = self.policy_value.width;
    vx.screen.width_method = self.policy_value.width;
    vx.caps.no_color = self.policy_value.depth == .none;
    vx.caps.rgb = self.policy_value.depth == .direct;
}

pub fn validateGeometry(size: vaxis.Winsize) !void {
    if (size.cols < 8 or size.rows < 2) return error.TerminalTooSmall;
    if (@as(u32, size.cols) * size.rows > max_cells) return error.TerminalTooLarge;
}

/// Start one nonpumping paint. Failed begin poisons even before a caller can
/// install its errdefer. Resize retires old grids before charging replacements.
pub fn begin(self: *Self, size: vaxis.Winsize) !void {
    if (self.phase == .poisoned) return error.RenderBackendPoisoned;
    std.debug.assert(self.phase == .idle);
    errdefer self.poison();
    try validateGeometry(size);
    self.phase = .painting;
    const s = &self.storage.?;
    const old = self.geometry();
    if (old.cols != size.cols or old.rows != size.rows) {
        const alloc = self.memory.allocator();
        const empty = try vaxis.AllocatingScreen.init(alloc, 0, 0);
        s.vx.screen.deinit(alloc);
        s.vx.screen_last.deinit(alloc);
        s.vx.screen = .{};
        s.vx.screen_last = empty;
        s.vx.resize(alloc, &s.frame.writer, size) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory, // Known allocating writer only.
            else => return err,
        };
    } else {
        s.vx.screen.width_pix = size.x_pixel;
        s.vx.screen.height_pix = size.y_pixel;
    }
    const win = s.vx.window();
    win.clear();
    win.hideCursor();
    win.setCursorShape(.default);
}

/// Borrowed only until encode/end. Every generated text/URI slice used by a
/// helper must live in this scratch arena, or remain in scope through encode.
pub fn scratch(self: *Self) std.mem.Allocator {
    std.debug.assert(self.phase == .painting);
    return self.storage.?.scratch.allocator();
}

pub fn window(self: *Self) vaxis.Window {
    std.debug.assert(self.phase == .painting);
    return self.storage.?.vx.window();
}

/// Memory writer, never output. Prefix precedes resize controls and rendering.
/// Its WriteFailed can only be allocation failure; callers staging terminal
/// reports must translate it there, never translate a real output failure.
pub fn prefixWriter(self: *Self) *std.Io.Writer {
    std.debug.assert(self.phase == .painting);
    return &self.storage.?.prefix.writer;
}

/// Freeze BEFORE any pumping output. Returned bytes borrow this owner until
/// end. Caller issues its domain ticket now, writes/flushes, then presents its
/// own receipt. On output failure caller poisons; this owner mints no receipt.
pub fn encode(self: *Self) ![]const u8 {
    if (self.phase == .poisoned) return error.RenderBackendPoisoned;
    std.debug.assert(self.phase == .painting);
    errdefer self.poison();
    const s = &self.storage.?;
    try self.admitCells();
    // begin already staged resize controls. Only that small prefix is shifted;
    // no second full encoded frame or external copy of the grid is created.
    const prefix = s.prefix.written();
    if (prefix.len != 0) {
        const resize_len = s.frame.written().len;
        try s.frame.ensureUnusedCapacity(prefix.len);
        std.mem.copyBackwards(u8, s.frame.writer.buffer[prefix.len..][0..resize_len], s.frame.written());
        @memcpy(s.frame.writer.buffer[0..prefix.len], prefix);
        s.frame.writer.end += prefix.len;
    }
    s.vx.render(&s.frame.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory, // NOT a terminal writer.
        else => return err,
    };
    // Prefix-only and resize-only frames must also leave links/style neutral.
    // A genuinely empty unchanged frame must keep its zero-output behavior.
    if (s.frame.written().len != 0)
        s.frame.writer.writeAll(postlude) catch return error.OutOfMemory;
    // The retained grid owns its copies now. Erase borrowed cell payloads,
    // not cursor/render metadata, before scratch is freed or input can pump.
    self.scrubCells();
    self.phase = .encoded;
    return s.frame.written();
}

/// Release a completed frame, or clean a poisoned attempt. Ending an unencoded
/// paint is not cache recovery. Neither end nor deinit can clear poison.
pub fn end(self: *Self) void {
    std.debug.assert(self.phase == .painting or self.phase == .encoded or self.phase == .poisoned);
    const completed = self.phase == .encoded;
    if (self.storage) |*s| {
        self.scrubCells();
        s.frame.deinit();
        s.frame = .init(self.memory.allocator());
        s.prefix.deinit();
        s.prefix = .init(self.memory.allocator());
        s.scratch.deinit();
        s.scratch = .init(self.memory.allocator());
    }
    self.phase = if (completed) .idle else .poisoned;
}

fn scrubCells(self: *Self) void {
    for (self.storage.?.vx.screen.buf) |*cell| {
        cell.char.grapheme = "";
        cell.link = .{};
        cell.image = null;
    }
}

/// One link/style admission boundary for every screen. Params are unsupported,
/// not an unaccounted retained URI-ID channel. Text/URI control sanitation is
/// still the domain's responsibility before painting.
fn admitCells(self: *Self) !void {
    const vx = &self.storage.?.vx;
    if (vx.screen.cursor_secondary.len != 0) return error.UnsupportedRenderCursor;
    var linked: usize = 0;
    var kept: usize = 0;
    for (vx.screen.buf, vx.screen_last.buf) |*cell, last| {
        if (cell.link.params.len != 0) return error.UnsupportedLinkParams;
        if (cell.image != null) return error.UnsupportedRenderImage;
        switch (self.policy_value.depth) {
            .none => {
                // NO_COLOR suppresses colors, not domain-owned Markdown
                // attributes. Overview itself chooses bold/reverse only.
                if (cell.style.fg != .default or cell.style.bg != .default or cell.style.ul != .default)
                    return error.InvalidRenderStyle;
            },
            .indexed => {
                if (cell.style.fg == .rgb or cell.style.bg == .rgb or cell.style.ul == .rgb)
                    return error.InvalidRenderStyle;
            },
            .direct => {},
        }
        kept += last.uri.capacity;
        if (cell.link.uri.len > frame_link_bytes - linked) cell.link = .{} else linked += cell.link.uri.len;
    }
    if (kept < grid_link_bytes) return;
    const alloc = self.memory.allocator();
    const width = vx.screen_last.width;
    const height = vx.screen_last.height;
    const empty = try vaxis.AllocatingScreen.init(alloc, 0, 0);
    vx.screen_last.deinit(alloc);
    vx.screen_last = empty;
    const replacement = try vaxis.AllocatingScreen.init(alloc, width, height);
    vx.screen_last.deinit(alloc);
    vx.screen_last = replacement;
    vx.queueRefresh();
}

// Actual page-rounded backing bytes, including transient growth/copy peaks.
// Two maximum grids take about 15.41 MiB; the rest serves retained graphemes,
// links, generated paint text and frozen prefix/resize/render bytes together.
const Memory = struct {
    used: usize = 0,
    peak: usize = 0,
    fault: if (builtin.is_test) Fault else void = if (builtin.is_test) .{} else {},
    const Fault = struct { after: ?usize = null, attempts: usize = 0 };

    fn allocator(self: *Memory) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }

    fn charge(length: usize) usize {
        const page = if (builtin.is_test) @max(16384, std.heap.pageSize()) else std.heap.pageSize();
        return std.mem.alignForward(usize, length, page);
    }

    fn alloc(raw: *anyopaque, length: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *Memory = @ptrCast(@alignCast(raw));
        if (builtin.is_test) {
            const attempt = self.fault.attempts;
            self.fault.attempts += 1;
            if (self.fault.after) |after| if (attempt >= after) return self.refuse();
        }
        if (length > memory_limit) return self.refuse();
        const amount = charge(length);
        if (amount > memory_limit - self.used) return self.refuse();
        const result = std.heap.page_allocator.rawAlloc(length, alignment, address) orelse return self.refuse();
        self.used += amount;
        self.peak = @max(self.peak, self.used);
        return result;
    }

    fn refuse(self: *Memory) ?[*]u8 {
        const backend: *Self = @alignCast(@fieldParentPtr("memory", self));
        backend.poison();
        return null;
    }

    fn free(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *Memory = @ptrCast(@alignCast(raw));
        self.used -= charge(bytes.len);
        std.heap.page_allocator.rawFree(bytes, alignment, address);
    }
};

const test_cluster = blk: {
    var bytes: [63]u8 = undefined;
    bytes[0] = 'e';
    for (0..31) |i| @memcpy(bytes[1 + i * 2 ..][0..2], "\u{301}");
    break :blk bytes;
};

const test_size: vaxis.Winsize = .{ .cols = 80, .rows = 24, .x_pixel = 0, .y_pixel = 0 };

fn testPaint(self: *Self) void {
    _ = self.window().printSegment(.{ .text = "same", .style = .{ .bold = true, .reverse = true } }, .{ .wrap = .none });
    self.window().showCursor(4, 23);
}

fn testPoison(self: *Self) !void {
    try std.testing.expectEqual(Phase.poisoned, self.phase);
    self.end();
    try std.testing.expectEqual(Phase.poisoned, self.phase);
    try std.testing.expectError(error.RenderBackendPoisoned, self.begin(test_size));
    self.deinit();
    self.deinit();
    try std.testing.expectEqual(@as(usize, 0), self.usage().used);
    try std.testing.expectEqual(Phase.poisoned, self.phase);
}

test "RenderBackend freezes prefix first, neutralizes prefix-only, and preserves empty unchanged frame" {
    var env = try std.testing.environ.createMap(std.testing.allocator);
    defer env.deinit();
    var self: Self = .{};
    try self.init(std.testing.io, &env, .{ .depth = .none });
    defer self.deinit();
    for (0..3) |pass| {
        try self.begin(test_size);
        if (pass != 1) try self.prefixWriter().writeAll("PREFIX");
        testPaint(&self);
        const bytes = try self.encode();
        if (pass == 1) {
            try std.testing.expectEqual(@as(usize, 0), bytes.len);
        } else {
            try std.testing.expect(std.mem.startsWith(u8, bytes, "PREFIX"));
            try std.testing.expect(std.mem.endsWith(u8, bytes, postlude));
            if (pass == 2) try std.testing.expectEqualStrings("PREFIX" ++ postlude, bytes);
        }
        self.end();
    }
}

fn testGenerated(self: *Self) !void {
    // Returning helpers must not leave cells borrowing their stack arrays.
    const text = try std.fmt.allocPrint(self.scratch(), "generated-{d}", .{42});
    const uri = try std.fmt.allocPrint(self.scratch(), "https://example.com/{d}", .{42});
    _ = self.window().printSegment(.{ .text = text, .link = .{ .uri = uri } }, .{ .wrap = .none });
    self.window().showCursor(12, 23);
}

test "RenderBackend keeps generated helper text through encode and scrubs only borrowed payloads" {
    var env = try std.testing.environ.createMap(std.testing.allocator);
    defer env.deinit();
    var self: Self = .{};
    try self.init(std.testing.io, &env, .{});
    defer self.deinit();
    try self.begin(test_size);
    try testGenerated(&self);
    const bytes = try self.encode();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "generated-42") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "https://example.com/42") != null);
    const s = &self.storage.?;
    try std.testing.expectEqualStrings("g", s.vx.screen_last.buf[0].char.items);
    try std.testing.expectEqualStrings("https://example.com/42", s.vx.screen_last.buf[0].uri.items);
    for (s.vx.screen.buf) |cell| {
        try std.testing.expectEqual(@as(usize, 0), cell.char.grapheme.len);
        try std.testing.expectEqual(@as(usize, 0), cell.link.uri.len);
    }
    try std.testing.expect(s.vx.screen.cursor_vis);
    try std.testing.expectEqual(@as(u16, 12), s.vx.screen.cursor.col);
    // Destroy all generated strings before the frozen output is consumed.
    s.scratch.deinit();
    s.scratch = .init(self.memory.allocator());
    try std.testing.expect(std.mem.indexOf(u8, bytes, "generated-42") != null);
    self.end();
    try self.begin(test_size);
    try testGenerated(&self);
    try std.testing.expectEqual(@as(usize, 0), (try self.encode()).len);
    self.end();
}

test "RenderBackend failed init and repeated disposal cannot restart a poisoned invocation" {
    var env = try std.testing.environ.createMap(std.testing.allocator);
    defer env.deinit();
    var self: Self = .{};
    self.memory.fault.after = 0;
    try std.testing.expectError(error.OutOfMemory, self.init(std.testing.io, &env, .{}));
    try testPoison(&self);
    try std.testing.expectError(error.RenderBackendPoisoned, self.init(std.testing.io, &env, .{}));
}

test "RenderBackend rejects geometry before charging cells and keeps poison through end" {
    var env = try std.testing.environ.createMap(std.testing.allocator);
    defer env.deinit();
    for ([_]vaxis.Winsize{
        .{ .cols = 7, .rows = 24, .x_pixel = 0, .y_pixel = 0 },
        .{ .cols = 80, .rows = 1, .x_pixel = 0, .y_pixel = 0 },
        .{ .cols = 480, .rows = 135, .x_pixel = 0, .y_pixel = 0 },
    }, 0..) |size, i| {
        var self: Self = .{};
        try self.init(std.testing.io, &env, .{});
        const used = self.usage().used;
        if (i < 2) try std.testing.expectError(error.TerminalTooSmall, self.begin(size)) else try std.testing.expectError(error.TerminalTooLarge, self.begin(size));
        try std.testing.expectEqual(used, self.usage().used);
        try testPoison(&self);
    }
}

test "RenderBackend every begin allocation failure including destructive resize is disposable" {
    var env = try std.testing.environ.createMap(std.testing.allocator);
    defer env.deinit();
    var reference: Self = .{};
    try reference.init(std.testing.io, &env, .{});
    reference.memory.fault = .{};
    try reference.begin(test_size);
    const allocations = reference.memory.fault.attempts;
    // An unencoded frame cannot be silently abandoned and reused.
    reference.end();
    try std.testing.expectEqual(Phase.poisoned, reference.phase);
    reference.deinit();
    var destructive = false;
    var installed = false;
    for (0..allocations) |index| {
        var self: Self = .{};
        try self.init(std.testing.io, &env, .{});
        // Start with an actually encoded smaller grid; replacement must not
        // retain both geometries, nor lose half-initialized grid ownership.
        try self.begin(.{ .cols = 8, .rows = 2, .x_pixel = 0, .y_pixel = 0 });
        _ = try self.encode();
        self.end();
        self.memory.fault = .{ .after = index };
        try std.testing.expectError(error.OutOfMemory, self.begin(test_size));
        destructive = destructive or self.geometry().cols == 0;
        installed = installed or self.geometry().cols == test_size.cols;
        try testPoison(&self);
    }
    try std.testing.expect(destructive);
    try std.testing.expect(installed); // resize writer failure after grid install
}

test "RenderBackend scratch and prefix allocation failures poison without a caller errdefer" {
    var env = try std.testing.environ.createMap(std.testing.allocator);
    defer env.deinit();
    for (0..2) |which| {
        var self: Self = .{};
        try self.init(std.testing.io, &env, .{});
        try self.begin(test_size);
        self.memory.fault = .{ .after = 0 };
        if (which == 0) {
            try std.testing.expectError(error.OutOfMemory, self.scratch().alloc(u8, 32));
        } else {
            // Writer's standard error vocabulary is WriteFailed; only this
            // known memory writer's caller may translate it to OutOfMemory.
            try std.testing.expectError(error.WriteFailed, self.prefixWriter().writeAll("prefix"));
        }
        try testPoison(&self);
    }
}

test "RenderBackend enforces empty link params and explicit indexed styles at one boundary" {
    var env = try std.testing.environ.createMap(std.testing.allocator);
    defer env.deinit();
    for (0..3) |which| {
        var self: Self = .{};
        try self.init(std.testing.io, &env, .{ .depth = if (which == 2) .none else .indexed });
        try self.begin(test_size);
        if (which == 0) {
            self.window().writeCell(0, 0, .{ .link = .{ .uri = "https://example.com", .params = "id=unbudgeted" } });
            try std.testing.expectError(error.UnsupportedLinkParams, self.encode());
        } else {
            const color: vaxis.Cell.Color = if (which == 2) .{ .index = 7 } else .{ .rgb = .{ 1, 2, 3 } };
            self.window().writeCell(0, 0, .{ .style = .{ .fg = color } });
            try std.testing.expectError(error.InvalidRenderStyle, self.encode());
        }
        try testPoison(&self);
    }
}

test "RenderBackend policy owns width and color authority while domains own day night palettes" {
    var env = try std.testing.environ.createMap(std.testing.allocator);
    defer env.deinit();
    var self: Self = .{};
    try self.init(std.testing.io, &env, .{ .depth = .none });
    defer self.deinit();
    for (0..3) |pass| {
        const depth: @FieldType(Policy, "depth") = switch (pass) {
            0 => .none,
            1 => .indexed,
            else => .direct,
        };
        _ = self.setPolicy(.{ .width = .unicode, .depth = depth });
        try self.begin(test_size);
        const style: vaxis.Style = switch (depth) {
            .none => .{ .bold = true, .reverse = true, .italic = true, .ul_style = .single },
            .indexed => .{ .fg = .{ .index = 123 }, .bg = .{ .index = 234 } },
            .direct => .{ .fg = .{ .rgb = .{ 12, 34, 56 } }, .bg = .{ .rgb = .{ 78, 90, 123 } } },
        };
        self.window().writeCell(0, 0, .{ .char = .{ .grapheme = "X", .width = 1 }, .style = style });
        try std.testing.expectEqual(vaxis.gwidth.Method.unicode, self.storage.?.vx.screen.width_method);
        try std.testing.expectEqual(vaxis.gwidth.Method.unicode, self.storage.?.vx.caps.unicode);
        const bytes = try self.encode();
        try std.testing.expect(std.mem.endsWith(u8, bytes, postlude));
        switch (depth) {
            .none => {
                try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[38") == null);
                try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[48") == null);
                try std.testing.expect(self.storage.?.vx.screen_last.buf[0].style.bold);
                try std.testing.expect(self.storage.?.vx.screen_last.buf[0].style.reverse);
                try std.testing.expect(self.storage.?.vx.screen_last.buf[0].style.italic);
                try std.testing.expectEqual(vaxis.Style.Underline.single, self.storage.?.vx.screen_last.buf[0].style.ul_style);
            },
            .indexed => {
                try std.testing.expect(std.mem.indexOf(u8, bytes, "38:5:123") != null);
                try std.testing.expect(std.mem.indexOf(u8, bytes, "48:5:234") != null);
                try std.testing.expect(std.mem.indexOf(u8, bytes, "38:2:") == null);
            },
            .direct => try std.testing.expect(std.mem.indexOf(u8, bytes, "38:2:12:34:56") != null),
        }
        self.end();
    }
}

test "RenderBackend output errors keep their real identity and poison before releasing frozen storage" {
    var env = try std.testing.environ.createMap(std.testing.allocator);
    defer env.deinit();
    var self: Self = .{};
    try self.init(std.testing.io, &env, .{});
    try self.begin(test_size);
    testPaint(&self);
    const bytes = try self.encode();
    const Output = struct {
        fn send(backend: *Self, _: []const u8) !void {
            errdefer backend.poison();
            return error.TerminalOutputFailed;
        }
    };
    // This is the caller's boundary, not a generic backend delivery method.
    try std.testing.expectError(error.TerminalOutputFailed, Output.send(&self, bytes));
    try testPoison(&self);
}

test "RenderBackend retained copy failure is not confused with frame writer failure" {
    var env = try std.testing.environ.createMap(std.testing.allocator);
    defer env.deinit();
    var self: Self = .{};
    try self.init(std.testing.io, &env, .{});
    defer self.deinit();
    try self.begin(test_size);
    const cluster: []const u8 = &test_cluster;
    const win = self.window();
    for (0..test_size.rows) |row| for (0..test_size.cols) |col| {
        win.writeCell(@intCast(col), @intCast(row), .{ .char = .{ .grapheme = cluster, .width = 1 } });
    };
    // No frame allocation can fail; only the retained arena can request memory.
    try self.storage.?.frame.ensureTotalCapacityPrecise(1024 * 1024);
    self.memory.fault = .{ .after = 0 };
    try std.testing.expectError(error.OutOfMemory, self.encode());
    try std.testing.expect(self.memory.fault.attempts != 0);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), self.storage.?.frame.writer.buffer.len);
    try testPoison(&self);
}

test "RenderBackend failed postlude poisons after successful render retained copies" {
    var env = try std.testing.environ.createMap(std.testing.allocator);
    defer env.deinit();
    var self: Self = .{};
    try self.init(std.testing.io, &env, .{});
    defer self.deinit();
    try self.begin(test_size);
    testPaint(&self);
    _ = try self.encode();
    self.end();
    self.invalidate();
    try self.begin(test_size);
    testPaint(&self);
    const render_len = (try self.encode()).len - postlude.len;
    self.end();
    self.invalidate();
    try self.begin(test_size);
    testPaint(&self);
    try self.storage.?.frame.ensureTotalCapacityPrecise(render_len);
    self.memory.fault = .{ .after = 0 };
    try std.testing.expectError(error.OutOfMemory, self.encode());
    // All library bytes fit, copied cells remain correct; only the required
    // final safety postlude needed the refused allocation.
    try std.testing.expectEqual(render_len, self.storage.?.frame.written().len);
    try std.testing.expectEqualStrings("s", self.storage.?.vx.screen_last.buf[0].char.items);
    try testPoison(&self);
}

fn testKeepLinks(self: *Self, uri: []const u8) !void {
    for (0..10) |pass| {
        try self.begin(test_size);
        const win = self.window();
        const start = pass * 192;
        for (start..start + 192) |index| win.writeCell(@intCast(index % test_size.cols), @intCast(index / test_size.cols), .{
            .char = .{ .grapheme = "x", .width = 1 },
            .link = .{ .uri = uri },
        });
        _ = try self.encode();
        self.end();
        if (testKeptLinks(self) >= grid_link_bytes) return;
    }
    return error.TestUnexpectedResult;
}

fn testKeptLinks(self: *const Self) usize {
    var kept: usize = 0;
    for (self.storage.?.vx.screen_last.buf) |cell| kept += cell.uri.capacity;
    return kept;
}

test "RenderBackend link admission and retained grid recycling share one charged budget" {
    var env = try std.testing.environ.createMap(std.testing.allocator);
    defer env.deinit();
    var self: Self = .{};
    try self.init(std.testing.io, &env, .{});
    defer self.deinit();
    var uri: [600]u8 = @splat('x');
    @memcpy(uri[0..8], "https://");
    try testKeepLinks(&self, &uri);
    try std.testing.expect(testKeptLinks(&self) >= grid_link_bytes);
    try self.begin(test_size);
    const win = self.window();
    for (0..test_size.rows) |row| for (0..test_size.cols) |col| {
        win.writeCell(@intCast(col), @intCast(row), .{ .char = .{ .grapheme = "x", .width = 1 }, .link = .{ .uri = &uri } });
    };
    _ = try self.encode();
    var linked: usize = 0;
    for (self.storage.?.vx.screen_last.buf) |cell| {
        linked += cell.uri.items.len;
        try std.testing.expectEqual(@as(usize, 0), cell.uri_id.items.len);
    }
    try std.testing.expectEqual(frame_link_bytes / uri.len * uri.len, linked);
    try std.testing.expect(testKeptLinks(&self) < grid_link_bytes);
    self.end();
    try std.testing.expect(self.usage().peak <= memory_limit);
}

test "RenderBackend destructive retained link grid failure is independently disposable" {
    var env = try std.testing.environ.createMap(std.testing.allocator);
    defer env.deinit();
    var uri: [600]u8 = @splat('x');
    @memcpy(uri[0..8], "https://");
    for (0..2) |index| {
        var self: Self = .{};
        try self.init(std.testing.io, &env, .{});
        try testKeepLinks(&self, &uri);
        try std.testing.expect(testKeptLinks(&self) >= grid_link_bytes);
        try self.begin(test_size);
        self.memory.fault = .{ .after = index };
        try std.testing.expectError(error.OutOfMemory, self.encode());
        try std.testing.expectEqual(@as(u16, if (index == 0) test_size.cols else 0), self.storage.?.vx.screen_last.width);
        try testPoison(&self);
    }
}

fn testDensePaint(self: *Self, size: vaxis.Winsize, cluster: []const u8) !void {
    // Generated link payload is charged scratch, not an uncharged cell cache.
    const uri = try self.scratch().alloc(u8, 600);
    @memset(uri, 'x');
    @memcpy(uri[0..8], "https://");
    const win = self.window();
    for (0..size.rows) |row| for (0..size.cols) |col| {
        win.writeCell(@intCast(col), @intCast(row), .{
            .char = .{ .grapheme = cluster, .width = 1 },
            .style = .{ .fg = .{ .rgb = if (col % 2 == 0) .{ 12, 34, 56 } else .{ 78, 90, 123 } }, .bold = col % 2 == 0 },
            .link = .{ .uri = uri },
        });
    };
    win.showCursor(0, size.rows - 1);
}

const test_max_sizes = [_]vaxis.Winsize{
    .{ .cols = 2048, .rows = 24, .x_pixel = 0, .y_pixel = 0 },
    .{ .cols = 256, .rows = 192, .x_pixel = 0, .y_pixel = 0 },
};

test "RenderBackend dense Unicode styles maximum links prefix and scratch fit charged maximum geometry" {
    var env = try std.testing.environ.createMap(std.testing.allocator);
    defer env.deinit();
    var self: Self = .{};
    try self.init(std.testing.io, &env, .{ .width = .unicode, .depth = .direct });
    defer self.deinit();
    for (test_max_sizes) |size| {
        for (0..2) |pass| {
            try self.begin(size);
            if (pass == 0) try self.prefixWriter().writeAll("waiting report");
            try testDensePaint(&self, size, "e\u{301}");
            const bytes = try self.encode();
            if (pass == 0) {
                try std.testing.expect(bytes.len != 0);
                try std.testing.expect(std.mem.startsWith(u8, bytes, "waiting report"));
                try std.testing.expect(std.mem.endsWith(u8, bytes, postlude));
            } else try std.testing.expectEqual(@as(usize, 0), bytes.len);
            try std.testing.expectEqualStrings("e\u{301}", self.storage.?.vx.screen_last.buf[0].char.items);
            var linked: usize = 0;
            for (self.storage.?.vx.screen_last.buf) |cell| linked += cell.uri.items.len;
            try std.testing.expectEqual(frame_link_bytes / 600 * 600, linked);
            self.end();
        }
        std.debug.print("RenderBackend dense NFD/RGB/links/prefix/scratch {d}x{d}: retained={d}, charged_peak={d}\n", .{ size.cols, size.rows, self.usage().used, self.usage().peak });
        try std.testing.expect(self.usage().peak <= memory_limit);
    }
    try self.begin(test_size);
    _ = try self.encode();
    self.end();
    try std.testing.expect(self.usage().peak <= memory_limit);
}

test "RenderBackend overbudget dense large clusters fail explicitly before any output authority" {
    var env = try std.testing.environ.createMap(std.testing.allocator);
    defer env.deinit();
    for (test_max_sizes) |size| {
        var self: Self = .{};
        try self.init(std.testing.io, &env, .{ .width = .unicode, .depth = .direct });
        try self.begin(size);
        try self.prefixWriter().writeAll("waiting report");
        try testDensePaint(&self, size, &test_cluster);
        try std.testing.expectError(error.OutOfMemory, self.encode());
        std.debug.print("RenderBackend bounded refusal cluster63/RGB/links {d}x{d}: retained={d}, charged_peak={d}\n", .{ size.cols, size.rows, self.usage().used, self.usage().peak });
        try std.testing.expect(self.usage().peak <= memory_limit);
        try testPoison(&self);
    }
}
