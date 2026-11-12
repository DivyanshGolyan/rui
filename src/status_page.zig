//! Owned Session inspection facts shared by the chat line and chat info panel.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const built_in_tool = @import("built_in_tool.zig");
const model_capability = @import("model_capability.zig");
const product_defaults = @import("product_defaults.zig");
const Provider = @import("provider_name.zig").Provider;
const ReasoningEffort = model_capability.ReasoningEffort;
const WorkKind = @import("session_work.zig").Kind;
const ArchiveState = @import("session_archive.zig").State;
const indent = "   ";

pub const max_session_bytes = 128;
pub const max_label_bytes = 100;
pub const max_path_bytes = 4096;
pub const max_model_bytes = model_capability.max_model_bytes;
pub const max_key_bytes = 128;
pub const max_outcome_bytes = 96;
pub const max_recent = 10;

pub const Session = struct {
    session: Bounded(max_session_bytes),
    /// Empty when the Session has no name.
    label: Bounded(max_label_bytes),
    workspace: Bounded(max_path_bytes),
    provider: Provider,
    model: Bounded(max_model_bytes),
    /// The saved spec's effort; null omits reasoning.
    effort: ?ReasoningEffort,
    effort_override: bool,
    permission: enum { ask, bypass },
    tools: built_in_tool.Selection,
    /// The Session was configured with instructions.
    instructions: bool,
    /// Null when the Host sets no automatic threshold.
    compaction_trigger: ?u64,
    compaction_override: bool,
    context_estimate: ?u64,
    output_reservation: u64,
    reservation_override: bool,
    work: Work,
    archive_state: ArchiveState = .active,

    /// The page shows the same Session and work.
    pub fn eql(self: *const Session, other: *const Session) bool {
        inline for (comptime std.meta.fieldNames(Session)) |name| {
            const a = &@field(self, name);
            const b = &@field(other, name);
            const Field = @TypeOf(a.*);
            const same = if (Field == Work) a.eql(b) else if (comptime @typeInfo(Field) == .@"struct" and @hasDecl(Field, "slice")) b.eql(a.slice()) else std.meta.eql(a.*, b.*);
            if (!same) return false;
        }
        return true;
    }
};

pub const Work = struct {
    state: WorkKind,
    /// Actions awaiting approval, which the page lists one per line after
    /// this part, and a digest of their IDs in Current's order.
    approvals: u64,
    actions: u64,
    current_message: ?Bounded(max_key_bytes),
    /// The first indeterminate Action of the active Turn, and how many there are.
    indeterminate: ?u64,
    indeterminate_count: u64,
    recent: [max_recent]Recent,
    recent_count: usize,

    pub const Recent = struct { message: Bounded(max_key_bytes), outcome: Bounded(max_outcome_bytes) };

    fn eql(self: *const Work, other: *const Work) bool {
        if (self.state != other.state or self.approvals != other.approvals or self.actions != other.actions or
            self.indeterminate != other.indeterminate or self.indeterminate_count != other.indeterminate_count or
            self.recent_count != other.recent_count) return false;
        if ((self.current_message == null) != (other.current_message == null)) return false;
        if (self.current_message) |*message| if (!other.current_message.?.eql(message.slice())) return false;
        for (self.recent[0..self.recent_count], other.recent[0..other.recent_count]) |*a, *b|
            if (!b.message.eql(a.message.slice()) or !b.outcome.eql(a.outcome.slice())) return false;
        return true;
    }
};

pub fn archiveBadge(state: ArchiveState) ?[]const u8 {
    return switch (state) {
        .active => null,
        .archiving => "Stopping and archiving",
        .archived => "Archived · /unarchive",
    };
}

/// One Action awaiting approval, after `render`.
pub fn writeAction(action: u64, out: *std.Io.Writer) !void {
    try out.print(indent ++ "Action requiring attention: {d}\n", .{action});
}

pub fn writeGrouped(out: *std.Io.Writer, value: u64) !void {
    var digits: [20]u8 = undefined;
    const text = std.fmt.bufPrint(&digits, "{d}", .{value}) catch unreachable;
    for (text, 0..) |digit, index| {
        if (index != 0 and (text.len - index) % 3 == 0) try out.writeByte(',');
        try out.writeByte(digit);
    }
}

pub fn sample(session: *Session) void {
    session.* = .{
        .session = .{ .len = 0 },
        .label = .{ .len = 0 },
        .workspace = .{ .len = 0 },
        .provider = .codex,
        .model = .{ .len = 0 },
        .effort = .high,
        .effort_override = false,
        .permission = .bypass,
        .tools = .initMany(&.{ .bash, .web_search }),
        .instructions = true,
        .compaction_trigger = 245_000,
        .compaction_override = false,
        .context_estimate = 31_200,
        .output_reservation = 0,
        .reservation_override = false,
        .work = .{ .state = .idle, .approvals = 0, .actions = 0, .current_message = null, .indeterminate = null, .indeterminate_count = 0, .recent = undefined, .recent_count = 0 },
    };
    session.session.set("k7m2qx") catch unreachable;
    session.label.set("fix-safari-export") catch unreachable;
    session.workspace.set("/home/d/code/rui") catch unreachable;
    session.model.set(product_defaults.recommended_model) catch unreachable;
}

test "archive badges name pending and completed archive independently of work" {
    try std.testing.expect(archiveBadge(.active) == null);
    try std.testing.expectEqualStrings("Stopping and archiving", archiveBadge(.archiving).?);
    try std.testing.expectEqualStrings("Archived · /unarchive", archiveBadge(.archived).?);
    var session: Session = undefined;
    sample(&session);
    var other = session;
    other.archive_state = .archiving;
    try std.testing.expect(!session.eql(&other));
    other.archive_state = .archived;
    try std.testing.expect(!session.eql(&other));
}

test "Session inspection equality ignores unused storage and includes work changes" {
    var session: Session = undefined;
    sample(&session);
    var other = session;
    try std.testing.expect(session.eql(&other));
    other.label.bytes[other.label.len] = 'x';
    other.work.recent[3].message = .{ .len = 0 };
    try std.testing.expect(session.eql(&other));
    other.work.actions = 1;
    try std.testing.expect(!session.eql(&other));
    other = session;
    other.work.current_message = .{ .len = 0 };
    try std.testing.expect(!session.eql(&other));
}
