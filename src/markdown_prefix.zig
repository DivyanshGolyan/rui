//! Raw logical-line syntax only: no inline parsing, terminal output or source rewriting.
//! `raw` excludes LF; `ended` means a real LF or canonical EOF, never a chunk/retention cut.
const std = @import("std");

/// Constructed values require depth 1..8 and bytes in indent+depth..indent+2*depth.
/// Recognition returns at most 19 ASCII prefix bytes; it never retains body text.
pub const Quote = struct {
    bytes: u8,
    depth: u4,
    indent: u2,

    fn assertValid(self: Quote) void {
        std.debug.assert(self.depth >= 1 and self.depth <= 8);
        const minimum = @as(usize, self.indent) + self.depth;
        std.debug.assert(self.bytes >= minimum and self.bytes <= minimum + self.depth);
    }

    pub const Continuation = struct { cells: u8, depth: u4, indent: u2 };

    /// Geometry for future soft rows only. First rows retain the exact source prefix.
    /// Null means use literal wrapping for the whole logical line, losing no source.
    pub fn continuation(self: Quote, width: usize) ?Continuation {
        self.assertValid();
        if (width < @as(usize, self.bytes) + 2) return null;
        return .{ .cells = self.bytes, .depth = self.depth, .indent = self.indent };
    }

    pub const Outer = union(enum) { need_more, literal, body: u8 };

    /// Consume only this container's depth, not a deeper `>` in quoted code.
    /// Initial indentation must match exactly; marker spacing may vary. A quoted
    /// blank may end before the opener's body column. No slice is retained.
    pub fn outer(self: Quote, raw: []const u8, ended: bool) Outer {
        self.assertValid();
        var at: usize = 0;
        while (at < self.indent) : (at += 1) {
            if (at == raw.len) return if (ended) .literal else .need_more;
            if (raw[at] != ' ') return .literal;
        }
        for (0..self.depth) |marker| {
            if (at == raw.len) return if (ended) .literal else .need_more;
            if (raw[at] != '>') return .literal;
            at += 1;
            if (at == raw.len) {
                if (!ended) return .need_more;
                return if (marker + 1 == self.depth) .{ .body = @intCast(at) } else .literal;
            }
            switch (raw[at]) {
                ' ' => at += 1,
                '>' => {},
                else => return .literal,
            }
        }
        return .{ .body = @intCast(at) };
    }
};

pub const Recognition = union(enum) { need_more, literal, quote: Quote };

/// Conservative raw prefix: up to three initial ASCII spaces and eight markers.
/// A marker requires a space, another marker, or actual EOL. One separator is
/// syntax; any additional space (or tab after that separator) is body text.
/// Never promote an incomplete prefix, even if a shorter quote would be valid.
pub fn recognize(raw: []const u8, ended: bool) Recognition {
    var at: usize = 0;
    while (at < raw.len and raw[at] == ' ') : (at += 1) {
        if (at == 3) return .literal;
    }
    const indent = at;
    if (at == raw.len) return if (ended) .literal else .need_more;
    if (raw[at] != '>') return .literal;
    var depth: u4 = 0;
    while (true) {
        depth += 1;
        if (depth > 8) return .literal;
        at += 1;
        if (at == raw.len) {
            if (!ended) return .need_more;
            break;
        }
        switch (raw[at]) {
            '>' => continue,
            ' ' => {
                at += 1;
                if (at == raw.len) {
                    if (!ended) return .need_more;
                    break;
                }
                if (raw[at] == '>') continue;
                break;
            },
            else => return .literal,
        }
    }
    return .{ .quote = .{ .bytes = @intCast(at), .depth = depth, .indent = @intCast(indent) } };
}

/// The existing assistant renderer's fence subset, not CommonMark. Callers own
/// line bounds, real endings, active/literal fence state and retained storage.
pub const Fence = struct {
    pub const Marker = enum { backtick, tilde };
    pub const Run = struct {
        marker: Marker,
        count: u8,
        end: u8,
        /// A terminator or actual ending was observed before the head cap.
        complete: bool,
    };
    pub const Lead = union(enum) { need_more, none, run: Run };

    /// Opacity-only raw facts. Partial runs expose their observed count so a
    /// closer can be disproved early, without guessing an opener's full run.
    /// `limit_cut` may refer to a containing head before its quote was peeled.
    /// Strict legacy helpers below deliberately keep their original subset.
    pub fn lead(raw: []const u8, supplied_ending: HeadEnding) Lead {
        std.debug.assert(raw.len <= head_limit);
        const ending = if (raw.len == head_limit) .limit_cut else supplied_ending;
        const start = indentation(raw);
        if (start == raw.len) return if (ending.ended()) .none else .need_more;
        const marker: Marker = switch (raw[start]) {
            '`' => .backtick,
            '~' => .tilde,
            else => return .none,
        };
        var end = start;
        while (end < raw.len and raw[end] == raw[start]) : (end += 1) {}
        return .{ .run = .{
            .marker = marker,
            .count = @intCast(end - start),
            .end = @intCast(end),
            .complete = end < raw.len or ending.ended(),
        } };
    }

    pub fn candidate(raw: []const u8) bool {
        return std.mem.startsWith(u8, raw[indentation(raw)..], "```");
    }

    pub fn opening(raw: []const u8) bool {
        const tail = raw[indentation(raw)..];
        if (!std.mem.startsWith(u8, tail, "```")) return false;
        for (tail[3..]) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '+') return false;
        }
        return true;
    }

    pub fn closing(raw: []const u8) bool {
        var closer: Closer = .{};
        for (raw) |byte| {
            closer.feed(byte);
            if (!closer.possible) return false;
        }
        return closer.matches();
    }

    fn indentation(raw: []const u8) usize {
        var at: usize = 0;
        while (at < raw.len and at < 3 and raw[at] == ' ') : (at += 1) {}
        return at;
    }

    /// Also used when a renderer's bounded fence overflows mid-line. Feeding
    /// never crosses LF; invalid syntax stays invalid until the caller resets.
    pub const Closer = struct {
        possible: bool = true,
        indent: u2 = 0,
        ticks: u2 = 0,

        pub fn feed(self: *Closer, byte: u8) void {
            if (!self.possible) return;
            if (self.ticks == 0 and self.indent < 3 and byte == ' ') {
                self.indent += 1;
            } else if (byte == '`' and self.ticks < 3) {
                self.ticks += 1;
            } else self.possible = false;
        }

        pub fn matches(self: Closer) bool {
            return self.possible and self.ticks == 3;
        }
    };
};

/// A source head, never a retained suffix. Reaching 128 bytes takes precedence
/// over a caller already knowing the following LF/EOF: every consumer applies
/// the same bounded policy without borrowing unavailable future bytes.
pub const head_limit = 128;
pub const HeadEnding = enum {
    pending,
    line_feed,
    canonical_eof,
    limit_cut,

    fn ended(self: HeadEnding) bool {
        return self == .line_feed or self == .canonical_eof;
    }
};

/// PURE UNUSED opacity eligibility. It grants no delimiter-stripping, styling,
/// copy, retained-provenance or terminal authority. Future output integration
/// must reconcile this with legacy display custody in ONE pre-inline owner;
/// enabling it beside an independently deciding renderer is not sufficient.
///
/// A draft traversal starts plain and discards this value at canonical end.
/// A future streaming caller reprobes its existing raw head until resolved,
/// commits next ONCE per hard line, then uses that projection to real LF/EOF.
/// need_more never commits. No source/chunk/retention edge resets context.
pub const Context = union(enum) {
    plain,
    fence: struct {
        outer: ?Quote,
        marker: Fence.Marker,
        /// Null means an opener run reached the head cap without a terminator:
        /// retain opacity through canonical EOF, never guess a shorter closer.
        run: ?u8,
    },

    pub const Mode = enum { prose, @"opaque" };
    pub const Projection = struct { quote: ?Quote, body_at: u8, mode: Mode };
    pub const Decision = struct { next: Context, projection: Projection };
    pub const Probe = union(enum) { need_more, resolved: Decision };

    pub fn step(self: Context, raw: []const u8, supplied_ending: HeadEnding) Probe {
        std.debug.assert(raw.len <= head_limit);
        std.debug.assert(std.mem.indexOfScalar(u8, raw, '\n') == null);
        std.debug.assert(supplied_ending != .limit_cut or raw.len == head_limit);
        const ending = if (raw.len == head_limit) .limit_cut else supplied_ending;
        var quote: ?Quote = null;
        var at: u8 = 0;
        switch (self) {
            .plain => switch (recognize(raw, ending.ended())) {
                .need_more => return .need_more,
                .literal => {},
                .quote => |value| {
                    quote = value;
                    at = value.bytes;
                },
            },
            .fence => |active| {
                if (active.run) |run| std.debug.assert(run >= 3 and run < head_limit);
                if (active.outer) |outer| switch (outer.outer(raw, ending.ended())) {
                    .need_more => return .need_more,
                    // A missing container is not proof the code ended. Never
                    // greedily reinterpret this line as a new/deeper quote.
                    .literal => return resolved(self, null, 0, .@"opaque"),
                    .body => |bytes| {
                        at = bytes;
                        quote = .{ .bytes = bytes, .depth = outer.depth, .indent = outer.indent };
                    },
                };
                const expected = active.run orelse return resolved(self, quote, at, .@"opaque");
                const body = raw[at..];
                const facts = switch (Fence.lead(body, ending)) {
                    .need_more => return .need_more,
                    .none => return resolved(self, quote, at, .@"opaque"),
                    .run => |value| value,
                };
                // Partial facts can disprove a close without waiting for EOL.
                if (facts.marker != active.marker or facts.count > expected or
                    (facts.complete and facts.count < expected)) return resolved(self, quote, at, .@"opaque");
                if (!facts.complete) return if (ending == .limit_cut) resolved(self, quote, at, .@"opaque") else .need_more;
                var tail = body[facts.end..];
                // CTX-V1-CRLF: only proved LF authorizes this syntax-only strip.
                // Legacy Fence.closing and LastCode deliberately remain strict.
                if (ending == .line_feed and tail.len > 0 and tail[tail.len - 1] == '\r') tail = tail[0 .. tail.len - 1];
                for (tail, 0..) |byte, index| {
                    if (byte == ' ' or byte == '\t') continue;
                    if (byte == '\r' and index + 1 == tail.len and ending == .pending) return .need_more;
                    return resolved(self, quote, at, .@"opaque");
                }
                if (ending == .pending) return .need_more;
                if (ending == .limit_cut) return resolved(self, quote, at, .@"opaque");
                return resolved(.plain, quote, at, .@"opaque");
            },
        }
        const facts = switch (Fence.lead(raw[at..], ending)) {
            .need_more => return .need_more,
            .none => return resolved(.plain, quote, at, .prose),
            .run => |value| value,
        };
        if (facts.complete and facts.count < 3) return resolved(.plain, quote, at, .prose);
        if (!facts.complete and ending != .limit_cut) return .need_more;
        // Run identity is irrevocable once its terminator is observed. Info
        // syntax affects legacy presentation, not opacity, so open early.
        return resolved(.{ .fence = .{
            .outer = quote,
            .marker = facts.marker,
            .run = if (facts.complete) facts.count else null,
        } }, quote, at, .@"opaque");
    }

    fn resolved(next: Context, quote: ?Quote, at: u8, mode: Mode) Probe {
        return .{ .resolved = .{ .next = next, .projection = .{ .quote = quote, .body_at = at, .mode = mode } } };
    }
};

test "markdown prefix bounded grammar and exact source ranges" {
    const cases = [_]struct { raw: []const u8, bytes: u8, depth: u4, indent: u2 = 0 }{
        .{ .raw = "> text", .bytes = 2, .depth = 1 },
        .{ .raw = ">> text", .bytes = 3, .depth = 2 },
        .{ .raw = "> > text", .bytes = 4, .depth = 2 },
        .{ .raw = ">", .bytes = 1, .depth = 1 },
        .{ .raw = "> >", .bytes = 3, .depth = 2 },
        .{ .raw = "   > ", .bytes = 5, .depth = 1, .indent = 3 },
        .{ .raw = "   > > > > > > > > body", .bytes = 19, .depth = 8, .indent = 3 },
        .{ .raw = ">  > body", .bytes = 2, .depth = 1 },
        .{ .raw = "> \ttext", .bytes = 2, .depth = 1 },
        .{ .raw = "> 👩‍🚀 é\x1b[31m", .bytes = 2, .depth = 1 },
    };
    for (cases) |case| {
        const quote = recognize(case.raw, true).quote;
        try std.testing.expectEqual(Quote{ .bytes = case.bytes, .depth = case.depth, .indent = case.indent }, quote);
        // A source offset, never a transformed payload: even controls stay raw.
        var reconstructed: [128]u8 = undefined;
        @memcpy(reconstructed[0..quote.bytes], case.raw[0..quote.bytes]);
        @memcpy(reconstructed[quote.bytes..case.raw.len], case.raw[quote.bytes..]);
        try std.testing.expectEqualStrings(case.raw, reconstructed[0..case.raw.len]);
    }
    for ([_][]const u8{ "", "   ", "plain", ">text", ">>text", "> >text", "\\> text", "\t> text", "    > text", ">\ttext", "> >\ttext", ">>>>>>>>> text", "> > > > > > > > > text", "```> text" }) |raw| {
        try std.testing.expectEqual(.literal, std.meta.activeTag(recognize(raw, true)));
    }
}

test "markdown prefix waits for actual syntax bytes or canonical ending at every split" {
    for ([_][]const u8{ "> text", ">> text", "   > > body", "> > > > > > > > body" }) |raw| {
        const final = recognize(raw, true);
        const prefix = final.quote.bytes;
        for (0..raw.len + 1) |split| {
            const got = recognize(raw[0..split], false);
            if (split <= prefix) {
                try std.testing.expectEqual(.need_more, std.meta.activeTag(got));
            } else try std.testing.expectEqual(final, got);
        }
    }
    for ([_][]const u8{ ">", "> ", "> >", "> > ", "   >>>>>>>> " }) |raw| {
        for (0..raw.len + 1) |split| {
            try std.testing.expectEqual(.need_more, std.meta.activeTag(recognize(raw[0..split], false)));
        }
        try std.testing.expectEqual(.quote, std.meta.activeTag(recognize(raw, true)));
    }
    try std.testing.expectEqual(.quote, std.meta.activeTag(recognize(">  ", false)));
    for ([_][]const u8{ ">text", "> >text", "> > > > > > > > > body", "   >>>>>>>>>" }) |raw| {
        // Invalid future syntax must never turn an earlier prefix into a quote.
        for (0..raw.len + 1) |split| {
            try std.testing.expect(std.meta.activeTag(recognize(raw[0..split], false)) != .quote);
        }
        try std.testing.expectEqual(.literal, std.meta.activeTag(recognize(raw, true)));
    }
}

test "markdown prefix continuation reserves two body cells without source decoration" {
    for (0..4) |indent| {
        for (1..9) |depth| {
            for ([_]bool{ false, true }) |spaced| {
                const quote: Quote = .{ .bytes = @intCast(indent + depth * (if (spaced) @as(usize, 2) else 1)), .depth = @intCast(depth), .indent = @intCast(indent) };
                for (0..25) |width| {
                    if (quote.continuation(width)) |geometry| {
                        try std.testing.expect(width - geometry.cells >= 2);
                        try std.testing.expectEqual(quote.bytes, geometry.cells);
                        try std.testing.expectEqual(quote.depth, geometry.depth);
                        try std.testing.expectEqual(quote.indent, geometry.indent);
                    } else try std.testing.expect(width < @as(usize, quote.bytes) + 2);
                }
                try std.testing.expect(quote.continuation(std.math.maxInt(usize)) != null);
            }
        }
    }
}

test "markdown prefix outer container consumes only recorded depth and exact indentation" {
    const quote = recognize(" > > opener", true).quote;
    const cases = [_]struct { raw: []const u8, bytes: u8, body: []const u8 }{
        .{ .raw = " >> code", .bytes = 4, .body = "code" },
        .{ .raw = " > >", .bytes = 4, .body = "" },
        .{ .raw = " >>", .bytes = 3, .body = "" },
        .{ .raw = " >>>>>code", .bytes = 3, .body = ">>>code" },
        .{ .raw = " > > >>>>>>>>> code", .bytes = 5, .body = ">>>>>>>>> code" },
        .{ .raw = " > >  indented", .bytes = 5, .body = " indented" },
    };
    for (cases) |case| {
        const at = quote.outer(case.raw, true).body;
        try std.testing.expectEqual(case.bytes, at);
        try std.testing.expectEqualStrings(case.body, case.raw[at..]);
    }
    for ([_][]const u8{ "> > code", "  > > code", " > code", " >\t> code", " > >text" }) |raw| {
        try std.testing.expectEqual(.literal, std.meta.activeTag(quote.outer(raw, true)));
    }
    const single = recognize("> text", true).quote;
    try std.testing.expectEqual(@as(u8, 1), single.outer(">", true).body);
    try std.testing.expectEqual(@as(u8, 1), single.outer(">> code", true).body);
    try std.testing.expectEqual(@as(u8, 2), single.outer("> >>>>>>>>> code", true).body);
}

test "markdown prefix outer context handles chunks without promoting quoted code" {
    const quote = recognize("  > > opener", true).quote;
    const raw = "  >> ```zig";
    for (0..raw.len + 1) |split| {
        const result = quote.outer(raw[0..split], false);
        if (split < 5) {
            try std.testing.expectEqual(.need_more, std.meta.activeTag(result));
        } else try std.testing.expectEqual(@as(u8, 5), result.body);
    }
    for ([_][]const u8{ "  >", "  > " }) |short| {
        try std.testing.expectEqual(.literal, std.meta.activeTag(quote.outer(short, true)));
        try std.testing.expectEqual(.need_more, std.meta.activeTag(quote.outer(short, false)));
    }
    const body = raw[quote.outer(raw, true).body..];
    try std.testing.expect(Fence.opening(body));
    const deeper = "  >> > ```zig";
    const code = deeper[quote.outer(deeper, true).body..];
    try std.testing.expectEqualStrings("> ```zig", code);
    try std.testing.expect(!Fence.candidate(code));
    // No quoted-fence interpretation or delimiter stripping is enabled here.
    try std.testing.expect(!Fence.candidate(deeper));
    const closer = "  >> ```";
    try std.testing.expect(Fence.closing(closer[quote.outer(closer, true).body..]));
    const unsupported = "  >> ```bad info";
    const unsupported_body = unsupported[quote.outer(unsupported, true).body..];
    try std.testing.expect(Fence.candidate(unsupported_body));
    try std.testing.expect(!Fence.opening(unsupported_body));
    // Unsupported fence-looking contexts need a caller's literal policy. This
    // lexical result alone confers no promotion, stripping or copy authority.
}

test "markdown fence lexical grammar matches the old complete formula and every streaming split" {
    // Independent pre-extraction formula: strip at most three leading spaces,
    // then compare the complete remaining bytes, not the streaming state.
    const alphabet = " `x\t\r";
    var raw: [7]u8 = undefined;
    var variants: usize = 1;
    for (0..raw.len + 1) |len| {
        for (0..variants) |variant| {
            var value = variant;
            for (raw[0..len]) |*byte| {
                byte.* = alphabet[value % alphabet.len];
                value /= alphabet.len;
            }
            var indent: usize = 0;
            while (indent < len and indent < 3 and raw[indent] == ' ') : (indent += 1) {}
            const expected = std.mem.eql(u8, raw[indent..len], "```");
            try std.testing.expectEqual(expected, Fence.closing(raw[0..len]));
            for (0..len + 1) |split| {
                var closer: Fence.Closer = .{};
                for (raw[0..split]) |byte| closer.feed(byte);
                for (raw[split..len]) |byte| closer.feed(byte);
                try std.testing.expectEqual(expected, closer.matches());
            }
        }
        variants *= alphabet.len;
    }
}

test "markdown fence opener and candidate preserve the existing unsupported syntax" {
    for ([_][]const u8{ "```", " ```zig", "  ```sh", "   ```C_2-c++" }) |raw| {
        try std.testing.expect(Fence.candidate(raw));
        try std.testing.expect(Fence.opening(raw));
    }
    for ([_][]const u8{ "``", "    ```", "\t```", "> ```sh", "\\```" }) |raw| {
        try std.testing.expect(!Fence.candidate(raw));
        try std.testing.expect(!Fence.opening(raw));
    }
    for ([_][]const u8{ "````", "```sh ", "```bad info", "```sh\r", "```\t", "```é" }) |raw| {
        try std.testing.expect(Fence.candidate(raw));
        try std.testing.expect(!Fence.opening(raw));
    }
    try std.testing.expect(!Fence.closing("```\r"));
    try std.testing.expect(!Fence.closing("``` "));
}

test "markdown fence opener retains every byte classification of the old info formula" {
    var raw: [8]u8 = undefined;
    for (0..5) |indent| {
        @memset(raw[0..indent], ' ');
        @memcpy(raw[indent..][0..3], "```");
        for (0..256) |value| {
            const byte: u8 = @intCast(value);
            raw[indent + 3] = byte;
            const old_info = (byte >= 'a' and byte <= 'z') or
                (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or
                byte == '_' or byte == '-' or byte == '+';
            try std.testing.expectEqual(indent <= 3, Fence.candidate(raw[0 .. indent + 4]));
            try std.testing.expectEqual(indent <= 3 and old_info, Fence.opening(raw[0 .. indent + 4]));
        }
    }
}

fn opacityResolved(context: Context, raw: []const u8, ending: HeadEnding) !Context.Decision {
    const result = context.step(raw, ending);
    try std.testing.expectEqual(.resolved, std.meta.activeTag(result));
    return result.resolved;
}

fn opacityFragments(context: Context, raw: []const u8, ending: HeadEnding, first: usize) !Context.Decision {
    const limit = @min(raw.len, head_limit);
    var at = @min(first, limit);
    while (true) : (at += 1) {
        const status: HeadEnding = if (at == head_limit) .limit_cut else if (at == raw.len) ending else .pending;
        switch (context.step(raw[0..at], status)) {
            .resolved => |decision| return decision,
            .need_more => try std.testing.expect(at < limit),
        }
    }
}

test "markdown opacity resolves ordinary and known opener prefixes early without stripping authority" {
    for ([_][]const u8{ "a", "~x", "`x", "\\```", "    > literal", ">text" }) |raw| {
        const result = try opacityResolved(.plain, raw, .pending);
        try std.testing.expectEqual(Context.Mode.prose, result.projection.mode);
        try std.testing.expectEqual(@as(?Quote, null), result.projection.quote);
        try std.testing.expectEqual(.plain, std.meta.activeTag(result.next));
    }
    for ([_][]const u8{ "", "   ", ">", "> ", "`", "``", "```", "~~~" }) |raw| {
        try std.testing.expectEqual(.need_more, std.meta.activeTag(Context.step(.plain, raw, .pending)));
    }
    const quoted = try opacityResolved(.plain, "> > prose", .pending);
    try std.testing.expectEqual(@as(u4, 2), quoted.projection.quote.?.depth);
    try std.testing.expectEqual(@as(u8, 4), quoted.projection.body_at);
    for ([_][]const u8{ "```x", "```` ", "~~~bad info", "```\r" }, [_]u8{ 3, 4, 3, 3 }) |raw, run| {
        const result = try opacityResolved(.plain, raw, .pending);
        try std.testing.expectEqual(Context.Mode.@"opaque", result.projection.mode);
        try std.testing.expectEqual(@as(?u8, run), result.next.fence.run);
    }
    try std.testing.expectEqual(Fence.Marker.tilde, (try opacityResolved(.plain, "~~~ ", .pending)).next.fence.marker);
    // These existing display policies have not been widened by opacity facts.
    try std.testing.expect(!Fence.opening("~~~"));
    try std.testing.expect(!Fence.opening("````"));
    try std.testing.expect(!Fence.opening("```bad info"));
    try std.testing.expect(!Fence.opening("```\r"));
}

test "markdown opacity records exact run identity and never promotes top level code quotes" {
    var state = (try opacityResolved(.plain, "````lang", .line_feed)).next;
    for ([_][]const u8{ "> still code", "```", "~~~", "`````", "````bad" }) |raw| {
        const result = try opacityResolved(state, raw, .line_feed);
        try std.testing.expectEqual(Context.Mode.@"opaque", result.projection.mode);
        try std.testing.expect(result.projection.quote == null);
        try std.testing.expectEqual(state, result.next);
    }
    try std.testing.expectEqual(.need_more, std.meta.activeTag(state.step("```", .pending)));
    state = (try opacityResolved(state, "````", .line_feed)).next;
    try std.testing.expectEqual(.plain, std.meta.activeTag(state));
    try std.testing.expectEqual(Context.Mode.prose, (try opacityResolved(state, "> real quote", .line_feed)).projection.mode);
}

test "markdown opacity quoted fences consume only exact recorded outer depth" {
    var state = (try opacityResolved(.plain, " > ```lang", .line_feed)).next;
    const body = try opacityResolved(state, " > >>>>>>>>> code", .line_feed);
    try std.testing.expectEqual(Context.Mode.@"opaque", body.projection.mode);
    try std.testing.expectEqual(Quote{ .bytes = 3, .depth = 1, .indent = 1 }, body.projection.quote.?);
    try std.testing.expectEqualStrings(">>>>>>>>> code", " > >>>>>>>>> code"[body.projection.body_at..]);
    const tight = try opacityResolved(state, " >> code", .line_feed);
    try std.testing.expectEqual(Quote{ .bytes = 2, .depth = 1, .indent = 1 }, tight.projection.quote.?);
    const blank = try opacityResolved(state, " >", .line_feed);
    try std.testing.expectEqual(@as(u8, 2), blank.projection.body_at);
    for ([_][]const u8{ "> code", "  > code", "plain", " >text" }) |raw| {
        const mismatch = try opacityResolved(state, raw, .line_feed);
        try std.testing.expect(mismatch.projection.quote == null);
        try std.testing.expectEqual(state, mismatch.next);
    }
    state = (try opacityResolved(state, " > ```", .line_feed)).next;
    try std.testing.expectEqual(.plain, std.meta.activeTag(state));
    const nested = (try opacityResolved(.plain, "> > ~~~", .line_feed)).next;
    const missing = try opacityResolved(nested, "> code", .line_feed);
    try std.testing.expect(missing.projection.quote == null);
    try std.testing.expectEqual(nested, missing.next);
    const code = try opacityResolved(nested, "> >>> code", .line_feed);
    try std.testing.expectEqual(Quote{ .bytes = 3, .depth = 2, .indent = 0 }, code.projection.quote.?);
    try std.testing.expectEqualStrings(">> code", "> >>> code"[code.projection.body_at..]);
}

test "markdown opacity CTX V1 CRLF close is distinct from strict display grammar" {
    const state = (try opacityResolved(.plain, "```bad info\r", .line_feed)).next;
    for ([_][]const u8{ "```", "   ```", "``` \t", "```\r", "``` \t\r" }) |raw| {
        const close = try opacityResolved(state, raw, .line_feed);
        try std.testing.expectEqual(.plain, std.meta.activeTag(close.next));
        try std.testing.expectEqual(Context.Mode.@"opaque", close.projection.mode);
    }
    try std.testing.expectEqual(.plain, std.meta.activeTag((try opacityResolved(state, "``` \t", .canonical_eof)).next));
    for ([_][]const u8{ "```\r", "``` \t" }) |raw| {
        try std.testing.expectEqual(.need_more, std.meta.activeTag(state.step(raw, .pending)));
    }
    for ([_][]const u8{ "```\r", "```\r\r", "```\r ", "``` ", "```\x00" }) |raw| {
        try std.testing.expectEqual(state, (try opacityResolved(state, raw, .canonical_eof)).next);
    }
    for ([_][]const u8{ "```\r\r", "```\rX", "``` \tX", "``` " }) |raw| {
        try std.testing.expectEqual(state, (try opacityResolved(state, raw, .pending)).next);
    }
    try std.testing.expectEqual(state, (try opacityResolved(state, "```\r\r", .line_feed)).next);
    try std.testing.expect(!Fence.closing("```\r"));
    try std.testing.expect(!Fence.closing("``` \t"));
    const tilde = (try opacityResolved(.plain, "~~~~bad", .line_feed)).next;
    try std.testing.expectEqual(.plain, std.meta.activeTag((try opacityResolved(tilde, "~~~~\t\r", .line_feed)).next));
}

test "markdown opacity deterministic head cap keeps unknown runs opaque through actual EOF" {
    var raw: [head_limit]u8 = @splat('`');
    try std.testing.expectEqual(.need_more, std.meta.activeTag(Context.step(.plain, raw[0 .. head_limit - 1], .pending)));
    const known = try opacityResolved(.plain, raw[0 .. head_limit - 1], .line_feed);
    try std.testing.expectEqual(@as(?u8, 127), known.next.fence.run);
    for ([_]HeadEnding{ .pending, .line_feed, .canonical_eof, .limit_cut }) |ending| {
        const unknown = try opacityResolved(.plain, &raw, ending);
        try std.testing.expect(unknown.next.fence.run == null);
        try std.testing.expectEqual(unknown.next, (try opacityResolved(unknown.next, "```", .line_feed)).next);
        try std.testing.expectEqual(unknown.next, (try opacityResolved(unknown.next, "> code", .canonical_eof)).next);
    }
    raw[head_limit - 1] = 'x';
    try std.testing.expectEqual(@as(?u8, 127), (try opacityResolved(.plain, &raw, .limit_cut)).next.fence.run);
    @memcpy(raw[0..2], "> ");
    @memset(raw[2..], '`');
    const quoted = try opacityResolved(.plain, &raw, .line_feed);
    try std.testing.expectEqual(@as(u4, 1), quoted.next.fence.outer.?.depth);
    try std.testing.expect(quoted.next.fence.run == null);
    const state = (try opacityResolved(.plain, "```", .line_feed)).next;
    @memcpy(raw[0..3], "```");
    @memset(raw[3..], ' ');
    try std.testing.expectEqual(state, (try opacityResolved(state, &raw, .line_feed)).next);
    try std.testing.expectEqual(.plain, std.meta.activeTag((try opacityResolved(state, "```", .line_feed)).next));
}

test "markdown opacity every prefix split commits the same one hard line decision" {
    const plain: Context = .plain;
    const fence = (try opacityResolved(plain, "````x", .line_feed)).next;
    const quoted = (try opacityResolved(plain, "> > ~~~x", .line_feed)).next;
    const unknown: Context = .{ .fence = .{ .outer = null, .marker = .backtick, .run = null } };
    const contexts = [_]Context{ plain, fence, quoted, unknown };
    const heads = [_][]const u8{ "ordinary", "> a", "> > a", ">", "> ", "```", "````", "````x", "~~~~\r", "```` \t\r", "> > >>> code", "> > ~~~\t\r", "changed outer", "" };
    for (contexts) |state| for (heads) |raw| for ([_]HeadEnding{ .line_feed, .canonical_eof }) |ending| {
        const whole = try opacityResolved(state, raw, ending);
        for (0..raw.len + 1) |first| {
            try std.testing.expectEqual(whole, try opacityFragments(state, raw, ending, first));
        }
    };
    const cap: [head_limit]u8 = @splat('~');
    const whole = try opacityResolved(plain, &cap, .line_feed);
    for (0..head_limit + 1) |first| {
        try std.testing.expectEqual(whole, try opacityFragments(plain, &cap, .line_feed, first));
    }
}

test "markdown opacity source remains raw and state has no per line buffer" {
    const raw = "> ```bad\x1b[31m\xff\x07";
    const opened = try opacityResolved(.plain, raw, .line_feed);
    try std.testing.expectEqualStrings("```bad\x1b[31m\xff\x07", raw[opened.projection.body_at..]);
    const code = "> > \x1b]8;;https://example.test\x07";
    const projected = try opacityResolved(opened.next, code, .line_feed);
    try std.testing.expectEqual(Quote{ .bytes = 2, .depth = 1, .indent = 0 }, projected.projection.quote.?);
    try std.testing.expectEqualStrings("> \x1b]8;;https://example.test\x07", code[projected.projection.body_at..]);
    try std.testing.expect(@sizeOf(Context) <= 16);
    try std.testing.expect(@sizeOf(Context.Decision) <= 32);
    try std.testing.expect(@sizeOf(Context.Probe) <= 40);
    std.debug.print("opacity value sizes Context={d} Decision={d} Probe={d} bytes (unused; no renderer authority)\n", .{ @sizeOf(Context), @sizeOf(Context.Decision), @sizeOf(Context.Probe) });
}
