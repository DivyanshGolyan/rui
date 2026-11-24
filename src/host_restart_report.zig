const std = @import("std");
const client = @import("client.zig");
const activation = @import("host_activation.zig");
const release = @import("release_candidate.zig");
const TerminalText = @import("TerminalText.zig");

pub fn field(writer: *std.Io.Writer, text: []const u8) !void {
    var terminal: TerminalText = .{ .mode = .line };
    try terminal.feed(writer, text);
    try terminal.finish(writer);
}

pub fn writeOutcome(writer: *std.Io.Writer, store: []const u8, outcome: activation.Outcome, version: ?release.Version) !activation.Category {
    if (store.len == 0) {
        try writer.writeAll("Host handover: ");
    } else {
        try field(writer, store);
        try writer.writeAll(": ");
    }
    switch (outcome) {
        .ready => {
            if (version) |v| try writer.print("restarted on 0.{d}.{d}", .{ v.schema, v.patch }) else try writer.writeAll("restarted");
        },
        .client_incompatible => {
            // The lifecycle verified a new instance and answering target
            // release, but this client's protocol cannot read ordinary replies.
            if (version) |v| try writer.print("restarted on 0.{d}.{d}; different Host protocol; inspect with the selected Rui client", .{ v.schema, v.patch }) else try writer.writeAll("restarted with a different Host protocol; inspect with the selected Rui client");
        },
        .already_ready => {
            if (version) |v| try writer.print("already on 0.{d}.{d}", .{ v.schema, v.patch }) else try writer.writeAll("already on the selected build");
        },
        .superseded => {
            if (version) |v| try writer.print("left running: newer than 0.{d}.{d}; no downgrade", .{ v.schema, v.patch }) else try writer.writeAll("left running: newer than the selected build; no downgrade");
        },
        .not_needed => {
            try writer.writeAll("no longer running; no Host started");
        },
        .unsupported => |limitation| {
            try writer.print("left running: {s}", .{switch (limitation) {
                .inaccessible => "Store or Host is inaccessible; check access with its owning client",
                .incompatible => "Host protocol is unsupported; use its owning client",
                .ownership_status => "ownership is unconfirmed; do not stop a guessed Host (Host status unavailable while owned)",
                .ownership_observation => "ownership is unconfirmed; do not stop a guessed Host (initial Host observation failed)",
                .ownership_directory_unavailable => "ownership is unconfirmed; do not stop a guessed Host (Host directory could not be canonicalized)",
                .ownership_directory_mismatch => "ownership is unconfirmed; do not stop a guessed Host (Host directories differ)",
                .ownership_confirmation => "ownership is unconfirmed; do not stop a guessed Host (Host identity confirmation failed)",
                .application_owned => "application-owned Host (including MySQL); restart through its application",
                .configuration_unavailable => "launch configuration cannot be safely reconstructed; restart through its owner",
                .target_capability => "target build cannot safely check a detached restart; Host left running",
                .not_start_eligible => "not eligible for an ordinary start on this build; Host left running",
            }});
        },
        .replacement_observed => {
            try writer.writeAll("failed at verifying: a replacement Host was observed; inspect with its owning client, then retry");
        },
        .cancelled => {
            try writer.writeAll("failed at activation: cancelled; inspect Host status, then retry");
        },
        .faulted => |fault| {
            if (fault.effect.stage()) |stage| {
                try writer.print("failed at {s}: restart is unconfirmed during {s} ({s}); inspect Host status with its owning client, then retry", .{ @tagName(stage), @tagName(fault.effect), fault.cause.slice() });
            } else {
                try writer.print("failed during {s} ({s}); Host left running; inspect with its owning client, then retry", .{ @tagName(fault.effect), fault.cause.slice() });
            }
        },
        .target_unusable => |step| {
            const doing: []const u8 = switch (step) {
                .resolving => "resolving the target",
                .checking => "checking the target",
            };
            const done: []const u8 = switch (step) {
                .resolving => "resolved",
                .checking => "checked",
            };
            try writer.print("failed at {s}: the target build could not be {s}; Host left running; check the installation, then retry", .{ doing, done });
        },
        .refused => |refusal| {
            try writer.print("refused at {s}\n", .{@tagName(refusal.stage)});
            var line: [@import("start_report.zig").max_line_bytes]u8 = undefined;
            try writer.writeAll(@import("start_report.zig").line(&refusal.failure, &line));
            return activation.category(outcome);
        },
        .failed, .unconfirmed => |stage| {
            try writer.print("failed at {s}: {s}; inspect Host status with its owning client, then retry", .{ @tagName(stage), if (outcome == .failed) "restart failed" else "restart is unconfirmed" });
        },
    }
    try writer.writeByte('\n');
    return activation.category(outcome);
}

const Result = activation.Category;
const Totals = activation.Counts;

fn writeTotals(totals: Totals, writer: *std.Io.Writer) !void {
    const total = totals.restarted + totals.current + totals.skipped + totals.failed;
    if (total == 0) return writer.writeAll("No running Hosts.\n");
    try writer.print("{d} Hosts: {d} restarted, {d} already current, {d} left unchanged, {d} failed.\n", .{ total, totals.restarted, totals.current, totals.skipped, totals.failed });
}

/// A failed entry's stage and cause live with the activation answer they become (`activation.Selected`).
pub const Stage = activation.EntryStage;
pub const Failure = activation.EntryFailure;
pub const Entry = struct {
    socket: ?[]const u8 = null,
    /// Persistent local routing selector; never replace it with wire Store identity.
    directory: ?[]const u8 = null,
    /// Explains a positively identified Host whose sources could not be read.
    pid: ?c_int = null,
    store: ?[]const u8 = null,
    state: union(enum) {
        observed: client.HostControlObservation,
        outcome: activation.Outcome,
        failed: Failure,
    },

    pub fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        if (self.socket) |socket| allocator.free(socket);
        if (self.directory) |directory| allocator.free(directory);
        if (self.store) |store| allocator.free(store);
    }
};

/// One restart's result as it reads to the person: the per-Host entries, their
/// totals and warnings. `host_restart_all` builds it; the coordinator, upgrade and
/// the CLI render it.
pub const Batch = struct {
    entries: []Entry = &.{},
    version: ?release.Version = null,
    failure: ?anyerror = null,

    pub fn deinit(self: *Batch, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| entry.deinit(allocator);
        allocator.free(self.entries);
        self.* = .{};
    }

    /// The answer for the Store `store`: its entry's outcome, or the failure that ended its entry.
    pub fn selected(self: *const Batch, store: []const u8) activation.Selected {
        return self.summary(store).own;
    }

    /// The aggregate exit retains uncertainty if any Host may have been stopped.
    pub fn result(self: *const Batch) !void {
        for (self.entries) |entry| switch (entry.state) {
            .outcome => |outcome| if (outcome == .unconfirmed or (outcome == .faulted and outcome.faulted.effect.stage() != null)) return error.HostRestartUnconfirmed,
            .observed => return error.HostRestartUnconfirmed,
            .failed => {},
        };
        if (self.failure) |err| if (err == error.HostRestartUnconfirmed) return error.HostRestartUnconfirmed;
        if (self.totals().failed != 0) return error.HostRestartFailed;
    }

    pub fn hasGuidance(self: *const Batch) bool {
        self.assertSettled();
        return self.summary(null).guidance;
    }

    pub fn totals(self: *const Batch) Totals {
        self.assertSettled();
        return self.summary(null).counts;
    }

    /// Every entry placed against `store` (none when null) and folded by
    /// `host_activation`; an entry still only observed is unconfirmed there.
    pub fn summary(self: *const Batch, store: ?[]const u8) activation.Summary {
        var tally: activation.Tally = .{};
        for (self.entries) |entry| tally.add(.{
            .place = if (entry.directory orelse entry.store) |path|
                (if (store != null and std.mem.eql(u8, path, store.?)) .own else .other)
            else
                .unlocated,
            .state = switch (entry.state) {
                .outcome => |outcome| .{ .outcome = outcome },
                .failed => |failure| .{ .failed = failure },
                .observed => .{ .outcome = .{ .unconfirmed = .verifying } },
            },
        });
        return tally.finish(if (self.failure) |err| if (err == error.Cancelled) .cancelled else .other else null);
    }

    /// A restart batch has settled every Host it observed.
    fn assertSettled(self: *const Batch) void {
        for (self.entries) |entry| if (entry.state == .observed) unreachable;
    }

    pub fn write(self: *const Batch, writer: *std.Io.Writer) !void {
        if (self.failure) |err| try writer.print("Host restart could not finish ({s}); inspect this user's Hosts with their owning clients, then retry.\n", .{@errorName(err)});
        for (self.entries) |entry| switch (entry.state) {
            .observed => unreachable,
            .failed => |failure| try writeEntryFailure(writer, &entry, failure),
            .outcome => |outcome| _ = try writeOutcome(writer, entry.directory orelse entry.store.?, outcome, self.version),
        };
        try writeTotals(self.totals(), writer);
    }

    pub fn writeWarning(self: *const Batch, writer: *std.Io.Writer) !void {
        if (self.entries.len == 0 and self.failure == null) {
            return writer.writeAll("No running Hosts discovered now; Hosts running after publication will also be considered.\n");
        }
        try writer.print("Upgrade restarts every running Host it can safely activate, interrupting work across ALL Sessions in those Stores. Discovered {d} Hosts:\n", .{self.entries.len});
        for (self.entries) |entry| switch (entry.state) {
            .observed => {
                try field(writer, entry.directory orelse entry.store.?);
                try writer.writeAll(": running; will restart on the selected installed build\n");
            },
            .outcome => |outcome| _ = try writeOutcome(writer, entry.directory orelse entry.store.?, outcome, self.version),
            .failed => |failure| try writeEntryFailure(writer, &entry, failure),
        };
    }
};

/// One Store's failed entry, as restart all and the Host launch both print it. An empty
/// `store` is the unscoped handover line, as `writeOutcome` prints it.
pub fn writeFailure(writer: *std.Io.Writer, store: []const u8, failure: Failure) !void {
    if (store.len == 0) {
        try writer.writeAll("Host handover: ");
    } else {
        try field(writer, store);
        try writer.writeAll(": ");
    }
    try writer.print("failed at {s} ({s}): {s}\n", .{ @tagName(failure.stage), failure.cause.slice(), switch (failure.stage) {
        .discovery => "could not read this Host's sources; inspect with its owning client, then retry.",
        .observation => "could not confirm this Host; inspect with its owning client, then retry.",
        .selection => "selected installed build has no verified release version; install a managed release and retry.",
    } });
}

fn writeEntryFailure(writer: *std.Io.Writer, entry: *const Entry, failure: Failure) !void {
    if (entry.directory orelse entry.store) |store| return writeFailure(writer, store, failure);
    try writer.writeAll("Store unknown (");
    if (entry.socket) |socket| {
        try writer.writeAll("socket ");
        try field(writer, socket);
    } else if (entry.pid) |pid| {
        try writer.print("Host process {d}", .{pid});
    } else try writer.writeAll("Host sources unavailable");
    try writer.print("): failed at discovery: Host state is unconfirmed ({s}); inspect this {s} with the owning client, then retry. A refused or missing socket alone does not prove the Host stopped.\n", .{ failure.cause.slice(), if (entry.socket != null) "socket and its Store" else "Host process" });
}

pub const OptionalOutput = struct {
    io: std.Io,
    destination: std.Io.File,
    writer: std.Io.Writer,

    pub fn init(io: std.Io, destination: std.Io.File, buffer: []u8) OptionalOutput {
        return .{ .io = io, .destination = destination, .writer = .{ .buffer = buffer, .vtable = &.{ .drain = drain } } };
    }

    fn emit(self: *OptionalOutput, bytes: []const u8) void {
        self.destination.writeStreamingAll(self.io, bytes) catch {
            @import("stderr.zig").diagnosticBytes(bytes);
        };
    }

    fn drain(writer: *std.Io.Writer, parts: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *OptionalOutput = @alignCast(@fieldParentPtr("writer", writer));
        self.emit(writer.buffered());
        writer.end = 0;
        var count: usize = 0;
        for (parts[0 .. parts.len - 1]) |part| {
            self.emit(part);
            count += part.len;
        }
        for (0..splat) |_| self.emit(parts[parts.len - 1]);
        return count + splat * parts[parts.len - 1].len;
    }
};

test "SH-50 restart all reports every activation outcome and limitation with exit truth" {
    const identity = .{ .instance = @as([16]u8, @splat(1)), .pid = @as(c_int, 42) };
    const Case = struct { outcome: activation.Outcome, text: []const u8, result: Result };
    const cases = [_]Case{
        .{ .outcome = .{ .ready = .{ .instance = identity.instance, .pid = identity.pid } }, .text = "restarted on 0.1.2", .result = .restarted },
        .{ .outcome = .{ .client_incompatible = identity.pid }, .text = "restarted on 0.1.2; different Host protocol; inspect with the selected Rui client", .result = .restarted },
        .{ .outcome = .{ .already_ready = .{ .instance = identity.instance, .pid = identity.pid } }, .text = "already on 0.1.2", .result = .current },
        .{ .outcome = .superseded, .text = "left running: newer than 0.1.2; no downgrade", .result = .skipped },
        .{ .outcome = .not_needed, .text = "no longer running; no Host started", .result = .skipped },
        .{ .outcome = .replacement_observed, .text = "failed at verifying: a replacement Host was observed; inspect with its owning client, then retry", .result = .failed },
        .{ .outcome = .cancelled, .text = "failed at activation: cancelled; inspect Host status, then retry", .result = .failed },
        .{ .outcome = .{ .faulted = .{ .effect = .resolve_target, .cause = try .from("OutOfMemory") } }, .text = "failed during resolve_target (OutOfMemory); Host left running; inspect with its owning client, then retry", .result = .failed },
        .{ .outcome = .{ .target_unusable = .resolving }, .text = "failed at resolving the target: the target build could not be resolved; Host left running; check the installation, then retry", .result = .failed },
        .{ .outcome = .{ .target_unusable = .checking }, .text = "failed at checking the target: the target build could not be checked; Host left running; check the installation, then retry", .result = .failed },
    };
    var covered: std.EnumSet(std.meta.Tag(activation.Outcome)) = .empty;
    for (cases) |case| {
        var bytes: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try std.testing.expectEqual(case.result, try writeOutcome(&writer, "/store", case.outcome, .{ .schema = 1, .patch = 2 }));
        var expected: [1024]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "/store: {s}\n", .{case.text}), writer.buffered());
        covered.insert(std.meta.activeTag(case.outcome));
    }
    const without_version = [_]struct { outcome: activation.Outcome, text: []const u8, result: Result }{
        .{ .outcome = .{ .ready = .{ .instance = identity.instance, .pid = identity.pid } }, .text = "restarted", .result = .restarted },
        .{ .outcome = .{ .client_incompatible = identity.pid }, .text = "restarted with a different Host protocol; inspect with the selected Rui client", .result = .restarted },
        .{ .outcome = .{ .already_ready = .{ .instance = identity.instance, .pid = identity.pid } }, .text = "already on the selected build", .result = .current },
        .{ .outcome = .superseded, .text = "left running: newer than the selected build; no downgrade", .result = .skipped },
    };
    for (without_version) |case| {
        var bytes: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try std.testing.expectEqual(case.result, try writeOutcome(&writer, "", case.outcome, null));
        var expected: [1024]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "Host handover: {s}\n", .{case.text}), writer.buffered());
    }
    const limitations = [_][]const u8{
        "Store or Host is inaccessible; check access with its owning client",
        "Host protocol is unsupported; use its owning client",
        "ownership is unconfirmed; do not stop a guessed Host (Host status unavailable while owned)",
        "ownership is unconfirmed; do not stop a guessed Host (initial Host observation failed)",
        "ownership is unconfirmed; do not stop a guessed Host (Host directory could not be canonicalized)",
        "ownership is unconfirmed; do not stop a guessed Host (Host directories differ)",
        "ownership is unconfirmed; do not stop a guessed Host (Host identity confirmation failed)",
        "application-owned Host (including MySQL); restart through its application",
        "launch configuration cannot be safely reconstructed; restart through its owner",
        "target build cannot safely check a detached restart; Host left running",
        "not eligible for an ordinary start on this build; Host left running",
    };
    inline for (std.meta.tags(activation.Limitation), limitations) |limitation, text| {
        var bytes: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try std.testing.expectEqual(Result.skipped, try writeOutcome(&writer, "/store", .{ .unsupported = limitation }, .{ .schema = 1, .patch = 2 }));
        try std.testing.expectEqualStrings("/store: left running: " ++ text ++ "\n", writer.buffered());
    }
    covered.insert(.unsupported);
    inline for (.{ .checking, .starting }) |stage| {
        const refusal: activation.Outcome = .{ .refused = .{ .stage = stage, .failure = @import("start_report.zig").Failure.init(.settings_invalid, "typed refusal") } };
        var bytes: [2048]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try std.testing.expectEqual(Result.failed, try writeOutcome(&writer, "/store", refusal, null));
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "rui_start_error") != null);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "typed refusal") != null);
    }
    covered.insert(.refused);
    inline for (.{ .failed, .unconfirmed }) |tag| {
        inline for (std.meta.tags(activation.Stage)) |stage| {
            var bytes: [1024]u8 = undefined;
            var writer = std.Io.Writer.fixed(&bytes);
            try std.testing.expectEqual(Result.failed, try writeOutcome(&writer, "/store", @unionInit(activation.Outcome, @tagName(tag), stage), .{ .schema = 1, .patch = 2 }));
            const reason = comptime if (tag == .failed) "restart failed" else "restart is unconfirmed";
            var expected: [1024]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "/store: failed at {s}: {s}; inspect Host status with its owning client, then retry\n", .{ @tagName(stage), reason }), writer.buffered());
            var unscoped: [1024]u8 = undefined;
            var unscoped_writer = std.Io.Writer.fixed(&unscoped);
            try std.testing.expectEqual(Result.failed, try writeOutcome(&unscoped_writer, "", @unionInit(activation.Outcome, @tagName(tag), stage), null));
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "Host handover: failed at {s}: {s}; inspect Host status with its owning client, then retry\n", .{ @tagName(stage), reason }), unscoped_writer.buffered());
        }
        covered.insert(tag);
    }
    try std.testing.expectEqual(std.meta.tags(std.meta.Tag(activation.Outcome)).len, covered.count());
}

test "restart all totals distinguish no Hosts success skips and failures" {
    var bytes: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writeTotals(.{}, &writer);
    try std.testing.expectEqualStrings("No running Hosts.\n", writer.buffered());
    writer.end = 0;
    var totals: Totals = .{};
    for ([_]Result{ .restarted, .current, .skipped, .failed }) |result| totals.add(result);
    try writeTotals(totals, &writer);
    try std.testing.expectEqualStrings("4 Hosts: 1 restarted, 1 already current, 1 left unchanged, 1 failed.\n", writer.buffered());
}

test "restart all counts every outcome even after its output reader closes" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    _ = std.c.close(fds[0]);
    const destination: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer destination.close(std.testing.io);
    var buffer: [16]u8 = undefined;
    var output = OptionalOutput.init(std.testing.io, destination, &buffer);
    var totals: Totals = .{};
    const info = @typeInfo(activation.Outcome).@"union";
    inline for (info.field_names, info.field_types) |name, Payload| {
        const outcome = @unionInit(activation.Outcome, name, std.mem.zeroes(Payload));
        totals.add(try writeOutcome(&output.writer, "/store", outcome, .{ .schema = 1, .patch = 2 }));
        try output.writer.flush();
    }
    try writeTotals(totals, &output.writer);
    try output.writer.flush();
    try std.testing.expectEqual(info.field_names.len, totals.restarted + totals.current + totals.skipped + totals.failed);
}

test "every failed stage names its cause" {
    var buffer: [512]u8 = undefined;
    for ([_]Stage{ .discovery, .observation, .selection }) |stage| {
        var writer: std.Io.Writer = .fixed(&buffer);
        const entry: Entry = .{ .socket = "/run/x.sock", .store = if (stage == .discovery) null else "/store", .state = .{ .failed = .of(stage, error.ConnectionRefused) } };
        try writeEntryFailure(&writer, &entry, entry.state.failed);
        const text = writer.buffered();
        try std.testing.expect(std.mem.indexOf(u8, text, "(ConnectionRefused)") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, @tagName(stage)) != null);
    }
}

test "restart batch retains DIR selection independently of wire identity and outcomes" {
    var entries = [_]Entry{.{
        .directory = "/host-directory",
        .store = "mysql-opaque-identity",
        .state = .{ .outcome = .{ .refused = .{ .stage = .checking, .failure = @import("start_report.zig").Failure.init(.settings_invalid, "cannot start") } } },
    }};
    const batch: Batch = .{ .entries = &entries };
    try std.testing.expect(batch.selected("/host-directory").outcome == .refused);
    try std.testing.expect(batch.selected("mysql-opaque-identity").outcome == .not_needed);
    try std.testing.expect(batch.hasGuidance());
    try std.testing.expectEqual(@as(usize, 1), batch.totals().failed);
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try batch.write(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "/host-directory: refused at checking") != null);
}

test "restart reports a positively identified Host without a socket or directory" {
    const entry: Entry = .{ .pid = 42, .state = .{ .failed = .of(.discovery, error.HostServeStoreMissing) } };
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeEntryFailure(&writer, &entry, entry.state.failed);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Host process 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "HostServeStoreMissing") != null);
}

test "SH-127 lifecycle faults report the exact effect and cause at every stage" {
    const cases = [_]struct { effect: std.meta.Tag(activation.Effect), expected: []const u8 }{
        .{ .effect = .resolve_target, .expected = "failed during resolve_target (OutOfMemory); Host left running; inspect with its owning client, then retry" },
        .{ .effect = .confirm_current, .expected = "failed during confirm_current (OutOfMemory); Host left running; inspect with its owning client, then retry" },
        .{ .effect = .reconstruct_sources, .expected = "failed during reconstruct_sources (OutOfMemory); Host left running; inspect with its owning client, then retry" },
        .{ .effect = .check_target, .expected = "failed during check_target (OutOfMemory); Host left running; inspect with its owning client, then retry" },
        .{ .effect = .reobserve, .expected = "failed during reobserve (OutOfMemory); Host left running; inspect with its owning client, then retry" },
        .{ .effect = .snapshot, .expected = "failed during snapshot (OutOfMemory); Host left running; inspect with its owning client, then retry" },
        .{ .effect = .stop, .expected = "failed at stopping: restart is unconfirmed during stop (OutOfMemory); inspect Host status with its owning client, then retry" },
        .{ .effect = .await_retirement, .expected = "failed at awaiting_retirement: restart is unconfirmed during await_retirement (OutOfMemory); inspect Host status with its owning client, then retry" },
        .{ .effect = .start, .expected = "failed at starting: restart is unconfirmed during start (OutOfMemory); inspect Host status with its owning client, then retry" },
        .{ .effect = .verify, .expected = "failed at verifying: restart is unconfirmed during verify (OutOfMemory); inspect Host status with its owning client, then retry" },
    };
    try std.testing.expectEqual(std.meta.tags(std.meta.Tag(activation.Effect)).len - 1, cases.len);
    for (cases) |case| {
        const outcome: activation.Outcome = .{ .faulted = .{ .effect = case.effect, .cause = try .from("OutOfMemory") } };
        const entries = [_]Entry{.{ .directory = "/store", .state = .{ .outcome = outcome } }};
        const batch: Batch = .{ .entries = @constCast(&entries) };
        var bytes: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&bytes);
        try batch.write(&writer);
        var line_bytes: [512]u8 = undefined;
        try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), try std.fmt.bufPrint(&line_bytes, "/store: {s}\n", .{case.expected})));
        try std.testing.expectEqual(@as(usize, 1), batch.totals().failed);
        try std.testing.expectEqualDeep(activation.Selected{ .outcome = outcome }, batch.selected("/store"));
    }
}

test "SH-127 a failed Store entry keeps its stage, cause and certainty across every answer" {
    const Certainty = enum { ok, failed, unconfirmed };
    const refusal: activation.Outcome = .{ .refused = .{ .stage = .checking, .failure = @import("start_report.zig").Failure.init(.settings_invalid, "cannot start") } };
    const cases = [_]struct { name: []const u8, state: ?@FieldType(Entry, "state"), selected: activation.Selected, text: []const u8, certainty: Certainty }{
        .{ .name = "observation failure", .state = .{ .failed = .of(.observation, error.OutOfMemory) }, .selected = .{ .failed = .of(.observation, error.OutOfMemory) }, .text = "/store: failed at observation (OutOfMemory): could not confirm this Host; inspect with its owning client, then retry.\n", .certainty = .failed },
        .{ .name = "selection failure", .state = .{ .failed = .of(.selection, error.NoVerifiedRelease) }, .selected = .{ .failed = .of(.selection, error.NoVerifiedRelease) }, .text = "/store: failed at selection (NoVerifiedRelease): selected installed build has no verified release version; install a managed release and retry.\n", .certainty = .failed },
        .{ .name = "absent", .state = null, .selected = .{ .outcome = .not_needed }, .text = "No running Hosts.\n", .certainty = .ok },
        .{ .name = "not_needed", .state = .{ .outcome = .not_needed }, .selected = .{ .outcome = .not_needed }, .text = "/store: no longer running; no Host started\n", .certainty = .ok },
        .{ .name = "refused", .state = .{ .outcome = refusal }, .selected = .{ .outcome = refusal }, .text = "/store: refused at checking\n", .certainty = .failed },
        .{ .name = "faulted before stop", .state = .{ .outcome = .{ .faulted = .{ .effect = .check_target, .cause = try .from("OutOfMemory") } } }, .selected = .{ .outcome = .{ .faulted = .{ .effect = .check_target, .cause = try .from("OutOfMemory") } } }, .text = "/store: failed during check_target (OutOfMemory); Host left running", .certainty = .failed },
        .{ .name = "faulted after stop", .state = .{ .outcome = .{ .faulted = .{ .effect = .start, .cause = try .from("OutOfMemory") } } }, .selected = .{ .outcome = .{ .faulted = .{ .effect = .start, .cause = try .from("OutOfMemory") } } }, .text = "/store: failed at starting: restart is unconfirmed during start (OutOfMemory)", .certainty = .unconfirmed },
        .{ .name = "unconfirmed", .state = .{ .outcome = .{ .unconfirmed = .verifying } }, .selected = .{ .outcome = .{ .unconfirmed = .verifying } }, .text = "/store: failed at verifying: restart is unconfirmed", .certainty = .unconfirmed },
    };
    for (cases) |case| {
        var storage: [1]Entry = undefined;
        const entries: []Entry = if (case.state) |state| blk: {
            storage[0] = .{ .directory = "/store", .store = "/store", .state = state };
            break :blk storage[0..1];
        } else storage[0..0];
        const batch: Batch = .{ .entries = entries };
        errdefer std.debug.print("case={s}\n", .{case.name});
        try std.testing.expectEqualDeep(case.selected, batch.selected("/store"));
        var bytes: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&bytes);
        try batch.write(&writer);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), case.text) != null);
        switch (case.certainty) {
            .ok => try batch.result(),
            .failed => try std.testing.expectError(error.HostRestartFailed, batch.result()),
            .unconfirmed => try std.testing.expectError(error.HostRestartUnconfirmed, batch.result()),
        }
    }
}

test "SH-127 a launch diagnostic renders a failed entry after its Batch is destroyed" {
    const host_launch = @import("host_launch.zig");
    const host_start = @import("host_start.zig");
    const allocator = std.testing.allocator;
    const entries = try allocator.alloc(Entry, 1);
    entries[0] = .{ .directory = try allocator.dupe(u8, "/store"), .state = .{ .failed = .of(.observation, error.OutOfMemory) } };
    var batch: Batch = .{ .entries = entries };
    const selected = batch.selected("/store");
    try std.testing.expect(selected == .failed);
    batch.deinit(allocator);
    var result: host_launch.Result = .failed(.setup, error.HostRestartUnconfirmed);
    host_start.handoverFailed(&result, selected);
    var bytes: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try host_launch.writeDiagnostics(&result, &writer, 0);
    try std.testing.expectEqualStrings("Host handover: failed at observation (OutOfMemory): could not confirm this Host; inspect with its owning client, then retry.\n", writer.buffered());
}

test "SH-129 batch exit preserves uncertainty across mixed Host results" {
    const pre: Entry = .{ .state = .{ .outcome = .{ .faulted = .{ .effect = .check_target, .cause = try .from("OutOfMemory") } } } };
    const post: Entry = .{ .state = .{ .outcome = .{ .faulted = .{ .effect = .verify, .cause = try .from("OutOfMemory") } } } };
    const unconfirmed: Entry = .{ .state = .{ .outcome = .{ .unconfirmed = .stopping } } };
    const success: Entry = .{ .state = .{ .outcome = .not_needed } };
    const cases = [_]struct { entries: []const Entry, failure: ?anyerror = null, expected: ?anyerror }{
        .{ .entries = &.{success}, .expected = null },
        .{ .entries = &.{pre}, .expected = error.HostRestartFailed },
        .{ .entries = &.{post}, .expected = error.HostRestartUnconfirmed },
        .{ .entries = &.{unconfirmed}, .expected = error.HostRestartUnconfirmed },
        .{ .entries = &.{ pre, post, success }, .expected = error.HostRestartUnconfirmed },
        .{ .entries = &.{ post, pre }, .expected = error.HostRestartUnconfirmed },
        .{ .entries = &.{}, .failure = error.HostRestartUnconfirmed, .expected = error.HostRestartUnconfirmed },
        .{ .entries = &.{}, .failure = error.OutOfMemory, .expected = error.HostRestartFailed },
    };
    for (cases) |case| {
        const batch: Batch = .{ .entries = @constCast(case.entries), .failure = case.failure };
        if (case.expected) |err| try std.testing.expectError(err, batch.result()) else try batch.result();
    }
}
