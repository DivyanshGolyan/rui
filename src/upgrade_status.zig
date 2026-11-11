//! Inline /upgrade: where an Upgrade run stands and what the status bar
//! says about it, on the overview and in a conversation alike. Values in,
//! words out; the worker that runs the check and the install says where
//! the run stands. Whether Host requests wait is `session_upgrade`'s decision.

const std = @import("std");

/// What a run leaves Host requests: nothing installed, the selected Rui
/// speaks this Host's protocol, or it does not.
pub const Outcome = enum { unchanged, compatible, incompatible };

/// A release's version, as `0.{schema}.{patch}`.
pub const Version = struct {
    schema: u32,
    patch: u32,

    pub fn format(self: Version, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("0.{d}.{d}", .{ self.schema, self.patch });
    }
};

/// The Host a found release restarts: none running, or one with this many
/// Sessions at work.
pub const Host = union(enum) { none, running: usize };

pub const Found = struct { version: Version, host: Host };

/// Why the check installs nothing here. The full reason prints in a shell.
pub const Refusal = enum { first_install, source_build, unknown_build, package_managed };

/// Where an install stands. Only `preparing` can still roll back.
pub const Step = enum { preparing, publishing, restarting };

pub const Ended = union(enum) {
    up_to_date: Version,
    /// Another install selected a build newer than the release found:
    /// nothing changed and nothing restarted.
    superseded,
    refused: Refusal,
    /// Cancelled before publishing: nothing changed.
    cancelled,
    /// Failed before publishing: nothing changed.
    failed,
    upgraded: struct { version: Version, restarted: bool },
    /// Installed, but this client cannot use the Host it left.
    incompatible: Version,
};

/// Where a run stands. Its worker says the whole of it each time it
/// changes, and the status bar says only that: nothing here is advanced
/// step by step, so no step can arrive out of turn.
pub const Run = union(enum) {
    checking,
    installing: struct { found: Found, step: Step = .preparing },
    /// A stop was asked for and the run has not yet ended.
    cancelling,
    /// How it ended, as the status bar says it, and what it leaves Host
    /// requests: the run's own outcome, never read back from the words.
    ended: struct { how: Ended, outcome: Outcome },

    /// The run has not ended: Host requests wait and the worker is polled.
    pub fn going(self: Run) bool {
        return self != .ended;
    }

    /// Esc is the run's while it can still change nothing, as its line
    /// offers; whether the stop holds is the worker's to say.
    pub fn takesEscape(self: Run) bool {
        return switch (self) {
            .checking, .cancelling => true,
            .installing => |install| install.step == .preparing,
            .ended => false,
        };
    }
};

pub const Tone = enum { normal, attention };

/// How long the status bar keeps a line: while the run goes on, as a
/// notice (until the next key or about 5 s), or until another /upgrade.
pub const Lasts = enum { until_done, notice, persistent };

pub const Line = struct { text: []const u8, tone: Tone, lasts: Lasts };

pub const Script = enum { unicode, ascii };

/// Bytes the longest line takes.
pub const max_line_bytes = 160;

/// What the status bar says of `run`. Borrows `buffer`.
pub fn line(run: Run, buffer: *[max_line_bytes]u8, script: Script) Line {
    const dot = if (script == .unicode) "·" else "-";
    const ellipsis = if (script == .unicode) "…" else "...";
    const shell = "run rui upgrade in a shell for details";
    var writer = std.Io.Writer.fixed(buffer);
    const said: struct { Tone, Lasts } = switch (run) {
        .checking => said: {
            writer.print("Checking for updates{s}", .{ellipsis}) catch unreachable;
            break :said .{ .normal, .until_done };
        },
        .cancelling => said: {
            writer.print("Cancelling{s}", .{ellipsis}) catch unreachable;
            break :said .{ .normal, .until_done };
        },
        .installing => |install| said: {
            switch (install.step) {
                .preparing => {
                    writer.print("Upgrading to {f} {s} ", .{ install.found.version, dot }) catch unreachable;
                    switch (install.found.host) {
                        .none => writer.writeAll("no Host running") catch unreachable,
                        .running => |working| if (working == 0)
                            writer.writeAll("restarts the Host") catch unreachable
                        else
                            writer.print("restarts the Host ({d} Session{s} working)", .{ working, if (working == 1) "" else "s" }) catch unreachable,
                    }
                    writer.print(" {s} esc cancels", .{dot}) catch unreachable;
                },
                .publishing => writer.writeAll("Publishing; cancelling no longer rolls back") catch unreachable,
                .restarting => writer.print("Restarting the Host{s}", .{ellipsis}) catch unreachable,
            }
            break :said .{ .normal, .until_done };
        },
        .ended => |ended| switch (ended.how) {
            .up_to_date => |version| said: {
                writer.print("Rui is up to date ({f})", .{version}) catch unreachable;
                break :said .{ .normal, .notice };
            },
            .superseded => said: {
                writer.writeAll("A newer Rui is already installed; nothing changed") catch unreachable;
                break :said .{ .normal, .notice };
            },
            .refused => |why| said: {
                writer.print("Can't upgrade here: {s} {s} {s}", .{ refusals.get(why), dot, shell }) catch unreachable;
                break :said .{ .attention, .notice };
            },
            .cancelled => said: {
                writer.writeAll("Upgrade cancelled; nothing changed") catch unreachable;
                break :said .{ .normal, .notice };
            },
            .failed => said: {
                writer.print("! Upgrade failed; nothing changed {s} {s}", .{ dot, shell }) catch unreachable;
                break :said .{ .attention, .notice };
            },
            .upgraded => |done| said: {
                writer.print("Upgraded to {f}", .{done.version}) catch unreachable;
                if (done.restarted) writer.print(" {s} Host restarted", .{dot}) catch unreachable;
                break :said .{ .normal, .notice };
            },
            .incompatible => |version| said: {
                writer.print("Rui {f} installed {s} restart rui to continue {s} your draft is kept until you leave", .{ version, dot, dot }) catch unreachable;
                break :said .{ .attention, .persistent };
            },
        },
    };
    return .{ .text = writer.buffered(), .tone = said[0], .lasts = said[1] };
}

const refusals = std.enums.EnumArray(Refusal, []const u8).init(.{
    .first_install = "no managed install",
    .source_build = "a source build",
    .unknown_build = "an unknown build",
    .package_managed = "installed by another tool",
});

comptime {
    // The widest line fits: the longest version, Session count and refusal.
    const version = "0.4294967295.4294967295";
    std.debug.assert(("Upgrading to " ++ version ++ " · restarts the Host (18446744073709551615 Sessions working) · esc cancels").len <= max_line_bytes);
    std.debug.assert(("Rui " ++ version ++ " installed · restart rui to continue · your draft is kept until you leave").len <= max_line_bytes);
    for (refusals.values) |why| std.debug.assert(("Can't upgrade here:  · run rui upgrade in a shell for details").len + why.len + 2 <= max_line_bytes);
}

test "a run's line: the check, what the restart will do, each step, and a stop" {
    const v: Version = .{ .schema = 60, .patch = 1 };
    for ([_]struct { Run, []const u8, bool }{
        .{ .checking, "Checking for updates…", true },
        .{ .{ .installing = .{ .found = .{ .version = v, .host = .{ .running = 2 } } } }, "Upgrading to 0.60.1 · restarts the Host (2 Sessions working) · esc cancels", true },
        .{ .{ .installing = .{ .found = .{ .version = v, .host = .{ .running = 1 } } } }, "Upgrading to 0.60.1 · restarts the Host (1 Session working) · esc cancels", true },
        .{ .{ .installing = .{ .found = .{ .version = v, .host = .{ .running = 0 } } } }, "Upgrading to 0.60.1 · restarts the Host · esc cancels", true },
        .{ .{ .installing = .{ .found = .{ .version = v, .host = .none } } }, "Upgrading to 0.60.1 · no Host running · esc cancels", true },
        // Once it publishes the line stops offering Esc, and Esc is the screen's.
        .{ .{ .installing = .{ .found = .{ .version = v, .host = .none }, .step = .publishing } }, "Publishing; cancelling no longer rolls back", false },
        .{ .{ .installing = .{ .found = .{ .version = v, .host = .none }, .step = .restarting } }, "Restarting the Host…", false },
        // A second Esc is still the run's while it winds down.
        .{ .cancelling, "Cancelling…", true },
    }) |case| {
        var buffer: [max_line_bytes]u8 = undefined;
        const shown = line(case[0], &buffer, .unicode);
        try std.testing.expectEqualStrings(case[1], shown.text);
        try std.testing.expectEqual(Tone.normal, shown.tone);
        try std.testing.expectEqual(Lasts.until_done, shown.lasts);
        try std.testing.expect(case[0].going());
        try std.testing.expectEqual(case[2], case[0].takesEscape());
        // A line offers Esc exactly while Esc is the run's to take.
        if (case[0] != .cancelling and case[0] != .checking) try std.testing.expectEqual(case[2], std.mem.endsWith(u8, shown.text, "esc cancels"));
    }
}

test "how a run ended: a notice, or held until another /upgrade when the client cannot go on" {
    const v: Version = .{ .schema = 60, .patch = 1 };
    for ([_]struct { Ended, []const u8, Tone, Lasts }{
        .{ .{ .up_to_date = .{ .schema = 59, .patch = 7 } }, "Rui is up to date (0.59.7)", .normal, .notice },
        // Another install selected a newer build: no version of ours to name.
        .{ .superseded, "A newer Rui is already installed; nothing changed", .normal, .notice },
        .{ .{ .refused = .first_install }, "Can't upgrade here: no managed install · run rui upgrade in a shell for details", .attention, .notice },
        .{ .{ .refused = .source_build }, "Can't upgrade here: a source build · run rui upgrade in a shell for details", .attention, .notice },
        .{ .{ .refused = .unknown_build }, "Can't upgrade here: an unknown build · run rui upgrade in a shell for details", .attention, .notice },
        .{ .{ .refused = .package_managed }, "Can't upgrade here: installed by another tool · run rui upgrade in a shell for details", .attention, .notice },
        .{ .cancelled, "Upgrade cancelled; nothing changed", .normal, .notice },
        .{ .failed, "! Upgrade failed; nothing changed · run rui upgrade in a shell for details", .attention, .notice },
        .{ .{ .upgraded = .{ .version = v, .restarted = true } }, "Upgraded to 0.60.1 · Host restarted", .normal, .notice },
        .{ .{ .upgraded = .{ .version = v, .restarted = false } }, "Upgraded to 0.60.1", .normal, .notice },
        .{ .{ .incompatible = .{ .schema = 61, .patch = 0 } }, "Rui 0.61.0 installed · restart rui to continue · your draft is kept until you leave", .attention, .persistent },
    }) |case| {
        // The words never depend on what the run leaves Host requests.
        const run: Run = .{ .ended = .{ .how = case[0], .outcome = .unchanged } };
        var buffer: [max_line_bytes]u8 = undefined;
        const shown = line(run, &buffer, .unicode);
        try std.testing.expectEqualStrings(case[1], shown.text);
        try std.testing.expectEqual(case[2], shown.tone);
        try std.testing.expectEqual(case[3], shown.lasts);
        try std.testing.expect(!run.going() and !run.takesEscape());
    }
}

test "ASCII spells the ellipsis and dot" {
    var buffer: [max_line_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("Checking for updates...", line(.checking, &buffer, .ascii).text);
    try std.testing.expectEqualStrings("Upgrading to 0.60.0 - restarts the Host (2 Sessions working) - esc cancels", line(.{ .installing = .{ .found = .{ .version = .{ .schema = 60, .patch = 0 }, .host = .{ .running = 2 } } } }, &buffer, .ascii).text);
}

/// Compact state for a Version field. The shell status line can offer recovery
/// commands; a settings field contains state only, never a second command UI.
pub fn fieldTail(run: Run, buffer: *[max_line_bytes]u8) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    const text: []const u8 = switch (run) {
        .checking => " · checking for updates…",
        .cancelling => " · cancelling…",
        .installing => |install| switch (install.step) {
            .preparing => {
                writer.print(" · upgrading to {f}", .{install.found.version}) catch unreachable;
                return writer.buffered();
            },
            .publishing => " · publishing…",
            .restarting => " · restarting the Host…",
        },
        .ended => |ended| switch (ended.how) {
            .up_to_date => " · up to date",
            .superseded => " · newer Rui installed",
            .refused => |why| switch (why) {
                .first_install => " · no managed install",
                .source_build => " · source build",
                .unknown_build => " · unknown build",
                .package_managed => " · package managed",
            },
            .cancelled => " · cancelled",
            .failed => " · upgrade failed",
            .upgraded => |done| {
                writer.print(" · upgraded to {f}", .{done.version}) catch unreachable;
                return writer.buffered();
            },
            .incompatible => |version| {
                writer.print(" · {f} installed · restart needed", .{version}) catch unreachable;
                return writer.buffered();
            },
        },
    };
    return text;
}

test "Upgrade settings field reports state without shell instructions" {
    var buffer: [max_line_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(" · checking for updates…", fieldTail(.checking, &buffer));
    try std.testing.expectEqualStrings(" · cancelling…", fieldTail(.cancelling, &buffer));
    const found: Found = .{ .version = .{ .schema = 61, .patch = 0 }, .host = .none };
    try std.testing.expectEqualStrings(" · upgrading to 0.61.0", fieldTail(.{ .installing = .{ .found = found } }, &buffer));
    try std.testing.expectEqualStrings(" · publishing…", fieldTail(.{ .installing = .{ .found = found, .step = .publishing } }, &buffer));
    try std.testing.expectEqualStrings(" · restarting the Host…", fieldTail(.{ .installing = .{ .found = found, .step = .restarting } }, &buffer));
    const endings = [_]Ended{
        .{ .up_to_date = .{ .schema = 60, .patch = 0 } },
        .superseded,
        .{ .refused = .first_install },
        .{ .refused = .source_build },
        .{ .refused = .unknown_build },
        .{ .refused = .package_managed },
        .cancelled,
        .failed,
        .{ .upgraded = .{ .version = found.version, .restarted = true } },
        .{ .incompatible = found.version },
    };
    for (endings) |ending| {
        const text = fieldTail(.{ .ended = .{ .how = ending, .outcome = .unchanged } }, &buffer);
        try std.testing.expect(std.mem.startsWith(u8, text, " · "));
        try std.testing.expect(std.mem.indexOf(u8, text, "shell") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "esc") == null);
    }
}
