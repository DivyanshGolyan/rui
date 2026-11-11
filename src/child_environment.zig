//! One Host-memory environment snapshot and install for both child doors.
//! Nothing here enters Store records, request digests or diagnostics.
const std = @import("std");
const SessionEnvironments = @import("SessionEnvironments.zig");
const Store = @import("store.zig").Store;

pub const Inheritance = struct {
    environments: ?*SessionEnvironments,
    offer: SessionEnvironments.Offer = .{},

    pub fn init(environments: ?*SessionEnvironments, parent: []const u8, allocator: std.mem.Allocator, scratch: std.mem.Allocator) !Inheritance {
        var self: Inheritance = .{ .environments = environments };
        const table = environments orelse return self;
        const base = (try table.copy(parent, scratch)) orelse return self;
        defer scratch.free(base);
        self.offer = try .init(allocator, base.len);
        @memcpy(self.offer.room()[0..base.len], base);
        return self;
    }

    pub fn deinit(self: *Inheritance, allocator: std.mem.Allocator) void {
        self.offer.deinit(allocator);
    }

    pub fn messageCallback(self: *Inheritance) ?Store.MessageCommitted {
        return if (self.offer.value() != null) .{ .context = self, .call = message } else null;
    }

    pub fn creationCallback(self: *Inheritance) ?Store.CreationCommitted {
        return if (self.offer.value() != null) .{ .context = self, .call = creation } else null;
    }

    fn message(context: *anyopaque, admission: Store.MessageAdmission) void {
        const self: *Inheritance = @ptrCast(@alignCast(context));
        self.install(admission.session, admission.admission_id);
    }

    fn creation(context: *anyopaque, session: []const u8) void {
        const self: *Inheritance = @ptrCast(@alignCast(context));
        self.install(session, 0);
    }

    fn install(self: *Inheritance, session: []const u8, admission: u64) void {
        self.environments.?.offer(session, .{ .origin = .peer, .admission = admission }, &self.offer);
    }
};
