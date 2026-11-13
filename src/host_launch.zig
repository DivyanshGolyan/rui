//! A settled Host launch and its reporting policy. Terminal adapters keep
//! the complete transcript and context; screens borrow one safe semantic line.
const std = @import("std");
const start_report = @import("start_report.zig");
const protocol = @import("protocol.zig");
const protocol_reply = @import("protocol_reply.zig");
const HostStartupWait = @import("HostStartupWait.zig");
const TerminalText = @import("TerminalText.zig");
pub const invalid_base_url = "rui: " ++ @import("providers.zig").openai_base_url_variable ++ " must be an https:// URL with a host and no credentials, query or fragment";

/// The screen's semantic projection of the shared launch result. It owns no
/// terminal receipt or child bytes; kind, words and next action stay together.
pub const Summary = union(enum) {
    ready: ?Warning,
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
        /// Terminal exit classification is retained, never shown as UI text.
        err: anyerror,
        refusal_code: ?start_report.StartError = null,

        pub const Kind = enum { setup, worker, os_launch, child_refused, child_closed, startup_full, readiness_timeout, incompatible, store_access, store_identity, mysql_unavailable, interrupted, provider_unserved, store_format };

        pub fn words(self: Failure) []const u8 {
            return switch (self.kind) {
                // The person can only retry these three, so they read alike.
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
    pub const Warning = enum {
        invalid_openai_base_url,

        pub fn words(_: Warning) []const u8 {
            return "OpenAI URL invalid";
        }
    };

    pub fn words(self: Summary) []const u8 {
        return switch (self) {
            .ready => |warning| if (warning) |value| value.words() else "",
            .failed => |failure| failure.words(),
        };
    }
};

pub const Result = struct {
    outcome: union(enum) { ready: Ready, failed: Failure },
    warning: ?Summary.Warning = null,
    startup_bytes: [max_startup_bytes]u8 = undefined,
    startup_len: usize = 0,
    wait: ?HostStartupWait = null,

    pub const max_startup_bytes = 8192;
    pub const Cause = Summary.Failure;
    pub const Ready = struct {
        facts: protocol_reply.HostInfoFacts,
        diagnostics_directory: protocol.Bounded(protocol.max_store_bytes) = .{ .len = 0 },
    };
    pub const Failure = struct {
        cause: Cause,
        store: protocol.Bounded(protocol.max_store_bytes) = .{ .len = 0 },
        os_error: ?c_int = null,
        refusal: ?start_report.Failure = null,
    };

    pub fn failed(kind: Cause.Kind, err: anyerror) Result {
        return .{ .outcome = .{ .failed = .{ .cause = .{ .kind = kind, .err = err }, .store = .{ .len = 0 } } } };
    }

    pub fn summary(self: *const Result) Summary {
        return switch (self.outcome) {
            .ready => .{ .ready = self.warning },
            .failed => |failure| .{ .failed = failure.cause },
        };
    }

    pub fn startup(self: *const Result) []const u8 {
        return self.startup_bytes[0..self.startup_len];
    }
};

/// Enough for a full startup transcript, escaped Store context and guidance.
/// There is one bounded transcript per launch, not one per screen row.
pub const max_report_bytes = 4 * protocol.max_store_bytes + Result.max_startup_bytes + 2048;

/// The detailed terminal presentation, shared by shell launch and departure
/// after screen restoration. No output or terminal custody is acquired here.
pub fn writeDiagnostics(result: *const Result, writer: *std.Io.Writer, shown: usize) !void {
    // The child states the same warning in its transcript; show it once.
    if (result.warning != null and std.mem.indexOf(u8, result.startup(), invalid_base_url) == null) try writer.writeAll(invalid_base_url ++ "; this Host starts without OpenAI.\n");
    switch (result.outcome) {
        .ready => {
            if (result.startup_len != 0) try writer.writeAll(result.startup()[shown..]);
        },
        .failed => |*failure| switch (failure.cause.kind) {
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
                if (result.startup_len == 0) if (failure.refusal) |*refusal| try writer.print("rui: the Host did not start: {f} [{s}]\n", .{ std.zig.fmtString(refusal.message.slice()), @tagName(refusal.code) });
                if (failure.cause.kind == .child_closed) try writer.writeAll("Child closed its startup channel before readiness; exit status unavailable.\n");
                if (failure.cause.kind == .startup_full) try writer.writeAll("Startup output reached 8 KiB; readiness and exit status remain unconfirmed.\n");
            },
            .readiness_timeout => {
                if (result.startup_len != 0) try writer.writeAll(result.startup()[shown..]);
                try writer.writeAll("rui: Host readiness unconfirmed after 10 seconds. Inspect rui host status and the selected Store's diagnostics/ startup records if present; do not kill or reclaim an uncertain owner.\n");
            },
            .incompatible => try writer.writeAll("rui: the Host serving this Store does not speak this rui's protocol, usually because another Rui version started it. Stop it with that version's rui host pause (rui host stop in older versions), then run this rui again; saved work is unchanged.\n"),
            .provider_unserved => try writer.writeAll("rui: the Host serving this Store does not serve the selected provider. Pause it with rui host pause, then start a Host serving that provider, or select a provider it serves; saved work is unchanged.\n"),
            .setup, .worker, .store_access, .mysql_unavailable, .interrupted => {},
        },
    }
}

/// One plain input-row line. Neither child bytes nor paths are screen text.
/// The same next-action policy supplies the overview and sign-in retry hint.
pub fn writeSignIn(writer: *std.Io.Writer, summary: Summary, default_failed: bool, retry_hint: bool) !void {
    try writer.writeAll("Sign-in saved");
    if (default_failed) try writer.writeAll("; default not saved");
    switch (summary) {
        .ready => |warning| if (warning) |value| try writer.print("; {s}", .{value.words()}),
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
