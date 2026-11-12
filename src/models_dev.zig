//! Slim a models.dev response without retaining its unread model metadata.
const std = @import("std");
const catalog = @import("model_catalog.zig");

const Error = error{ InvalidCatalog, OutOfMemory };

/// Scratch owns the returned entries and their IDs; release it after use.
/// Only unique, valid IDs are copied out of the body. No JSON value tree.
pub fn parse(scratch: std.mem.Allocator, body: []const u8) Error![]catalog.Entry {
    return parseRecords(false, scratch, body);
}

/// Generator-only metadata. Runtime catalog reads keep just `catalog.Entry`.
/// Strings, including the ID, are owned by the supplied scratch allocator.
pub const Generated = struct {
    model: catalog.Entry,
    kind: ?[]const u8 = null,
    family: ?[]const u8 = null,
    input_text: bool = false,
    output_text: bool = false,

    pub fn canChat(self: Generated) bool {
        return std.mem.eql(u8, self.kind orelse "chat", "chat") and self.input_text and self.output_text;
    }

    pub fn deinit(self: Generated, scratch: std.mem.Allocator) void {
        scratch.free(self.model.id);
        releaseMetadata(true, scratch, self);
    }
};

/// Use the same ID validation, precedence and ordering for generation, while
/// retaining the type, family and text-modality facts omitted at runtime.
pub fn parseForGeneration(scratch: std.mem.Allocator, body: []const u8) Error![]Generated {
    return parseRecords(true, scratch, body);
}

fn Record(comptime generation: bool) type {
    return if (generation) Generated else catalog.Entry;
}

fn entryOf(comptime generation: bool, record: anytype) *catalog.Entry {
    return if (generation) &record.model else record;
}

fn releaseMetadata(comptime generation: bool, scratch: std.mem.Allocator, record: anytype) void {
    if (generation) {
        if (record.kind) |kind| scratch.free(kind);
        if (record.family) |family| scratch.free(family);
    }
}

fn parseRecords(comptime generation: bool, scratch: std.mem.Allocator, body: []const u8) Error![]Record(generation) {
    var parser: Parser = .{ .scanner = .initCompleteInput(scratch, body), .scratch = scratch };
    defer parser.scanner.deinit();
    var models: std.StringHashMap(Record(generation)) = .init(scratch);
    defer models.deinit();
    errdefer {
        var keys = models.keyIterator();
        while (keys.next()) |key| scratch.free(key.*);
        var values = models.valueIterator();
        while (values.next()) |value| releaseMetadata(generation, scratch, value.*);
    }
    try parser.expect(.object_begin);
    var openai_seen = false;
    while (try parser.key()) |provider| {
        defer parser.release(provider);
        const openai = std.mem.eql(u8, text(provider), "openai");
        openai_seen = openai_seen or openai;
        try parser.expect(.object_begin);
        while (try parser.key()) |member| {
            defer parser.release(member);
            if (!std.mem.eql(u8, text(member), "models")) {
                try parser.skip();
                continue;
            }
            try parser.expect(.object_begin);
            while (try parser.key()) |id_token| {
                defer parser.release(id_token);
                const id = text(id_token);
                if (!catalog.validModelSyntax(id)) {
                    try parser.skip();
                    continue;
                }
                const previous = models.getPtr(id);
                if (previous) |kept| {
                    if (!openai or entryOf(generation, kept).openai_listed) {
                        try parser.skip();
                        continue;
                    }
                }
                var record = try parser.model(generation);
                errdefer releaseMetadata(generation, scratch, record);
                const entry = entryOf(generation, &record);
                if (previous) |kept| {
                    entry.id = entryOf(generation, kept).id;
                    entry.openai_listed = true;
                    releaseMetadata(generation, scratch, kept.*);
                    kept.* = record;
                } else {
                    const owned = try scratch.dupe(u8, id);
                    errdefer scratch.free(owned);
                    entry.id = owned;
                    entry.openai_listed = openai;
                    try models.put(owned, record);
                }
            }
        }
    }
    try parser.expect(.end_of_document);
    if (!openai_seen) return error.InvalidCatalog;
    const entries = try scratch.alloc(Record(generation), models.count());
    var values = models.valueIterator();
    for (entries) |*entry| entry.* = values.next().?.*;
    // IDs are unique: stability adds nothing. Block sort keeps a 16 KiB
    // temporary on the execution stack; pdqsort uses bounded small frames.
    std.mem.sortUnstable(Record(generation), entries, {}, struct {
        fn lessThan(_: void, a: Record(generation), b: Record(generation)) bool {
            const left = if (generation) a.model.id else a.id;
            const right = if (generation) b.model.id else b.id;
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);
    return entries;
}

fn text(token: std.json.Token) []const u8 {
    return switch (token) {
        .string, .allocated_string, .number, .allocated_number => |value| value,
        else => unreachable,
    };
}

const Parser = struct {
    scanner: std.json.Scanner,
    scratch: std.mem.Allocator,

    fn next(self: *Parser) Error!std.json.Token {
        return self.scanner.nextAlloc(self.scratch, .alloc_if_needed) catch |err| return parseError(err);
    }

    fn release(self: *Parser, token: std.json.Token) void {
        switch (token) {
            .allocated_string, .allocated_number => |bytes| self.scratch.free(bytes),
            else => {},
        }
    }

    fn expect(self: *Parser, tag: std.meta.Tag(std.json.Token)) Error!void {
        const token = try self.next();
        defer self.release(token);
        if (token != tag) return error.InvalidCatalog;
    }

    fn key(self: *Parser) Error!?std.json.Token {
        const token = try self.next();
        switch (token) {
            .string, .allocated_string => return token,
            .object_end => return null,
            else => {
                self.release(token);
                return error.InvalidCatalog;
            },
        }
    }

    fn skip(self: *Parser) Error!void {
        // skipValue requires a value, not an unexpected closing delimiter.
        const tag = self.scanner.peekNextTokenType() catch |err| return parseError(err);
        switch (tag) {
            .object_end, .array_end, .end_of_document => return error.InvalidCatalog,
            else => self.scanner.skipValue() catch |err| return parseError(err),
        }
    }

    fn model(self: *Parser, comptime generation: bool) Error!Record(generation) {
        try self.expect(.object_begin);
        const empty: catalog.Entry = .{ .id = "", .context_window = null, .efforts = .{}, .openai_listed = false };
        var record: Record(generation) = if (generation) .{ .model = empty } else empty;
        errdefer releaseMetadata(generation, self.scratch, record);
        const entry = entryOf(generation, &record);
        while (try self.key()) |member| {
            defer self.release(member);
            if (std.mem.eql(u8, text(member), "limit")) {
                entry.context_window = try self.limit();
            } else if (std.mem.eql(u8, text(member), "reasoning_options")) {
                entry.efforts = try self.reasoningOptions();
            } else if (generation) {
                if (std.mem.eql(u8, text(member), "type")) {
                    const kind = try self.ownedString();
                    if (record.kind) |old| self.scratch.free(old);
                    record.kind = kind;
                } else if (std.mem.eql(u8, text(member), "family")) {
                    const family = try self.ownedString();
                    if (record.family) |old| self.scratch.free(old);
                    record.family = family;
                } else if (std.mem.eql(u8, text(member), "modalities")) {
                    const modalities = try self.textModalities();
                    record.input_text = modalities.input;
                    record.output_text = modalities.output;
                } else try self.skip();
            } else try self.skip();
        }
        return record;
    }

    fn ownedString(self: *Parser) Error![]const u8 {
        const token = try self.next();
        defer self.release(token);
        if (token != .string and token != .allocated_string) return error.InvalidCatalog;
        return self.scratch.dupe(u8, text(token));
    }

    const TextModalities = struct { input: bool = false, output: bool = false };

    fn textModalities(self: *Parser) Error!TextModalities {
        try self.expect(.object_begin);
        var modalities: TextModalities = .{};
        while (try self.key()) |member| {
            defer self.release(member);
            if (std.mem.eql(u8, text(member), "input")) {
                modalities.input = try self.hasText();
            } else if (std.mem.eql(u8, text(member), "output")) {
                modalities.output = try self.hasText();
            } else try self.skip();
        }
        return modalities;
    }

    fn hasText(self: *Parser) Error!bool {
        try self.expect(.array_begin);
        var found = false;
        while (true) {
            const token = try self.next();
            defer self.release(token);
            switch (token) {
                .array_end => return found,
                .string, .allocated_string => found = found or std.mem.eql(u8, text(token), "text"),
                else => return error.InvalidCatalog,
            }
        }
    }

    fn limit(self: *Parser) Error!?u32 {
        const tag = self.scanner.peekNextTokenType() catch |err| return parseError(err);
        if (tag != .object_begin) {
            try self.skip();
            return null;
        }
        try self.expect(.object_begin);
        var context: ?u32 = null;
        while (try self.key()) |member| {
            defer self.release(member);
            if (!std.mem.eql(u8, text(member), "context")) {
                try self.skip();
                continue;
            }
            const value_tag = self.scanner.peekNextTokenType() catch |err| return parseError(err);
            if (value_tag != .number) {
                try self.skip();
                context = null;
                continue;
            }
            const token = try self.next();
            defer self.release(token);
            context = std.fmt.parseInt(u32, text(token), 10) catch null;
        }
        return context;
    }

    fn reasoningOptions(self: *Parser) Error!catalog.Efforts {
        try self.expect(.array_begin);
        var efforts: catalog.Efforts = .{};
        while (true) {
            const token = try self.next();
            defer self.release(token);
            switch (token) {
                .array_end => return efforts,
                .object_begin => {},
                else => return error.InvalidCatalog,
            }
            var is_effort = false;
            var values: catalog.Efforts = .{};
            while (try self.key()) |member| {
                defer self.release(member);
                if (std.mem.eql(u8, text(member), "type")) {
                    const kind = try self.next();
                    defer self.release(kind);
                    switch (kind) {
                        .string, .allocated_string => is_effort = std.mem.eql(u8, text(kind), "effort"),
                        else => return error.InvalidCatalog,
                    }
                } else if (std.mem.eql(u8, text(member), "values")) {
                    values = try self.effortValues();
                } else try self.skip();
            }
            if (is_effort) efforts.setUnion(values);
        }
    }

    fn effortValues(self: *Parser) Error!catalog.Efforts {
        // Values can precede type; collect recognized strings without assuming
        // the shape of toggle or budget_tokens options we will ignore.
        const tag = self.scanner.peekNextTokenType() catch |err| return parseError(err);
        if (tag != .array_begin) {
            try self.skip();
            return .{};
        }
        try self.expect(.array_begin);
        var efforts: catalog.Efforts = .{};
        while (true) {
            const value_tag = self.scanner.peekNextTokenType() catch |err| return parseError(err);
            if (value_tag != .string and value_tag != .array_end) {
                try self.skip();
                continue;
            }
            const token = try self.next();
            defer self.release(token);
            switch (token) {
                .array_end => return efforts,
                .string, .allocated_string => {
                    const effort = std.meta.stringToEnum(catalog.ReasoningEffort, text(token)) orelse continue;
                    efforts.insert(effort);
                },
                else => unreachable,
            }
        }
    }
};

fn parseError(err: anyerror) Error {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidCatalog;
}

test "models dev openai wins otherwise first provider wins and output is sorted" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const entries = try parse(arena.allocator(),
        \\{"earlier":{"models":{"z":{"limit":{"context":1}},"a":{"limit":{"context":2}}}},
        \\"openai":{"models":{"z":{"limit":{"context":3}}}},
        \\"later":{"models":{"z":{"limit":{"context":4}},"a":{"limit":{"context":5}}}}}
    );
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("a", entries[0].id);
    try std.testing.expectEqual(@as(?u32, 2), entries[0].context_window);
    try std.testing.expect(!entries[0].openai_listed);
    try std.testing.expectEqualStrings("z", entries[1].id);
    try std.testing.expectEqual(@as(?u32, 3), entries[1].context_window);
    try std.testing.expect(entries[1].openai_listed);
}

test "models dev unions listed efforts drops unknowns and ignores other options" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const entries = try parse(arena.allocator(),
        \\{"openai":{"models":{"m":{"reasoning_options":[
        \\{"values":["none","low","minimal","default","future"],"type":"effort"},
        \\{"type":"effort","values":["low","high"]},
        \\{"type":"toggle","values":[true,false,"medium",{}]},
        \\{"type":"budget_tokens","min":1,"max":999999,"values":{"max":true}}]}}}}
    );
    try std.testing.expectEqual(catalog.Efforts.init(.{ .none = true, .low = true, .high = true }), entries[0].efforts);
    try std.testing.expectEqual(@as(?u32, null), entries[0].context_window);
}

test "models dev context requires a u32 integer and invalid ids are skipped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const entries = try parse(arena.allocator(),
        \\{"ignored":{"nested":[{"huge":1e9999}]},"openai":{"models":{
        \\"missing":{},"string":{"limit":{"context":"12"}},"fraction":{"limit":{"context":1.5}},
        \\"exponent":{"limit":{"context":1e3}},"overflow":{"limit":{"context":4294967296}},
        \\"negative":{"limit":{"context":-1}},"null":{"limit":{"context":null}},
        \\"object":{"limit":{"context":{}}},"zero":{"limit":{"context":0}},
        \\"max":{"limit":{"context":4294967295}},"a\/b":{},"quote\"id":{},
        \\"has space":{},"":{},"\u00e9":{}}}}
    );
    try std.testing.expectEqual(@as(usize, 12), entries.len);
    try std.testing.expect(catalog.find(entries, "a/b") != null);
    try std.testing.expect(catalog.find(entries, "quote\"id") != null);
    try std.testing.expectEqual(@as(?u32, 0), catalog.find(entries, "zero").?.context_window);
    try std.testing.expectEqual(@as(?u32, 4294967295), catalog.find(entries, "max").?.context_window);
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.id, "zero") or std.mem.eql(u8, entry.id, "max")) continue;
        try std.testing.expectEqual(@as(?u32, null), entry.context_window);
    }
}

test "models dev rejects malformed input and missing openai without partial results" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "",                                "[]",                                                           "{}",                           "{\"other\":{\"models\":{}}}",
        "{\"openai\":{}} trailing",        "{\"openai\":{\"models\":{\"m\":{}}}",                          "{\"openai\":{\"models\":[]}}", "{\"openai\":{\"models\":{\"m\":{\"unknown\":}}}}",
        "{\"openai\":{\"unknown\":[1,]}}", "{\"openai\":{\"models\":{\"m\":{\"limit\":{\"context\":}}}}}",
    }) |body| try std.testing.expectError(error.InvalidCatalog, parse(arena.allocator(), body));
    try std.testing.expectEqual(@as(usize, 0), (try parse(arena.allocator(), "{\"openai\":{\"models\":{}}}")).len);
}

test "models dev owns escaped ids and releases temporary tokens and failed parses" {
    const allocator = std.testing.allocator;
    const entries = try parse(allocator,
        \\{"opena\u0069":{"mo\u0064els":{"a\/b":{"l\u0069mit":{"con\u0074ext":42},
        \\"reasoning_op\u0074ions":[{"t\u0079pe":"ef\u0066ort","val\u0075es":["h\u0069gh"]}]},
        \\"a/b":{"limit":{"context":99}},"bad id":["metadata skipped unread"]}}}
    );
    defer allocator.free(entries);
    defer for (entries) |entry| allocator.free(entry.id);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("a/b", entries[0].id);
    try std.testing.expectEqual(@as(?u32, 42), entries[0].context_window);
    try std.testing.expectEqual(catalog.Efforts.init(.{ .high = true }), entries[0].efforts);
    try std.testing.expect(entries[0].openai_listed);
    try std.testing.expectError(error.InvalidCatalog, parse(allocator,
        \\{"openai":{"models":{"a\/b":{},"a/b":{"unread":[1,]}}}}
    ));
    try std.testing.expectError(error.InvalidCatalog, parse(allocator,
        \\{"other":{"models":{"a\/b":{}}}}
    ));
}

test "models dev generation keeps chat metadata under the same provider precedence" {
    const body =
        \\{"earlier":{"models":{
        \\  "overridden":{"type":"image","family":"old","modalities":{"input":["text"],"output":["image"]}},
        \\  "first":{"type":"embedding","family":"embed","modalities":{"input":["text"],"output":["text"]}}
        \\}},"openai":{"models":{
        \\  "overridden":{"type":"chat","family":"gpt","limit":{"context":42},"modalities":{"input":["text","image"],"output":["text"]}},
        \\  "escaped":{"type":"ima\u0067e","type":"cha\u0074","family":"old","family":"a\/b",
        \\    "modalities":{"input":["image"],"output":["text"]},"modalities":{"input":["text"],"output":["text"]}}
        \\}},"later":{"models":{
        \\  "first":{"type":"chat","modalities":{"input":["text"],"output":["text"]}},
        \\  "overridden":{"type":"video","modalities":{"input":["text"],"output":["video"]}}
        \\}}}
    ;
    const scratch = std.testing.allocator;
    const records = try parseForGeneration(scratch, body);
    defer scratch.free(records);
    defer for (records) |record| record.deinit(scratch);
    try std.testing.expectEqual(@as(usize, 3), records.len);
    try std.testing.expectEqualStrings("escaped", records[0].model.id);
    try std.testing.expectEqualStrings("chat", records[0].kind.?);
    try std.testing.expectEqualStrings("a/b", records[0].family.?);
    try std.testing.expect(records[0].canChat());
    try std.testing.expectEqualStrings("first", records[1].model.id);
    try std.testing.expectEqualStrings("embedding", records[1].kind.?);
    try std.testing.expect(!records[1].model.openai_listed and !records[1].canChat());
    try std.testing.expectEqualStrings("overridden", records[2].model.id);
    try std.testing.expectEqualStrings("gpt", records[2].family.?);
    try std.testing.expect(records[2].model.openai_listed and records[2].canChat());
    const runtime = try parse(scratch, body);
    defer scratch.free(runtime);
    defer for (runtime) |entry| scratch.free(entry.id);
    for (runtime, records) |entry, record| {
        try std.testing.expectEqualStrings(entry.id, record.model.id);
        try std.testing.expectEqual(entry.context_window, record.model.context_window);
        try std.testing.expectEqual(entry.efforts, record.model.efforts);
        try std.testing.expectEqual(entry.openai_listed, record.model.openai_listed);
    }
}

test "models dev generation classifies every text modality combination and releases failed metadata" {
    const scratch = std.testing.allocator;
    for ([_]?[]const u8{ null, "chat", "image", "embedding", "realtime", "speech", "transcription", "video", "reranking", "" }, 0..) |kind, at| {
        // Only the absent/chat kind admits the fourth text-modality state.
        const expected = if (at < 2) [4]bool{ false, false, false, true } else [4]bool{ false, false, false, false };
        for (0..4) |modalities| {
            var body: std.Io.Writer.Allocating = .init(scratch);
            defer body.deinit();
            try body.writer.writeAll("{\"openai\":{\"models\":{\"m\":{");
            if (kind) |value| try body.writer.print("\"type\":\"{s}\",", .{value});
            try body.writer.print("\"modalities\":{{\"input\":[\"{s}\"],\"output\":[\"{s}\"]}}}}}}}}}}", .{
                if (modalities & 1 != 0) "text" else "audio",
                if (modalities & 2 != 0) "text" else "image",
            });
            const records = try parseForGeneration(scratch, body.written());
            defer scratch.free(records);
            defer for (records) |record| record.deinit(scratch);
            try std.testing.expectEqual(expected[modalities], records[0].canChat());
        }
    }
    const missing = try parseForGeneration(scratch, "{\"openai\":{\"models\":{\"m\":{}}}}");
    defer scratch.free(missing);
    defer for (missing) |record| record.deinit(scratch);
    try std.testing.expect(!missing[0].canChat());
    for ([_][]const u8{
        \\{"earlier":{"models":{"m":{"type":"image","family":"old"}}},"openai":{"models":{"m":{"type":"chat","family":"new"},"bad":{"type":"image","family":null}}}}
        ,
        \\{"openai":{"models":{"m":{"type":"image","family":"f","modalities":{"input":["text"],"output":[{}]}}}}}
        ,
        \\{"openai":{"models":{"m":{"type":"image","family":"f","modalities":[]}}}}
        ,
        \\{"openai":{"models":{"m":{"type":"image","family":"f"}}}}
        \\trailing
        ,
        \\{"other":{"models":{"m":{"type":"image","family":"f"}}}}
    }) |body| try std.testing.expectError(error.InvalidCatalog, parseForGeneration(scratch, body));
    // Generation's extra validation does not tighten runtime catalog reads.
    const runtime = try parse(scratch, "{\"openai\":{\"models\":{\"m\":{\"type\":[],\"family\":null,\"modalities\":42}}}}");
    defer scratch.free(runtime);
    defer for (runtime) |entry| scratch.free(entry.id);
    try std.testing.expectEqual(@as(usize, 1), runtime.len);
}
