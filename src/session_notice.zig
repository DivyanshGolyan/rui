const std = @import("std");
const submission = @import("submission_state.zig");
const ConsentPolicy = @import("session_consent.zig");
const Text = @import("TerminalText.zig");
const protocol = @import("protocol.zig");

pub const Held = struct { kind: submission.Kind, state: submission.State, failure: ?Failure = null };

pub const Failure = struct { line: []const u8, key: Key };

pub const Key = enum { retry, discard, status };

pub const Presentation = struct {
    note: ?[]const u8 = null,
    status: ?[]const u8 = null,
    action: ?Key = null,
    details: bool = false,
    details_available: bool = false,
    repair_details: bool = false,
    in_flight: bool = false,
};

pub const too_large = "! Environment too large; nothing sent · details";

/// The refusal of a chat Message whose Session's provider this Host does not serve; the fix is in the Host's settings.
pub fn writeUnserved(writer: *std.Io.Writer, provider: ?@import("connection.zig").Name) !void {
    const shown = if (provider) |name| if (@import("provider_route.zig").builtInOf(name)) |built_in| built_in.shown() else name.slice() else "This Session's provider";
    try writer.print("! {s}{s}", .{ shown, unserved_advice });
}

const unserved_advice = " isn't served by this Host. Check rui host settings, then rui host pause and rui host start.";
pub const unserved_capacity = blk: {
    var longest: usize = "This Session's provider".len;
    for (std.meta.tags(protocol.Provider)) |provider| longest = @max(longest, provider.shown().len);
    longest = @max(longest, @import("connection.zig").max_name_bytes);
    break :blk "! ".len + longest + unserved_advice.len;
};

pub fn presentation(opening: bool, waiting: bool, held: ?Held) Presentation {
    var result: Presentation = .{};
    if (held) |original| {
        const shown: struct { line: ?[]const u8, action: ?Key } = if (original.failure) |failure|
            .{ .line = failure.line, .action = failure.key }
        else switch (original.state) {
            .not_started => .{ .line = "Not sent · ctrl+r retries original", .action = .retry },
            .submitting => .{ .line = if (original.kind == .decision) "Sending…" else null, .action = null },
            .unconfirmed => .{ .line = if (original.kind == .decision) "! Decision not confirmed · ctrl+r retries original" else "Not confirmed · ctrl+r retries original", .action = .retry },
            .rejected => .{ .line = "Rejected · /discard", .action = .discard },
        };
        if (original.kind == .message) result.note = shown.line else result.status = shown.line;
        result.action = shown.action;
        result.details = original.state != .submitting;
        result.details_available = true;
        result.repair_details = result.details and original.failure != null and shown.action == .status;
        result.in_flight = original.kind == .decision and original.state == .submitting;
    }
    if (opening) {
        result.status = "Opening…";
        result.in_flight = true;
    } else if (waiting) {
        result.status = "";
        result.in_flight = false;
    }
    return result;
}

pub fn key(held: Held) ?Key {
    return presentation(false, false, held).action;
}

pub const Action = struct {
    preview: bool,
    visible: bool,
    reason: bool,
};

pub fn decision(action: Action) []const u8 {
    if (action.preview) return "! Action exceeds in-app preview. Approval disabled.";
    return if (action.visible) "! Action needs a decision; Esc returns to the choice." else "! Action needs a decision; Esc returns to it.";
}

pub const reason_not_ready = "! Not ready; nothing denied · " ++ ConsentPolicy.deny_words;

pub const Refusal = @import("session_keys.zig").Facts.Send.Refusal;

pub const Busy = struct {
    /// The reason `session_keys.Facts.Send.refusal` gave, or null when sending
    /// is open and only a pending original or command refused the input.
    refusal: ?Refusal,
    held: ?Held,
    action: ?Action,
    letter: bool,
};

pub const host_not_ready = "! Host not ready.";
pub const opening_not_ready = "! Chat still opening.";
pub const saving_not_ready = "! Chat info still saving.";

/// The notice for a refused send. `.upgrade` is not here: its words depend on
/// the Upgrade's phase, which `session_upgrade.refusal` owns.
pub fn busy(facts: Busy) []const u8 {
    if (facts.refusal) |refusal| switch (refusal) {
        .command => return "! Command still running.",
        .saving => return saving_not_ready,
        .upgrade => unreachable,
        .rejected => return "! Original rejected. Keep editing; /discard releases it.",
        .host => return host_not_ready,
        .opening => return opening_not_ready,
        .preparing => return "! Action needs a decision.",
        .submitting => {},
    };
    if (facts.action) |action| {
        if (!action.reason) return decision(action);
        return if (facts.letter) "! Use ←→ and Enter to choose; a message denies the call." else reason_not_ready;
    }
    if (facts.held) |held| if (held.kind == .decision) return "! Decision pending. Keep editing; Ctrl-R retries that decision.";
    return "! Input still pending. Keep editing; Ctrl-R retries the original.";
}

pub const Close = union(enum) { leave, stay: []const u8 };

pub fn close(held: ?submission.State, published: bool, draft_empty: bool) Close {
    if (held) |state| switch (state) {
        .not_started => return .{ .stay = "Esc returns to the overview once Ctrl-R retries the original." },
        .submitting => return .{ .stay = "Esc returns to the overview once the original is confirmed." },
        .unconfirmed => if (!published) return .{ .stay = "Esc returns to the overview once Ctrl-R retries the original." },
        .rejected => {},
    };
    return if (draft_empty) .leave else .{ .stay = "Esc returns to the overview once the draft is empty." };
}

pub fn follow(held: ?submission.State, published: bool, draft_empty: bool, action: bool, command: bool) Close {
    if (action) return .{ .stay = "Links open once the Action is decided." };
    if (command) return .{ .stay = "Links open once the command ends." };
    return close(held, published, draft_empty);
}

test "a Session link leaves only where Esc would, and never past a waiting Action or command" {
    try std.testing.expectEqual(Close.leave, follow(null, false, true, false, false));
    try std.testing.expectEqualStrings("Esc returns to the overview once the draft is empty.", follow(null, false, false, false, false).stay);
    try std.testing.expectEqualStrings("Esc returns to the overview once the original is confirmed.", follow(.submitting, false, true, false, false).stay);
    try std.testing.expectEqualStrings("Links open once the Action is decided.", follow(null, false, true, true, true).stay);
    try std.testing.expectEqualStrings("Links open once the command ends.", follow(null, false, true, false, true).stay);
}

test "original presentation preserves placement actions repair and opening precedence" {
    try std.testing.expectEqualDeep(Presentation{}, presentation(false, false, null));
    for ([_]submission.Kind{ .message, .decision }) |kind| {
        for ([_]submission.State{ .not_started, .submitting, .unconfirmed, .rejected }) |state| {
            const held: Held = .{ .kind = kind, .state = state };
            const shown = presentation(false, false, held);
            try std.testing.expect(shown.details_available);
            try std.testing.expectEqual(state != .submitting, shown.details);
            try std.testing.expect(!shown.repair_details);
            try std.testing.expectEqual(kind == .decision and state == .submitting, shown.in_flight);
            const words: ?[]const u8 = switch (state) {
                .not_started => "Not sent · ctrl+r retries original",
                .submitting => if (kind == .decision) "Sending…" else null,
                .unconfirmed => if (kind == .decision) "! Decision not confirmed · ctrl+r retries original" else "Not confirmed · ctrl+r retries original",
                .rejected => "Rejected · /discard",
            };
            const line = if (kind == .message) shown.note else shown.status;
            try std.testing.expectEqual(words == null, line == null);
            if (words) |expected| try std.testing.expectEqualStrings(expected, line.?);
            try std.testing.expect((if (kind == .message) shown.status else shown.note) == null);
            const action: ?Key = switch (state) {
                .not_started, .unconfirmed => .retry,
                .submitting => null,
                .rejected => .discard,
            };
            try std.testing.expectEqual(action, shown.action);
            try std.testing.expectEqual(action, key(held));
        }
        const refused: Held = .{ .kind = kind, .state = .not_started, .failure = .{ .line = too_large, .key = .status } };
        const shown = presentation(false, false, refused);
        try std.testing.expectEqualStrings(too_large, (if (kind == .message) shown.note else shown.status).?);
        try std.testing.expect(shown.details and shown.details_available and shown.repair_details);
        try std.testing.expectEqual(@as(?Key, .status), shown.action);
        try std.testing.expectEqual(@as(?Key, .status), key(refused));
        const opening = presentation(true, true, refused);
        try std.testing.expectEqualStrings("Opening…", opening.status.?);
        try std.testing.expect(opening.in_flight);
        if (kind == .message) try std.testing.expectEqualStrings(too_large, opening.note.?);
        const waiting = presentation(false, true, refused);
        try std.testing.expectEqualStrings("", waiting.status.?);
        try std.testing.expect(!waiting.in_flight);
    }
}

test "Enter in the draft says the most pressing reason it sent nothing" {
    const reason: Action = .{ .preview = false, .visible = true, .reason = true };
    const rejected: Held = .{ .kind = .message, .state = .rejected };
    const pending: Held = .{ .kind = .decision, .state = .unconfirmed };
    const cases = [_]struct { Busy, []const u8 }{
        .{ .{ .refusal = .command, .held = rejected, .action = reason, .letter = false }, "! Command still running." },
        .{ .{ .refusal = .rejected, .held = rejected, .action = reason, .letter = false }, "! Original rejected. Keep editing; /discard releases it." },
        .{ .{ .refusal = .preparing, .held = pending, .action = reason, .letter = false }, "! Action needs a decision." },
        .{ .{ .refusal = null, .held = pending, .action = reason, .letter = false }, reason_not_ready },
        .{ .{ .refusal = null, .held = null, .action = reason, .letter = true }, "! Use ←→ and Enter to choose; a message denies the call." },
        .{ .{ .refusal = null, .held = null, .action = .{ .preview = false, .visible = false, .reason = false }, .letter = true }, "! Action needs a decision; Esc returns to it." },
        .{ .{ .refusal = null, .held = pending, .action = null, .letter = true }, "! Decision pending. Keep editing; Ctrl-R retries that decision." },
        .{ .{ .refusal = .submitting, .held = .{ .kind = .message, .state = .unconfirmed }, .action = null, .letter = false }, "! Input still pending. Keep editing; Ctrl-R retries the original." },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case[1], busy(case[0]));
    try std.testing.expect(std.mem.indexOf(u8, reason_not_ready, ConsentPolicy.deny_words) != null);
}

test "every way Enter is refused names its own reason, whatever original or Action is held" {
    const Send = @import("session_keys.zig").Facts.Send;
    const helds = [_]?Held{ null, .{ .kind = .message, .state = .unconfirmed }, .{ .kind = .decision, .state = .unconfirmed }, .{ .kind = .message, .state = .rejected } };
    const actions = [_]?Action{ null, .{ .preview = false, .visible = true, .reason = true }, .{ .preview = true, .visible = false, .reason = false } };
    var bits: u8 = 0;
    while (true) : (bits += 1) {
        const send: Send = .{ .command_active = bits & 1 != 0, .upgrade = bits & 2 != 0, .saving = bits & 4 != 0, .rejected = bits & 8 != 0, .host_held = bits & 16 != 0, .opening = bits & 32 != 0, .preparing = bits & 64 != 0, .submitting = bits & 128 != 0 };
        errdefer std.debug.print("send={any}\n", .{send});
        try std.testing.expectEqual(bits == 0, send.allowed());
        // The first refusing fact in the contract's order, listed here
        // independently of `Send.refusal`.
        const expected: ?[]const u8 = if (send.command_active)
            "! Command still running."
        else if (send.upgrade)
            null
        else if (send.saving)
            saving_not_ready
        else if (send.rejected)
            "! Original rejected. Keep editing; /discard releases it."
        else if (send.host_held)
            host_not_ready
        else if (send.opening)
            opening_not_ready
        else if (send.preparing)
            "! Action needs a decision."
        else
            null;
        if (expected) |words| for (helds) |held| for (actions) |action| for ([_]bool{ false, true }) |letter| {
            try std.testing.expectEqualStrings(words, busy(.{ .refusal = send.refusal(), .held = held, .action = action, .letter = letter }));
        };
        // A send still under way refuses with no reason of its own: the held
        // original or Action says what is pending.
        if (send.refusal() == .submitting) {
            try std.testing.expectEqualStrings("! Input still pending. Keep editing; Ctrl-R retries the original.", busy(.{ .refusal = .submitting, .held = null, .action = null, .letter = false }));
            try std.testing.expectEqualStrings("! Decision pending. Keep editing; Ctrl-R retries that decision.", busy(.{ .refusal = .submitting, .held = helds[2], .action = null, .letter = false }));
        }
        if (bits == std.math.maxInt(u8)) break;
    }
    // The reasons this PR words fit the narrowest chat footer.
    for ([_][]const u8{ host_not_ready, opening_not_ready, saving_not_ready }) |words| try std.testing.expect(words.len <= 46);
}

test "a waiting Action that is a preview says it is decided in the shell, whether or not it is on screen" {
    for ([_]bool{ false, true }) |visible| {
        try std.testing.expectEqualStrings("! Action exceeds in-app preview. Approval disabled.", decision(.{ .preview = true, .visible = visible, .reason = false }));
    }
    try std.testing.expectEqualStrings("! Action needs a decision; Esc returns to the choice.", decision(.{ .preview = false, .visible = true, .reason = false }));
}

test "Esc leaves the settled view with an empty draft unless the held original is not yet saved" {
    for ([_]?submission.State{ null, .unconfirmed, .rejected }) |held| {
        try std.testing.expectEqual(Close.leave, close(held, true, true));
        try std.testing.expectEqualStrings("Esc returns to the overview once the draft is empty.", close(held, true, false).stay);
    }
    try std.testing.expectEqualStrings("Esc returns to the overview once Ctrl-R retries the original.", close(.unconfirmed, false, true).stay);
    for ([_]bool{ false, true }) |empty| {
        try std.testing.expectEqualStrings("Esc returns to the overview once Ctrl-R retries the original.", close(.not_started, false, empty).stay);
        try std.testing.expectEqualStrings("Esc returns to the overview once the original is confirmed.", close(.submitting, false, empty).stay);
    }
}

test "SUI-14 message and decision notices retain their placement during opening and waiting" {
    const Case = struct {
        held: Held,
        note: ?[]const u8,
        status: ?[]const u8,
        action: ?Key,
        details: bool,
        in_flight: bool,
    };
    const cases = [_]Case{
        .{ .held = .{ .kind = .message, .state = .not_started }, .note = "Not sent · ctrl+r retries original", .status = null, .action = .retry, .details = true, .in_flight = false },
        .{ .held = .{ .kind = .message, .state = .submitting }, .note = null, .status = null, .action = null, .details = false, .in_flight = false },
        .{ .held = .{ .kind = .message, .state = .unconfirmed }, .note = "Not confirmed · ctrl+r retries original", .status = null, .action = .retry, .details = true, .in_flight = false },
        .{ .held = .{ .kind = .message, .state = .rejected }, .note = "Rejected · /discard", .status = null, .action = .discard, .details = true, .in_flight = false },
        .{ .held = .{ .kind = .decision, .state = .not_started }, .note = null, .status = "Not sent · ctrl+r retries original", .action = .retry, .details = true, .in_flight = false },
        .{ .held = .{ .kind = .decision, .state = .submitting }, .note = null, .status = "Sending…", .action = null, .details = false, .in_flight = true },
        .{ .held = .{ .kind = .decision, .state = .unconfirmed }, .note = null, .status = "! Decision not confirmed · ctrl+r retries original", .action = .retry, .details = true, .in_flight = false },
        .{ .held = .{ .kind = .decision, .state = .rejected }, .note = null, .status = "Rejected · /discard", .action = .discard, .details = true, .in_flight = false },
    };
    const checkText = struct {
        fn check(expected: ?[]const u8, actual: ?[]const u8) !void {
            try std.testing.expectEqual(expected == null, actual == null);
            if (expected) |text| try std.testing.expectEqualStrings(text, actual.?);
        }
    }.check;
    for (cases) |case| {
        for ([_]bool{ false, true }) |opening| {
            for ([_]bool{ false, true }) |waiting| {
                const shown = presentation(opening, waiting, case.held);
                try checkText(case.note, shown.note);
                try checkText(if (opening) "Opening…" else if (waiting) "" else case.status, shown.status);
                try std.testing.expectEqual(case.action, shown.action);
                try std.testing.expectEqual(case.details, shown.details);
                try std.testing.expect(shown.details_available);
                try std.testing.expect(!shown.repair_details);
                try std.testing.expectEqual(if (opening) true else if (waiting) false else case.in_flight, shown.in_flight);
            }
        }
    }
}

pub const Departure = struct { store: []const u8, opened: ?[]const u8, action: ?u64 };

/// The notice a departing terminal prints: how to come back, and for an open Session the
/// commands that name its Store, its Session and any pending Action.
pub fn writeDeparture(writer: *std.Io.Writer, facts: Departure) !void {
    try writer.writeAll("\nYour chats keep working while you are away.\nCome back with: rui\n");
    if (facts.opened) |session| {
        try writer.writeAll("Resume: rui session resume --store ");
        try Text.writeShellWord(writer, facts.store);
        try Text.writeShellSession(writer, session, true);
        try writer.writeByte('\n');
        if (facts.action) |id| {
            try writer.writeAll("Pending Action: inspect the complete proposal before deciding.\n");
            for ([_][]const u8{ "inspect", "allow", "deny" }) |command| {
                try writer.print("rui action {s} --store ", .{command});
                try Text.writeShellWord(writer, facts.store);
                try Text.writeShellSession(writer, session, false);
                try writer.print(" --action {d}\n", .{id});
            }
        }
    } else {
        try writer.writeAll("Overview: rui --store ");
        try Text.writeShellWord(writer, facts.store);
        try writer.writeByte('\n');
    }
}

test "SUI-62 departure names the Store, the Session and the pending Action" {
    // Decodes one `$'...'` word the way a POSIX shell reads it, into `out`; returns the value and the index after the word.
    const decodeWord = struct {
        fn decode(text: []const u8, out: []u8) !struct { value: []const u8, end: usize } {
            if (!std.mem.startsWith(u8, text, "$'")) return error.NotQuotedWord;
            var index: usize = 2;
            var length: usize = 0;
            while (true) {
                if (index >= text.len) return error.UnterminatedWord;
                const byte = text[index];
                if (byte == '\'') return .{ .value = out[0..length], .end = index + 1 };
                if (byte == '\\') {
                    if (index + 1 >= text.len) return error.UnterminatedWord;
                    const escaped = text[index + 1];
                    if (escaped == '\\' or escaped == '\'') {
                        out[length] = escaped;
                        index += 2;
                    } else {
                        if (index + 4 > text.len) return error.UnterminatedWord;
                        out[length] = try std.fmt.parseInt(u8, text[index + 1 .. index + 4], 8);
                        index += 4;
                    }
                } else {
                    out[length] = byte;
                    index += 1;
                }
                length += 1;
            }
        }
    }.decode;
    // A 4095-byte Store escapes to about 8 KiB per shell word, and one departure writes four of them.
    var storage: [64 * 1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&storage);
    const ordinary = "\nYour chats keep working while you are away.\nCome back with: rui\n";
    // Literal lines for the plain Store and one Session with a pending Action.
    try writeDeparture(&out, .{ .store = "/s", .opened = "k7m2qx", .action = 7 });
    try std.testing.expectEqualStrings(ordinary ++
        "Resume: rui session resume --store $'/s' k7m2qx\n" ++
        "Pending Action: inspect the complete proposal before deciding.\n" ++
        "rui action inspect --store $'/s' --session k7m2qx --action 7\n" ++
        "rui action allow --store $'/s' --session k7m2qx --action 7\n" ++
        "rui action deny --store $'/s' --session k7m2qx --action 7\n", out.buffered());
    out.end = 0;
    try writeDeparture(&out, .{ .store = "/s", .opened = "k7m2qx", .action = null });
    try std.testing.expectEqualStrings(ordinary ++ "Resume: rui session resume --store $'/s' k7m2qx\n", out.buffered());
    out.end = 0;
    try writeDeparture(&out, .{ .store = "/s", .opened = null, .action = 7 });
    try std.testing.expectEqualStrings(ordinary ++ "Overview: rui --store $'/s'\n", out.buffered());

    // Every Store text and Session, with and without a Session and an Action, round-trips through shell words.
    const hostile_store = "it's a \\ \n\xe2\x80\xae ";
    var long_buffer: [4095]u8 = undefined;
    for (&long_buffer, 0..) |*byte, index| byte.* = "a'\\\n "[index % 5];
    const long_store: []const u8 = &long_buffer;
    const stores = [_][]const u8{ "/plain/store", "/with space", "/quote'd", hostile_store, long_store };
    const sessions = [_][]const u8{ "k7m2qx", "09azvw" };
    const actions = [_]?u64{ null, 7, std.math.maxInt(u64) };
    for (stores) |store| for (sessions) |session| for (actions) |action| {
        out.end = 0;
        try writeDeparture(&out, .{ .store = store, .opened = session, .action = action });
        var rest = out.buffered()[ordinary.len..];
        var decoded: [4096]u8 = undefined;
        // Resume line: the Store word, then the bare Session ID.
        const resume_prefix = "Resume: rui session resume --store ";
        try std.testing.expect(std.mem.startsWith(u8, rest, resume_prefix));
        const resumed = try decodeWord(rest[resume_prefix.len..], &decoded);
        try std.testing.expectEqualSlices(u8, store, resumed.value);
        rest = rest[resume_prefix.len + resumed.end ..];
        try std.testing.expectEqual(@as(u8, ' '), rest[0]);
        try std.testing.expectEqualStrings(session, rest[1 .. 1 + session.len]);
        rest = rest[1 + session.len ..];
        try std.testing.expectEqual(@as(u8, '\n'), rest[0]);
        rest = rest[1..];
        if (action) |id| {
            try std.testing.expect(std.mem.startsWith(u8, rest, "Pending Action: inspect the complete proposal before deciding.\n"));
            rest = rest["Pending Action: inspect the complete proposal before deciding.\n".len..];
            for ([_][]const u8{ "inspect", "allow", "deny" }) |command| {
                const command_prefix = try std.fmt.allocPrint(std.testing.allocator, "rui action {s} --store ", .{command});
                defer std.testing.allocator.free(command_prefix);
                try std.testing.expect(std.mem.startsWith(u8, rest, command_prefix));
                const word = try decodeWord(rest[command_prefix.len..], &decoded);
                try std.testing.expectEqualSlices(u8, store, word.value);
                rest = rest[command_prefix.len + word.end ..];
                try std.testing.expect(std.mem.startsWith(u8, rest, " --session "));
                rest = rest[" --session ".len..];
                try std.testing.expectEqualStrings(session, rest[0..session.len]);
                rest = rest[session.len..];
                const action_text = try std.fmt.allocPrint(std.testing.allocator, " --action {d}\n", .{id});
                defer std.testing.allocator.free(action_text);
                try std.testing.expect(std.mem.startsWith(u8, rest, action_text));
                rest = rest[action_text.len..];
            }
        }
        try std.testing.expectEqual(@as(usize, 0), rest.len);
    };

    // Overview with no Session: the Store word alone.
    for (stores) |store| {
        out.end = 0;
        try writeDeparture(&out, .{ .store = store, .opened = null, .action = null });
        var decoded: [4096]u8 = undefined;
        const prefix = "Overview: rui --store ";
        const rest = out.buffered()[ordinary.len..];
        try std.testing.expect(std.mem.startsWith(u8, rest, prefix));
        const word = try decodeWord(rest[prefix.len..], &decoded);
        try std.testing.expectEqualSlices(u8, store, word.value);
        try std.testing.expectEqualStrings("\n", rest[prefix.len + word.end ..]);
    }
}

test "a refused chat Message names its unserved provider and the settings fix" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeUnserved(&writer, @import("connection.zig").Name.parse("openai"));
    try std.testing.expectEqualStrings("! OpenAI isn't served by this Host. Check rui host settings, then rui host pause and rui host start.", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);
    try writeUnserved(&writer, null);
    try std.testing.expectEqualStrings("! This Session's provider isn't served by this Host. Check rui host settings, then rui host pause and rui host start.", writer.buffered());
}
