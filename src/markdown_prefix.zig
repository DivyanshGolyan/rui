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
