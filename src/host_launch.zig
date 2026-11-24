const std = @import("std");
const start_report = @import("start_report.zig");
const protocol = @import("protocol.zig");
const protocol_reply = @import("protocol_reply.zig");
const HostStartupWait = @import("HostStartupWait.zig");
const TerminalText = @import("TerminalText.zig");
const activation = @import("host_activation.zig");

pub const Summary = union(enum) {
    ready: void,
    failed: Failure,

    pub const Next = enum {
        start,
        retry,

        pub fn label(self: Summary.Next) []const u8 {
            return switch (self) {
                .start => "r start",
                .retry => "r retry",
            };
        }
    };
    pub const Failure = struct {
        kind: Kind,
        err: anyerror,
        refusal_code: ?start_report.StartError = null,
        handover_words: ?[]const u8 = null,

        pub const Kind = enum { setup, worker, os_launch, child_refused, child_closed, startup_full, readiness_timeout, incompatible, store_access, store_identity, mysql_unavailable, interrupted, provider_unserved, store_format };

        pub fn words(self: Failure) []const u8 {
            if (self.handover_words) |words_for_handover| return words_for_handover;
            return switch (self.kind) {
                .setup, .worker, .os_launch => "could not start",
                .child_refused => "refused to start",
                .child_closed => "quit on start",
                .startup_full => "start unconfirmed",
                .readiness_timeout => "start timed out",
                .incompatible => "different Rui version",
                .store_access => "can't read Store",
                .store_identity => "not the same Store",
                .mysql_unavailable => "can't start from here",
                .interrupted => "start interrupted",
                .provider_unserved => "does not serve this provider",
                .store_format => "needs a compatible Rui",
            };
        }

        pub fn next(self: Failure) ?Summary.Next {
            return switch (self.kind) {
                .incompatible, .store_identity, .mysql_unavailable, .provider_unserved, .store_format => null,
                else => .retry,
            };
        }
    };
    pub fn words(self: Summary) []const u8 {
        return switch (self) {
            .ready => "",
            .failed => |failure| failure.words(),
        };
    }
};

pub const Result = struct {
    outcome: union(enum) { ready: Ready, failed: Failure },
    startup_bytes: [max_startup_bytes]u8 = undefined,
    startup_len: usize = 0,
    wait: ?HostStartupWait = null,

    pub const max_startup_bytes = 8192;
    pub const Cause = Summary.Failure;
    pub const Ready = struct {
        facts: protocol_reply.HostInfoFacts,
        selector: @import("host_settings.zig").OsBytes(protocol.max_store_bytes) = .{ .len = 0 },
        diagnostics_directory: @import("host_settings.zig").OsBytes(protocol.max_store_bytes) = .{ .len = 0 },
        /// The serving Host was already running or won a launch race, so it
        /// did not start with this command's settings.
        adopted: bool = false,
    };
    pub const Failure = struct {
        cause: Cause,
        store: protocol.Bounded(protocol.max_store_bytes) = .{ .len = 0 },
        os_error: ?c_int = null,
        detail: Detail = .none,

        pub const Detail = union(enum) { none, refusal: start_report.Failure, handover: activation.Selected };
        pub const RefusalView = struct { failure: *const start_report.Failure, attempt: start_report.Attempt };

        pub fn refusalView(self: *const Failure) ?RefusalView {
            return switch (self.detail) {
                .none => null,
                .refusal => |*refusal| .{ .failure = refusal, .attempt = .start },
                .handover => |*selected| switch (selected.*) {
                    .outcome => |*outcome| switch (outcome.*) {
                        .refused => |*refusal| .{ .failure = &refusal.failure, .attempt = if (refusal.stage == .checking) .check else .start },
                        else => null,
                    },
                    .failed => null,
                },
            };
        }
    };

    pub fn failed(kind: Cause.Kind, err: anyerror) Result {
        return .{ .outcome = .{ .failed = .{ .cause = .{ .kind = kind, .err = err }, .store = .{ .len = 0 } } } };
    }

    pub fn summary(self: *const Result) Summary {
        return switch (self.outcome) {
            .ready => .{ .ready = {} },
            .failed => |failure| failed: {
                var cause = failure.cause;
                switch (failure.detail) {
                    .handover => |selected| cause.handover_words = activation.selectedWords(selected),
                    else => {},
                }
                break :failed .{ .failed = cause };
            },
        };
    }

    pub fn startup(self: *const Result) []const u8 {
        return self.startup_bytes[0..self.startup_len];
    }
};

pub fn writeSentence(writer: *std.Io.Writer, attempt: start_report.Attempt, failure: *const start_report.Failure) !void {
    const prefix = switch (attempt) {
        .start => "the Host did not start",
        .save => "the setting was not saved",
        .check => "these settings would not start a Host",
    };
    try writer.print("rui: {s}: {f} [{s}]\n", .{ prefix, std.zig.fmtString(failure.message.slice()), @tagName(failure.code) });
}

pub const max_report_bytes = 4 * protocol.max_store_bytes + Result.max_startup_bytes + 2048;

pub fn writeDiagnostics(result: *const Result, writer: *std.Io.Writer, shown: usize) !void {
    switch (result.outcome) {
        .ready => {
            if (result.startup_len != 0) try writer.writeAll(result.startup()[shown..]);
        },
        .failed => |*failure| {
            if (failure.detail == .handover) {
                const report = @import("host_restart_report.zig");
                if (failure.refusalView()) |refusal| {
                    try writeSentence(writer, refusal.attempt, refusal.failure);
                } else switch (failure.detail.handover) {
                    .outcome => |outcome| _ = try report.writeOutcome(writer, failure.store.slice(), outcome, null),
                    .failed => |entry| try report.writeFailure(writer, failure.store.slice(), entry),
                }
                return;
            }
            switch (failure.cause.kind) {
                .os_launch => {
                    try writer.print("\nrui: detached Host launch reported OS error {d}. Execution and readiness are unconfirmed.\nCheck this Store: rui host status --store ", .{failure.os_error.?});
                    try TerminalText.writeShellWord(writer, failure.store.slice());
                    try writer.writeByte('\n');
                },
                .child_refused, .child_closed, .startup_full, .store_identity, .store_format => {
                    try writer.writeAll("\nrui: detached Host startup failed for Store ");
                    var path_text: TerminalText = .{ .mode = .line };
                    try path_text.feed(writer, failure.store.slice());
                    try path_text.finish(writer);
                    try writer.writeAll(":\n");
                    try writer.writeAll(result.startup()[shown..]);
                    if (result.startup_len == 0) if (failure.refusalView()) |refusal| try writeSentence(writer, refusal.attempt, refusal.failure);
                    if (failure.cause.kind == .child_closed) try writer.writeAll("Child closed its startup channel before readiness; exit status unavailable.\n");
                    if (failure.cause.kind == .startup_full) try writer.writeAll("Startup output reached 8 KiB; readiness and exit status remain unconfirmed.\n");
                },
                .readiness_timeout => {
                    if (result.startup_len != 0) try writer.writeAll(result.startup()[shown..]);
                    try writer.writeAll("rui: Host readiness unconfirmed after 10 seconds. Inspect rui host status and the selected Store's diagnostics/ startup records if present; do not kill or reclaim an uncertain owner.\n");
                },
                .incompatible => try writer.writeAll("rui: the Host serving this Store does not speak this rui's protocol. Run rui host restart --all to hand over eligible managed Hosts, and follow its per-Host instructions.\n"),
                .provider_unserved => try writer.writeAll("rui: the Host serving this Store does not serve the selected provider. Pause it with rui host pause, then start a Host serving that provider, or select a provider it serves; saved work is unchanged.\n"),
                .setup, .worker, .store_access, .mysql_unavailable, .interrupted => {},
            }
        },
    }
}

pub fn writeSignIn(writer: *std.Io.Writer, summary: Summary, default_failed: bool, retry_hint: bool) !void {
    try writer.writeAll("Sign-in saved");
    if (default_failed) try writer.writeAll("; default not saved");
    switch (summary) {
        .ready => {},
        .failed => |failure| {
            try writer.print("; Host {s}", .{failure.words()});
            if (retry_hint and failure.next() != null) try writer.writeAll(" · enter tries again");
        },
    }
}

pub fn failureOf(err: anyerror) Summary.Failure {
    return .{ .err = err, .kind = switch (err) {
        error.HostModelUnavailable => .provider_unserved,
        error.HostReadinessUnconfirmed => .readiness_timeout,
        error.IncompatibleHost => .incompatible,
        error.StoreAccessFailed => .store_access,
        error.MysqlHostUnavailable => .mysql_unavailable,
        else => .setup,
    } };
}
