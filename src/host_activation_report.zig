const std = @import("std");
const activation = @import("host_activation.zig");
const release = @import("release_candidate.zig");
const TerminalText = @import("TerminalText.zig");

fn field(writer: *std.Io.Writer, text: []const u8) !void {
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
            }});
        },
        .replacement_observed => {
            try writer.writeAll("failed at verifying: a replacement Host was observed; inspect with its owning client, then retry");
        },
        .cancelled => {
            try writer.writeAll("failed at activation: cancelled; inspect Host status, then retry");
        },
        .pre_stop_failed => |effect| {
            try writer.print("failed before stopping during {s}; Host left running", .{@tagName(effect)});
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

pub fn summary(outcome: activation.Outcome) []const u8 {
    return switch (outcome) {
        .not_needed => "no longer running",
        .superseded => "newer build already running",
        .already_ready => "already on selected build",
        .ready => "restarted",
        .client_incompatible => "restarted; client incompatible",
        .unsupported => |limitation| switch (limitation) {
            .inaccessible => "Host inaccessible",
            .incompatible => "Host protocol unsupported",
            .ownership_status => "Host status unavailable",
            .ownership_observation => "Host observation failed",
            .ownership_directory_unavailable => "Host directory unavailable",
            .ownership_directory_mismatch => "Host directories differ",
            .ownership_confirmation => "Host identity unconfirmed",
            .application_owned => "application-owned Host",
            .configuration_unavailable => "launch configuration unavailable",
            .target_capability => "target cannot check restart",
        },
        .replacement_observed => "replacement Host observed",
        .cancelled => "activation cancelled",
        .pre_stop_failed => "handover failed",
        .target_unusable => |step| switch (step) {
            .resolving => "target resolution failed",
            .checking => "target check failed",
        },
        .refused => |refusal| switch (refusal.stage) {
            .checking => "settings refused",
            .starting => "refused to start",
        },
        .failed => |stage| switch (stage) {
            .stopping => "stop failed",
            .awaiting_retirement => "retire failed",
            .starting => "start failed",
            .verifying => "verify failed",
        },
        .unconfirmed => |stage| switch (stage) {
            .stopping => "stop unconfirmed",
            .awaiting_retirement => "retire unconfirmed",
            .starting => "start unconfirmed",
            .verifying => "verify unconfirmed",
        },
    };
}

/// A lifecycle fault keeps its original cause and says whether a stop may have happened.
pub fn writeFault(writer: *std.Io.Writer, fault: activation.Fault) !void {
    const action: []const u8 = switch (fault.effect) {
        .resolve_target => "resolving the target",
        .confirm_current => "confirming the current Host",
        .reconstruct_sources => "reconstructing launch settings",
        .check_target => "checking the target",
        .reobserve => "reobserving the Host",
        .snapshot => "checking the Host process",
        .stop => "stopping the Host",
        .await_retirement => "awaiting retirement",
        .start => "starting the replacement",
        .verify => "verifying the replacement",
        .done => "finishing activation",
    };
    const cause: []const u8 = if (fault.cause == error.OutOfMemory)
        "Memory was exhausted during Host handover."
    else
        @import("caller_error.zig").facts(@import("caller_error.zig").of(fault.cause)).says;
    if (fault.effect.stage()) |stage| {
        try writer.print("Host handover: {s} is unconfirmed while {s}; inspect Host status before retrying. Cause: {s} [{s}]\n", .{ @tagName(stage), action, cause, @errorName(fault.cause) });
    } else {
        try writer.print("Host handover: failed while {s} before stopping the Host. Cause: {s} [{s}]\n", .{ action, cause, @errorName(fault.cause) });
    }
}

pub fn faultSummary(fault: activation.Fault) []const u8 {
    return if (fault.effect.stage()) |stage| summary(.{ .unconfirmed = stage }) else "handover failed";
}
