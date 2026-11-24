const std = @import("std");

pub const Outcome = enum { unchanged, compatible, incompatible };

pub const Version = struct {
    schema: u32,
    patch: u32,

    pub fn format(self: Version, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("0.{d}.{d}", .{ self.schema, self.patch });
    }

    /// The one release ordering: schema first, then patch.
    pub fn order(a: Version, b: Version) std.math.Order {
        const schema = std.math.order(a.schema, b.schema);
        return if (schema == .eq) std.math.order(a.patch, b.patch) else schema;
    }
};

test "releases order by schema first, then patch" {
    const v = struct {
        fn of(schema: u32, patch: u32) Version {
            return .{ .schema = schema, .patch = patch };
        }
    }.of;
    try std.testing.expectEqual(std.math.Order.lt, v(9, 5).order(v(10, 0)));
    try std.testing.expectEqual(std.math.Order.gt, v(10, 0).order(v(9, 99)));
    try std.testing.expectEqual(std.math.Order.lt, v(9, 1).order(v(9, 2)));
    try std.testing.expectEqual(std.math.Order.gt, v(9, 2).order(v(9, 1)));
    try std.testing.expectEqual(std.math.Order.eq, v(9, 2).order(v(9, 2)));
}

pub const Host = union(enum) { none, running: usize };

pub const Found = struct { host: Host };

pub const Refusal = enum { first_install, source_build, unknown_build, package_managed };

pub const Step = enum { preparing, publishing, restarting };

pub const Failure = enum { download, release, other };

pub const Ended = union(enum) {
    up_to_date: Version,
    superseded: Version,
    refused: Refusal,
    cancelled,
    failed: Failure,
    upgraded: struct { version: Version, restarted: bool },
    incompatible: Version,
};

pub const Run = union(enum) {
    checking,
    installing: struct { found: Found, step: Step = .preparing },
    cancelling,
    ended: struct { how: Ended, outcome: Outcome },

    pub fn going(self: Run) bool {
        return self != .ended;
    }

    pub fn takesEscape(self: Run) bool {
        return switch (self) {
            .checking, .cancelling => true,
            .installing => |install| install.step == .preparing,
            .ended => false,
        };
    }
};

pub const Tone = enum { normal, attention };

pub const Lasts = enum { until_done, notice, persistent };

pub const Line = struct { text: []const u8, tone: Tone, lasts: Lasts };

pub const Script = enum { unicode, ascii };

pub const max_line_bytes = 160;

pub const Target = struct {
    available: ?Version,
    run: ?Run,
};

pub const Control = struct {
    text: []const u8,
    tone: enum { quiet, link, warning },
    enabled: bool,
    fallback: ?[]const u8 = null,

    pub fn fit(self: Control, columns: usize) Control {
        var fitted = self;
        if (self.fallback) |fallback| if (self.text.len > columns) {
            fitted.text = fallback;
        };
        return fitted;
    }
};

pub fn control(current: []const u8, available: ?Version, run: ?Run, buffer: *[max_line_bytes]u8, script: Script) Control {
    var selected: ?Version = null;
    if (run) |active| {
        if (active.going()) return .{ .text = if (script == .unicode) "Updating…" else "Updating...", .tone = .quiet, .enabled = false };
        switch (active.ended.how) {
            .failed => |why| return failedControl(failure_words.get(why), buffer),
            .refused => |why| return failedControl(refusals.get(why), buffer),
            .upgraded => |done| selected = done.version,
            .incompatible, .up_to_date, .superseded => |version| selected = version,
            .cancelled => {},
        }
    }
    if (available) |version| {
        const newer = if (selected) |installed| version.schema > installed.schema or (version.schema == installed.schema and version.patch > installed.patch) else true;
        if (newer) return .{ .text = std.fmt.bufPrint(buffer, "Update to {f}", .{version}) catch unreachable, .tone = .link, .enabled = true };
    }
    if (selected) |version| return .{ .text = std.fmt.bufPrint(buffer, "{f}", .{version}) catch unreachable, .tone = .quiet, .enabled = true };
    return .{ .text = current, .tone = .quiet, .enabled = true };
}

fn failedControl(reason: []const u8, buffer: *[max_line_bytes]u8) Control {
    return .{ .text = std.fmt.bufPrint(buffer, "Update failed: {s}", .{reason}) catch unreachable, .tone = .warning, .enabled = true, .fallback = "Update failed" };
}

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
                    writer.print("Preparing Upgrade {s} ", .{dot}) catch unreachable;
                    switch (install.found.host) {
                        .none => writer.writeAll("no Hosts running") catch unreachable,
                        .running => |count| writer.print("restarts every eligible Host ({d} found)", .{count}) catch unreachable,
                    }
                    writer.print(" {s} esc cancels", .{dot}) catch unreachable;
                },
                .publishing => writer.writeAll("Publishing; cancelling no longer rolls back") catch unreachable,
                .restarting => writer.print("Restarting Hosts{s}", .{ellipsis}) catch unreachable,
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
            .failed => |why| said: {
                writer.print("! {s}; nothing changed {s} {s}", .{ failure_words.get(why), dot, shell }) catch unreachable;
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

const failure_words = std.enums.EnumArray(Failure, []const u8).init(.{
    .download = "Couldn't reach GitHub",
    .release = "Upgrade failed",
    .other = "Upgrade failed",
});

pub fn relaunchLine(run: Run, buffer: *[max_line_bytes]u8, script: Script) []const u8 {
    const ending = if (run == .ended and run.ended.how == .incompatible)
        Run{ .ended = .{ .how = .{ .upgraded = .{ .version = run.ended.how.incompatible, .restarted = false } }, .outcome = run.ended.outcome } }
    else
        run;
    return line(ending, buffer, script).text;
}

const refusals = std.enums.EnumArray(Refusal, []const u8).init(.{
    .first_install = "no managed install",
    .source_build = "a source build",
    .unknown_build = "an unknown build",
    .package_managed = "installed by another tool",
});

comptime {
    const version = "0.4294967295.4294967295";
    std.debug.assert(("Preparing Upgrade · restarts every eligible Host (18446744073709551615 found) · esc cancels").len <= max_line_bytes);
    std.debug.assert(("Rui " ++ version ++ " installed · restart rui to continue · your draft is kept until you leave").len <= max_line_bytes);
    for (refusals.values) |why| std.debug.assert(("Can't upgrade here:  · run rui upgrade in a shell for details").len + why.len + 2 <= max_line_bytes);
}

test "a run's line: the check, what the restart will do, each step, and a stop" {
    for ([_]struct { Run, []const u8, bool }{
        .{ .checking, "Checking for updates…", true },
        .{ .{ .installing = .{ .found = .{ .host = .{ .running = 2 } } } }, "Preparing Upgrade · restarts every eligible Host (2 found) · esc cancels", true },
        .{ .{ .installing = .{ .found = .{ .host = .{ .running = 1 } } } }, "Preparing Upgrade · restarts every eligible Host (1 found) · esc cancels", true },
        .{ .{ .installing = .{ .found = .{ .host = .{ .running = 0 } } } }, "Preparing Upgrade · restarts every eligible Host (0 found) · esc cancels", true },
        .{ .{ .installing = .{ .found = .{ .host = .none } } }, "Preparing Upgrade · no Hosts running · esc cancels", true },
        .{ .{ .installing = .{ .found = .{ .host = .none }, .step = .publishing } }, "Publishing; cancelling no longer rolls back", false },
        .{ .{ .installing = .{ .found = .{ .host = .none }, .step = .restarting } }, "Restarting Hosts…", false },
        .{ .cancelling, "Cancelling…", true },
    }) |case| {
        var buffer: [max_line_bytes]u8 = undefined;
        const shown = line(case[0], &buffer, .unicode);
        try std.testing.expectEqualStrings(case[1], shown.text);
        try std.testing.expectEqual(Tone.normal, shown.tone);
        try std.testing.expectEqual(Lasts.until_done, shown.lasts);
        try std.testing.expect(case[0].going());
        try std.testing.expectEqual(case[2], case[0].takesEscape());
        if (case[0] != .cancelling and case[0] != .checking) try std.testing.expectEqual(case[2], std.mem.endsWith(u8, shown.text, "esc cancels"));
    }
}

test "how a run ended: a notice, or held until another Upgrade when the client cannot go on" {
    const v: Version = .{ .schema = 60, .patch = 1 };
    for ([_]struct { Ended, []const u8, Tone, Lasts }{
        .{ .{ .up_to_date = .{ .schema = 59, .patch = 7 } }, "Rui is up to date (0.59.7)", .normal, .notice },
        .{ .{ .superseded = .{ .schema = 61, .patch = 0 } }, "A newer Rui is already installed; nothing changed", .normal, .notice },
        .{ .{ .refused = .first_install }, "Can't upgrade here: no managed install · run rui upgrade in a shell for details", .attention, .notice },
        .{ .{ .refused = .source_build }, "Can't upgrade here: a source build · run rui upgrade in a shell for details", .attention, .notice },
        .{ .{ .refused = .unknown_build }, "Can't upgrade here: an unknown build · run rui upgrade in a shell for details", .attention, .notice },
        .{ .{ .refused = .package_managed }, "Can't upgrade here: installed by another tool · run rui upgrade in a shell for details", .attention, .notice },
        .{ .cancelled, "Upgrade cancelled; nothing changed", .normal, .notice },
        .{ .{ .failed = .download }, "! Couldn't reach GitHub; nothing changed · run rui upgrade in a shell for details", .attention, .notice },
        .{ .{ .failed = .release }, "! Upgrade failed; nothing changed · run rui upgrade in a shell for details", .attention, .notice },
        .{ .{ .failed = .other }, "! Upgrade failed; nothing changed · run rui upgrade in a shell for details", .attention, .notice },
        .{ .{ .upgraded = .{ .version = v, .restarted = true } }, "Upgraded to 0.60.1 · Host restarted", .normal, .notice },
        .{ .{ .upgraded = .{ .version = v, .restarted = false } }, "Upgraded to 0.60.1", .normal, .notice },
        .{ .{ .incompatible = .{ .schema = 61, .patch = 0 } }, "Rui 0.61.0 installed · restart rui to continue · your draft is kept until you leave", .attention, .persistent },
    }) |case| {
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
    try std.testing.expectEqualStrings("Preparing Upgrade - restarts every eligible Host (2 found) - esc cancels", line(.{ .installing = .{ .found = .{ .host = .{ .running = 2 } } } }, &buffer, .ascii).text);
}

/// The Settings Version row's tail: a run's own words while one shows,
/// otherwise the release the update offer names.
pub fn versionTail(run: ?Run, available: ?Version, buffer: *[max_line_bytes]u8) ?[]const u8 {
    if (run) |shown| return fieldTail(shown, buffer);
    const version = available orelse return null;
    return std.fmt.bufPrint(buffer, " · update to {f}", .{version}) catch unreachable;
}

test "SH-152 the Version row shows a run's own words while one shows, otherwise the offered release" {
    var buffer: [max_line_bytes]u8 = undefined;
    const offer: Version = .{ .schema = 80, .patch = 2 };
    const runs = [_]?Run{ null, .checking, .{ .ended = .{ .how = .{ .up_to_date = .{ .schema = 80, .patch = 1 } }, .outcome = .unchanged } }, .{ .ended = .{ .how = .cancelled, .outcome = .unchanged } } };
    for (runs) |run| for ([_]?Version{ null, offer }) |available| {
        var expected_buffer: [max_line_bytes]u8 = undefined;
        const expected: ?[]const u8 = if (run) |shown| fieldTail(shown, &expected_buffer) else if (available != null) " · update to 0.80.2" else null;
        const actual = versionTail(run, available, &buffer);
        if (expected) |text| try std.testing.expectEqualStrings(text, actual.?) else try std.testing.expect(actual == null);
    };
}

pub fn fieldTail(run: Run, buffer: *[max_line_bytes]u8) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    const text: []const u8 = switch (run) {
        .checking => " · checking for updates…",
        .cancelling => " · cancelling…",
        .installing => |install| switch (install.step) {
            .preparing => " · preparing Upgrade…",
            .publishing => " · publishing…",
            .restarting => " · restarting Hosts…",
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
            .failed => |why| switch (why) {
                .download => " · couldn't reach GitHub",
                .release, .other => " · upgrade failed",
            },
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
    const found: Found = .{ .host = .none };
    try std.testing.expectEqualStrings(" · preparing Upgrade…", fieldTail(.{ .installing = .{ .found = found } }, &buffer));
    try std.testing.expectEqualStrings(" · publishing…", fieldTail(.{ .installing = .{ .found = found, .step = .publishing } }, &buffer));
    try std.testing.expectEqualStrings(" · restarting Hosts…", fieldTail(.{ .installing = .{ .found = found, .step = .restarting } }, &buffer));
    for ([_]struct { Failure, []const u8 }{
        .{ .download, " · couldn't reach GitHub" },
        .{ .release, " · upgrade failed" },
        .{ .other, " · upgrade failed" },
    }) |case| try std.testing.expectEqualStrings(case[1], fieldTail(.{ .ended = .{ .how = .{ .failed = case[0] }, .outcome = .unchanged } }, &buffer));
    const endings = [_]Ended{
        .{ .up_to_date = .{ .schema = 60, .patch = 0 } },
        .{ .superseded = .{ .schema = 61, .patch = 0 } },
        .{ .refused = .first_install },
        .{ .refused = .source_build },
        .{ .refused = .unknown_build },
        .{ .refused = .package_managed },
        .cancelled,
        .{ .failed = .other },
        .{ .upgraded = .{ .version = Version{ .schema = 61, .patch = 0 }, .restarted = true } },
        .{ .incompatible = Version{ .schema = 61, .patch = 0 } },
    };
    for (endings) |ending| {
        const text = fieldTail(.{ .ended = .{ .how = ending, .outcome = .unchanged } }, &buffer);
        try std.testing.expect(std.mem.startsWith(u8, text, " · "));
        try std.testing.expect(std.mem.indexOf(u8, text, "shell") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "esc") == null);
    }
}

test "relaunch ending removes old-client restart instructions only in the new client" {
    var buffer: [max_line_bytes]u8 = undefined;
    const incompatible: Run = .{ .ended = .{ .how = .{ .incompatible = .{ .schema = 60, .patch = 0 } }, .outcome = .incompatible } };
    try std.testing.expectEqualStrings("Upgraded to 0.60.0", relaunchLine(incompatible, &buffer, .unicode));
    try std.testing.expect(std.mem.indexOf(u8, line(incompatible, &buffer, .unicode).text, "restart rui") != null);
    const compatible: Run = .{ .ended = .{ .how = .{ .upgraded = .{ .version = .{ .schema = 60, .patch = 0 }, .restarted = true } }, .outcome = .compatible } };
    try std.testing.expectEqualStrings("Upgraded to 0.60.0 · Host restarted", relaunchLine(compatible, &buffer, .unicode));
}

test "relaunch ending preserves every failure reason without a success line" {
    var buffer: [max_line_bytes]u8 = undefined;
    inline for (std.enums.values(Failure)) |failure| {
        const run: Run = .{ .ended = .{ .how = .{ .failed = failure }, .outcome = .unchanged } };
        var ordinary_buffer: [max_line_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(line(run, &ordinary_buffer, .unicode).text, relaunchLine(run, &buffer, .unicode));
    }
    const download: Run = .{ .ended = .{ .how = .{ .failed = .download }, .outcome = .unchanged } };
    try std.testing.expectEqualStrings("! Couldn't reach GitHub; nothing changed · run rui upgrade in a shell for details", relaunchLine(download, &buffer, .unicode));
}

test "update control spans every run outcome and available state" {
    var buffer: [max_line_bytes]u8 = undefined;
    const version: Version = .{ .schema = 76, .patch = 0 };
    const outcomes = [_]Ended{ .{ .up_to_date = version }, .{ .superseded = version }, .{ .refused = .source_build }, .cancelled, .{ .failed = .download }, .{ .upgraded = .{ .version = version, .restarted = true } }, .{ .incompatible = version } };
    for ([_]?Version{ null, version }) |available| for (std.enums.values(Script)) |script| {
        const idle = control("0.75.1", available, null, &buffer, script);
        try std.testing.expectEqualStrings(if (available != null) "Update to 0.76.0" else "0.75.1", idle.text);
        try std.testing.expect(idle.enabled);
        for ([_]Run{ .checking, .cancelling, .{ .installing = .{ .found = .{ .host = .none } } } }) |run| {
            const busy = control("0.75.1", available, run, &buffer, script);
            try std.testing.expect(!busy.enabled and busy.tone == .quiet);
            try std.testing.expectEqualStrings(if (script == .unicode) "Updating…" else "Updating...", busy.text);
        }
        for (outcomes) |how| {
            const ended = control("0.75.1", available, .{ .ended = .{ .how = how, .outcome = .unchanged } }, &buffer, script);
            try std.testing.expect(ended.enabled);
            switch (how) {
                .failed, .refused => {
                    try std.testing.expectEqualStrings(if (how == .failed) "Update failed: Couldn't reach GitHub" else "Update failed: a source build", ended.text);
                    try std.testing.expect(ended.tone == .warning);
                },
                .upgraded, .up_to_date, .incompatible, .superseded => {
                    try std.testing.expectEqualStrings("0.76.0", ended.text);
                    try std.testing.expect(ended.tone == .quiet);
                },
                .cancelled => try std.testing.expectEqualStrings(if (available != null) "Update to 0.76.0" else "0.75.1", ended.text),
            }
        }
    };
}

test "completed update control retains selected receipt version until a newer release is available" {
    var buffer: [max_line_bytes]u8 = undefined;
    const selected: Version = .{ .schema = 76, .patch = 0 };
    const endings = [_]Ended{
        .{ .up_to_date = selected },
        .{ .superseded = selected },
        .{ .upgraded = .{ .version = selected, .restarted = true } },
        .{ .incompatible = selected },
    };
    const releases = [_]?Version{ null, .{ .schema = 75, .patch = 9 }, selected, .{ .schema = 76, .patch = 1 }, .{ .schema = 77, .patch = 0 } };
    for (endings) |how| for (std.enums.values(Outcome)) |outcome| for (std.enums.values(Script)) |script| for (releases, 0..) |available, index| {
        const shown = control("0.75.1", available, .{ .ended = .{ .how = how, .outcome = outcome } }, &buffer, script);
        try std.testing.expectEqualStrings(switch (index) {
            0, 1, 2 => "0.76.0",
            3 => "Update to 0.76.1",
            else => "Update to 0.77.0",
        }, shown.text);
        try std.testing.expectEqual(index >= 3, shown.tone == .link);
        try std.testing.expect(shown.enabled);
    };
}

test "failed update controls preserve owner reasons and fit to retry across widths" {
    const Case = struct { how: Ended, text: []const u8 };
    const cases = [_]Case{
        .{ .how = .{ .failed = .download }, .text = "Update failed: Couldn't reach GitHub" },
        .{ .how = .{ .failed = .release }, .text = "Update failed: Upgrade failed" },
        .{ .how = .{ .failed = .other }, .text = "Update failed: Upgrade failed" },
        .{ .how = .{ .refused = .first_install }, .text = "Update failed: no managed install" },
        .{ .how = .{ .refused = .source_build }, .text = "Update failed: a source build" },
        .{ .how = .{ .refused = .unknown_build }, .text = "Update failed: an unknown build" },
        .{ .how = .{ .refused = .package_managed }, .text = "Update failed: installed by another tool" },
    };
    var buffer: [max_line_bytes]u8 = undefined;
    for (cases) |case| for (std.enums.values(Script)) |script| for (0..80) |width| {
        const shown = control("0.75.1", null, .{ .ended = .{ .how = case.how, .outcome = .unchanged } }, &buffer, script).fit(width);
        try std.testing.expectEqualStrings(if (width >= case.text.len) case.text else "Update failed", shown.text);
        try std.testing.expect(shown.enabled and shown.tone == .warning);
    };
}
