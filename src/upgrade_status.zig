//! Inline /upgrade: where an Upgrade run stands and what the status bar
//! says about it, on the overview and in a conversation alike. Values in,
//! words out; the shell runs the check and the install and reports each
//! step. Whether Host requests wait is `session_upgrade`'s decision.

const std = @import("std");
const session_upgrade = @import("session_upgrade.zig");

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

/// What the worker reports of a run, in the order it happens.
pub const News = union(enum) {
    found: Found,
    step: Step,
    /// How it ended, as the status bar says it, and what it leaves Host
    /// requests: the run's own outcome, never read back from the words.
    ended: struct { how: Ended, outcome: session_upgrade.Outcome },
};

pub const State = union(enum) {
    idle,
    checking: struct { cancelling: bool = false },
    installing: struct { found: Found, step: Step = .preparing, cancelling: bool = false },
    ended: Ended,
};

pub const Tone = enum { normal, attention };

/// How long the status bar keeps a line: while the run goes on, as a
/// notice (until the next key or about 5 s), or until another /upgrade.
pub const Lasts = enum { until_done, notice, persistent };

pub const Line = struct { text: []const u8, tone: Tone, lasts: Lasts };

pub const Script = enum { unicode, ascii };

/// Bytes the longest line takes.
pub const max_line_bytes = 160;

pub const Upgrade = struct {
    state: State = .idle,

    /// /upgrade: check again, replacing whatever the last run left.
    pub fn begin(self: *Upgrade) void {
        self.state = .{ .checking = .{} };
    }

    /// The check found a release it may install, which starts at once,
    /// unless Esc cancelled the check.
    pub fn found(self: *Upgrade, release: Found) void {
        if (self.state != .checking or self.state.checking.cancelling) return;
        self.state = .{ .installing = .{ .found = release } };
    }

    /// The install moved on. Steps only move forward.
    pub fn step(self: *Upgrade, next: Step) void {
        switch (self.state) {
            .installing => |*install| if (@backingInt(next) > @backingInt(install.step)) {
                install.step = next;
                // The run published before Esc reached it; the worker
                // refused that cancel, so the row says what happens.
                install.cancelling = false;
            },
            else => {},
        }
    }

    pub fn ended(self: *Upgrade, how: Ended) void {
        switch (self.state) {
            .checking, .installing => self.state = .{ .ended = how },
            .idle, .ended => {},
        }
    }

    /// Esc: taken while the run can still change nothing, checking or
    /// preparing, which it asks for; the shell cancels the worker when this
    /// returns true. Otherwise Esc is the screen's.
    pub fn escape(self: *Upgrade) bool {
        switch (self.state) {
            .checking => |*check| {
                check.cancelling = true;
                return true;
            },
            .installing => |*install| {
                if (install.step != .preparing) return false;
                install.cancelling = true;
                return true;
            },
            else => return false,
        }
    }

    /// What the status bar says, or null before the first /upgrade.
    pub fn line(self: *const Upgrade, buffer: *[max_line_bytes]u8, script: Script) ?Line {
        const dot = if (script == .unicode) "·" else "-";
        const ellipsis = if (script == .unicode) "…" else "...";
        const shell = "run rui upgrade in a shell for details";
        var writer = std.Io.Writer.fixed(buffer);
        const said: struct { Tone, Lasts } = switch (self.state) {
            .idle => return null,
            .checking => |check| said: {
                writer.print("{s}{s}", .{ if (check.cancelling) "Cancelling" else "Checking for updates", ellipsis }) catch unreachable;
                break :said .{ .normal, .until_done };
            },
            .installing => |install| said: {
                if (install.cancelling) {
                    writer.print("Cancelling{s}", .{ellipsis}) catch unreachable;
                } else switch (install.step) {
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
            .ended => |how| switch (how) {
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
};

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

test "a found release installs at once, saying what the restart will do, and Esc cancels only until publishing" {
    var run: Upgrade = .{};
    var buffer: [max_line_bytes]u8 = undefined;
    run.begin();
    try expectLine(&run, &buffer, "Checking for updates…", .normal, .until_done);

    run.found(.{ .version = .{ .schema = 60, .patch = 0 }, .host = .{ .running = 2 } });
    try expectLine(&run, &buffer, "Upgrading to 0.60.0 · restarts the Host (2 Sessions working) · esc cancels", .normal, .until_done);
    // Esc is taken while it can still roll back, and says so.
    try std.testing.expect(run.escape());
    try expectLine(&run, &buffer, "Cancelling…", .normal, .until_done);
    try std.testing.expect(run.escape());
    run.ended(.cancelled);
    try expectLine(&run, &buffer, "Upgrade cancelled; nothing changed", .normal, .notice);
    // Once ended, Esc is the screen's again.
    try std.testing.expect(!run.escape());

    run.begin();
    run.found(.{ .version = .{ .schema = 60, .patch = 1 }, .host = .{ .running = 1 } });
    try expectLine(&run, &buffer, "Upgrading to 0.60.1 · restarts the Host (1 Session working) · esc cancels", .normal, .until_done);
    run.step(.publishing);
    try expectLine(&run, &buffer, "Publishing; cancelling no longer rolls back", .normal, .until_done);
    // Esc while preparing, but the worker published first: the row says
    // what happened, not the cancel it refused.
    var raced: Upgrade = .{};
    raced.begin();
    raced.found(.{ .version = .{ .schema = 60, .patch = 0 }, .host = .none });
    try std.testing.expect(raced.escape());
    raced.step(.publishing);
    try expectLine(&raced, &buffer, "Publishing; cancelling no longer rolls back", .normal, .until_done);
    try std.testing.expect(!run.escape());
    run.step(.restarting);
    try expectLine(&run, &buffer, "Restarting the Host…", .normal, .until_done);
    try std.testing.expect(!run.escape());
    run.ended(.{ .upgraded = .{ .version = .{ .schema = 60, .patch = 1 }, .restarted = true } });
    try expectLine(&run, &buffer, "Upgraded to 0.60.1 · Host restarted", .normal, .notice);
}

test "Esc during the check cancels it: a release found after installs nothing, and it ends cancelled" {
    var run: Upgrade = .{};
    var buffer: [max_line_bytes]u8 = undefined;
    run.begin();
    try std.testing.expect(run.escape());
    try expectLine(&run, &buffer, "Cancelling…", .normal, .until_done);
    // A second Esc is still the Upgrade's while it winds down.
    try std.testing.expect(run.escape());
    // The check may finish before it hears the cancel; nothing installs.
    run.found(.{ .version = .{ .schema = 60, .patch = 0 }, .host = .none });
    try expectLine(&run, &buffer, "Cancelling…", .normal, .until_done);
    run.ended(.cancelled);
    try expectLine(&run, &buffer, "Upgrade cancelled; nothing changed", .normal, .notice);
    try std.testing.expect(!run.escape());
}

test "with nothing working or no Host, the first line says so" {
    var run: Upgrade = .{};
    var buffer: [max_line_bytes]u8 = undefined;
    run.begin();
    run.found(.{ .version = .{ .schema = 60, .patch = 0 }, .host = .{ .running = 0 } });
    try expectLine(&run, &buffer, "Upgrading to 0.60.0 · restarts the Host · esc cancels", .normal, .until_done);
    run.begin();
    run.found(.{ .version = .{ .schema = 60, .patch = 0 }, .host = .none });
    try expectLine(&run, &buffer, "Upgrading to 0.60.0 · no Host running · esc cancels", .normal, .until_done);
    run.step(.publishing);
    run.ended(.{ .upgraded = .{ .version = .{ .schema = 60, .patch = 0 }, .restarted = false } });
    try expectLine(&run, &buffer, "Upgraded to 0.60.0", .normal, .notice);
}

test "a check that installs nothing ends as a notice: up to date, superseded, refused or failed" {
    var buffer: [max_line_bytes]u8 = undefined;
    for ([_]struct { Ended, []const u8, Tone }{
        .{ .{ .up_to_date = .{ .schema = 59, .patch = 7 } }, "Rui is up to date (0.59.7)", .normal },
        // Another install selected a newer build: no version of ours to name.
        .{ .superseded, "A newer Rui is already installed; nothing changed", .normal },
        .{ .{ .refused = .first_install }, "Can't upgrade here: no managed install · run rui upgrade in a shell for details", .attention },
        .{ .{ .refused = .source_build }, "Can't upgrade here: a source build · run rui upgrade in a shell for details", .attention },
        .{ .{ .refused = .unknown_build }, "Can't upgrade here: an unknown build · run rui upgrade in a shell for details", .attention },
        .{ .{ .refused = .package_managed }, "Can't upgrade here: installed by another tool · run rui upgrade in a shell for details", .attention },
        .{ .failed, "! Upgrade failed; nothing changed · run rui upgrade in a shell for details", .attention },
    }) |case| {
        var run: Upgrade = .{};
        run.begin();
        run.ended(case[0]);
        try expectLine(&run, &buffer, case[1], case[2], .notice);
    }
}

test "a release the running client cannot use stays on the status bar until another /upgrade" {
    var run: Upgrade = .{};
    var buffer: [max_line_bytes]u8 = undefined;
    run.begin();
    run.found(.{ .version = .{ .schema = 61, .patch = 0 }, .host = .{ .running = 3 } });
    run.step(.publishing);
    run.step(.restarting);
    run.ended(.{ .incompatible = .{ .schema = 61, .patch = 0 } });
    try expectLine(&run, &buffer, "Rui 0.61.0 installed · restart rui to continue · your draft is kept until you leave", .attention, .persistent);
    // A new /upgrade replaces it.
    run.begin();
    try expectLine(&run, &buffer, "Checking for updates…", .normal, .until_done);
}

test "nothing shows before the first /upgrade, and ASCII spells the ellipsis and dot" {
    var run: Upgrade = .{};
    var buffer: [max_line_bytes]u8 = undefined;
    try std.testing.expectEqual(null, run.line(&buffer, .unicode));
    run.begin();
    try std.testing.expectEqualStrings("Checking for updates...", run.line(&buffer, .ascii).?.text);
    run.found(.{ .version = .{ .schema = 60, .patch = 0 }, .host = .{ .running = 2 } });
    try std.testing.expectEqualStrings("Upgrading to 0.60.0 - restarts the Host (2 Sessions working) - esc cancels", run.line(&buffer, .ascii).?.text);
}

test "a step or an end that arrives out of turn changes nothing" {
    var run: Upgrade = .{};
    run.step(.publishing);
    run.ended(.cancelled);
    try std.testing.expectEqual(Upgrade{}, run);
    run.begin();
    // No step before a release is found.
    run.step(.restarting);
    try std.testing.expectEqual(Upgrade{ .state = .{ .checking = .{} } }, run);
    run.found(.{ .version = .{ .schema = 60, .patch = 0 }, .host = .none });
    run.step(.restarting);
    // Steps only move forward.
    run.step(.publishing);
    try std.testing.expectEqual(Step.restarting, run.state.installing.step);
}

fn expectLine(run: *const Upgrade, buffer: *[max_line_bytes]u8, text: []const u8, tone: Tone, lasts: Lasts) !void {
    const shown = run.line(buffer, .unicode).?;
    try std.testing.expectEqualStrings(text, shown.text);
    try std.testing.expectEqual(tone, shown.tone);
    try std.testing.expectEqual(lasts, shown.lasts);
}
