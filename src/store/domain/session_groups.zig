const std = @import("std");
const group = @import("../../session_group.zig");
const topic = @import("../../session_group_topic.zig");
const Bounded = @import("../../bounded.zig").Bounded;
const session_id = @import("../../session_id.zig");
const workspace_path = @import("../../workspace_path.zig");
const command_input = @import("../../command_input.zig");
const command_reply = @import("../../command_reply.zig");
const mutation_answer = @import("../../mutation_answer.zig");
const command_domain = @import("command.zig");
const store_core = @import("../Store.zig");
const rsql = @import("../rsql.zig");
const transition = @import("../transition.zig");

const member = rsql.Read(.{
    .sql = "SELECT s.session_ref,s.workspace_key,s.next_position,s.workspace,s.label,m.group_id,m.manual,m.creator_ref,m.evaluated " ++
        "FROM session s JOIN session_group_member m ON m.session_ref=s.session_ref WHERE s.session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct {
        session: rsql.SessionHead,
        workspace: *Bounded(workspace_path.max_bytes),
        label: ?group.Name,
        group_id: ?rsql.Positive,
        manual: bool,
        creator_ref: ?Bounded(session_id.bytes),
        evaluated: bool,
    },
    .cardinality = .optional,
});
const creator = rsql.Read(.{
    .sql = "SELECT s.session_ref,s.workspace_key,s.next_position,s.label,m.group_id,m.manual FROM session s " ++
        "JOIN session_group_member m ON m.session_ref=s.session_ref WHERE s.session_ref=?1",
    .Args = struct { session: []const u8 },
    .Row = struct { session: rsql.SessionHead, label: ?group.Name, group_id: ?rsql.Positive, manual: bool },
    .cardinality = .optional,
});
const named = rsql.Read(.{
    .sql = "SELECT group_id,name,collapsed,revision FROM session_group WHERE name=?1",
    .Args = struct { name: []const u8 },
    .Row = struct { group_id: rsql.Positive, name: group.Name, collapsed: bool, revision: rsql.Positive },
    .cardinality = .optional,
});
const anchored = rsql.Read(.{
    .sql = "SELECT group_id,name,collapsed,revision FROM session_group WHERE automatic_anchor=?1",
    .Args = struct { anchor: [32]u8 },
    .Row = named.Row,
    .cardinality = .optional,
});
const by_id = rsql.Read(.{
    .sql = "SELECT group_id,name,collapsed,revision FROM session_group WHERE group_id=?1",
    .Args = struct { id: u64 },
    .Row = named.Row,
    .cardinality = .optional,
});
const insert_group = rsql.Write(.{
    .sql = "INSERT INTO session_group(group_id,name,collapsed,revision,automatic_anchor) VALUES(?1,?2,0,1,?3)",
    .Args = struct { id: u64, name: []const u8, anchor: ?[32]u8 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});
const insert_member = rsql.Write(.{
    .sql = "INSERT INTO session_group_member(session_ref,group_id,manual,creator_ref,evaluated) VALUES(@session(?1),NULL,0,?2,0)",
    .Args = struct { session: rsql.SessionHead, creator_ref: ?[]const u8 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});
const set_member = rsql.Write(.{
    .sql = "UPDATE session_group_member SET group_id=?2,manual=?3,evaluated=?4 WHERE session_ref=@session(?1)",
    .Args = struct { session: rsql.SessionHead, id: ?u64, manual: bool, evaluated: bool },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});
const family_member = rsql.Write(.{
    .sql = "UPDATE session_group_member SET group_id=?2,evaluated=1 WHERE session_ref=@session(?1) AND manual=0 AND group_id IS NULL",
    .Args = struct { session: rsql.SessionHead, id: u64 },
    .expect = .{ .at_most = 1 },
});
const rename_group = rsql.Write(.{
    .sql = "UPDATE session_group SET name=?2,revision=revision+1 WHERE group_id=?1",
    .Args = struct { id: u64, name: []const u8 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});
const collapse_group = rsql.Write(.{
    .sql = "UPDATE session_group SET collapsed=?2,revision=revision+1 WHERE group_id=?1",
    .Args = struct { id: u64, collapsed: bool },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.CorruptStore } },
});

pub const Automatic = struct {
    phase: enum { facts, creator, candidate, collision, done } = .done,
    row: member.Row = undefined,
    found: @import("../access.zig").Found = .missing,
    parent: creator.Result = null,
    candidate: anchored.Result = null,
    collision: named.Result = null,
    name: group.Name = .{},
    anchor: [32]u8 = undefined,
    id: ?u64 = null,
    family: bool = false,

    pub fn prepareCreator(self: *Automatic, a: anytype, reference: []const u8) void {
        a.read(creator, .{ .session = reference }, &self.parent);
    }

    pub fn prepareCreation(self: *Automatic, a: anytype) void {
        if (self.phase != .done) return;
        const parent = self.parent orelse return;
        if (group.automatic(.{}, false, placement(parent.group_id, parent.manual)) != .family) return;
        self.familyGroup(a, parent);
    }

    pub fn placeCreated(self: *Automatic, a: anytype, session: rsql.SessionHead, workspace: *Bounded(workspace_path.max_bytes), label: ?group.Name) !bool {
        self.row = .{ .session = session, .workspace = workspace, .label = label, .group_id = null, .manual = false, .creator_ref = null, .evaluated = false };
        if (self.parent != null) {
            if (self.phase == .done) self.phase = .creator;
            return self.advance(a);
        }
        return self.topicGroup(a);
    }

    pub fn prepare(self: *Automatic, a: anytype, session: rsql.SessionHead, workspace: *Bounded(workspace_path.max_bytes)) void {
        self.* = .{ .phase = .facts, .row = .{ .session = session, .workspace = workspace, .label = null, .group_id = null, .manual = false, .creator_ref = null, .evaluated = false } };
        a.readInto(member, .{ .session = &self.row.session.ref }, &self.row, &self.found);
    }

    pub fn advance(self: *Automatic, a: anytype) !bool {
        switch (self.phase) {
            .done => return true,
            .facts => {
                if (!self.found.get()) return error.CorruptStore;
                if (group.automatic(placement(self.row.group_id, self.row.manual), self.row.evaluated, null) == .keep) return self.done();
                if (self.row.creator_ref) |*reference| {
                    a.read(creator, .{ .session = reference.slice() }, &self.parent);
                    self.phase = .creator;
                    return false;
                }
                return self.topicGroup(a);
            },
            .creator => {
                const parent = self.parent orelse return error.CorruptStore;
                switch (group.automatic(.{}, false, placement(parent.group_id, parent.manual))) {
                    .inherit => |id| {
                        self.save(a, id);
                        return self.done();
                    },
                    .ungrouped => {
                        self.save(a, null);
                        return self.done();
                    },
                    .family => {
                        self.familyGroup(a, parent);
                        return false;
                    },
                    .topic, .keep => unreachable,
                }
            },
            .candidate => {
                if (self.candidate) |row| {
                    self.save(a, row.group_id.get());
                    return self.done();
                }
                if (self.collision == null) return self.create(a);
                return self.retryName(a);
            },
            .collision => {
                if (self.collision != null) return self.retryName(a);
                return self.create(a);
            },
        }
    }

    fn familyGroup(self: *Automatic, a: anytype, parent: creator.Row) void {
        self.family = true;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("rui/session-group/family/1\x00");
        hash.update(&parent.session.ref);
        self.anchor = hash.finalResult();
        self.name = group.Name.from(&parent.session.ref) catch unreachable;
        if (parent.label) |name| if (group.validName(name.slice())) {
            self.name = name;
        };
        _ = self.lookup(a);
    }

    fn topicGroup(self: *Automatic, a: anytype) !bool {
        const label = if (self.row.label) |*value| value else return self.done();
        const key = topic.key(self.row.workspace.slice(), label.slice()) orelse {
            self.save(a, null);
            return self.done();
        };
        self.anchor = key;
        self.name = label.*;
        return self.lookup(a);
    }

    fn lookup(self: *Automatic, a: anytype) bool {
        a.read(anchored, .{ .anchor = self.anchor }, &self.candidate);
        a.read(named, .{ .name = self.name.slice() }, &self.collision);
        self.phase = .candidate;
        return false;
    }

    fn retryName(self: *Automatic, a: anytype) !bool {
        self.id = try a.identity(.group_id);
        var buffer: [100]u8 = undefined;
        const prefix = @import("../../utf8_validation.zig").completePrefix(self.name.slice()[0..@min(self.name.len, 70)]);
        const text = try std.fmt.bufPrint(&buffer, "{s} [{d}]", .{ prefix, self.id.? });
        self.name = try group.Name.from(text);
        self.collision = null;
        a.read(named, .{ .name = self.name.slice() }, &self.collision);
        self.phase = .collision;
        return false;
    }

    fn create(self: *Automatic, a: anytype) !bool {
        const id = self.id orelse try a.identity(.group_id);
        a.write(insert_group, .{ .id = id, .name = self.name.slice(), .anchor = self.anchor });
        self.save(a, id);
        return self.done();
    }

    fn save(self: *Automatic, a: anytype, id: ?u64) void {
        a.write(set_member, .{ .session = self.row.session, .id = id, .manual = false, .evaluated = true });
        if (self.family and id != null) a.write(family_member, .{ .session = self.parent.?.session, .id = id.? });
    }

    fn done(self: *Automatic) bool {
        self.phase = .done;
        return true;
    }
};

fn placement(id: ?rsql.Positive, manual: bool) group.Placement {
    return .{ .group = if (id) |value| value.get() else null, .manual = manual };
}

pub fn created(a: anytype, session: rsql.SessionHead, creator_ref: ?[]const u8) void {
    a.write(insert_member, .{ .session = session, .creator_ref = creator_ref });
}

pub const GroupSession = struct {
    pub const rounds = transition.rounds(.{ .saved = .{.always}, .facts = .{.branch}, .automatic = .{.paged} });
    pub const round_budget = 2;
    pub const commit: transition.Commit = .transaction;
    pub const begin: ?rounds.At = .saved;
    pub const Input = struct { command: *const command_input.SessionGroupCommand };
    pub const Result = command_reply.SessionGroupReply;
    pub const Ordinary = store_core.Ordinary.none;
    pub const Guards = error{};
    pub const Declined = error{};

    input: Input,
    digest: [32]u8 = undefined,
    saved: command_domain.saved_command.Result = undefined,
    target: member.Row = undefined,
    found: @import("../access.zig").Found = .missing,
    selected: by_id.Result = null,
    duplicate: named.Result = null,
    answer: command_domain.StoredAnswer = undefined,
    rejection: ?mutation_answer.SessionGroupRejection = null,

    pub fn step(t: *GroupSession, r: *transition.Round(GroupSession), ran: ?rounds.At) !transition.Next(GroupSession) {
        const command = t.input.command;
        const session = command.session.slice();
        const key = command.key.slice();
        const scratch = r.configurationReads();
        if (ran == null) {
            t.digest = command.semanticDigest();
            command_domain.lookupCommand(r, key, &t.saved);
            return .{ .round = .saved };
        }
        if (ran.? == .saved) {
            switch (try command_domain.classify(mutation_answer.SessionGroupRejection, &t.saved, .session_group, session, &t.digest)) {
                .fresh => {},
                .conflict => return .{ .done = .conflict },
                .accepted => return .{ .done = .{ .accepted = .{ .replayed = true } } },
                .rejected => |code| return .{ .done = .{ .rejected = .{ .replayed = true, .code = code } } },
            }
            scratch.next.workspace.len = 0;
            t.target.workspace = &scratch.next.workspace;
            if (session_id.valid(session)) r.readInto(member, .{ .session = session }, &t.target, &t.found);
            switch (command.action) {
                .assign => |*name| if (group.validName(name.slice())) r.read(named, .{ .name = name.slice() }, &t.duplicate),
                .rename_current => |*name| {
                    if (group.validName(name.slice())) r.read(named, .{ .name = name.slice() }, &t.duplicate);
                },
                .rename => |*value| {
                    if (group.validId(value.group)) r.read(by_id, .{ .id = value.group }, &t.selected);
                    if (group.validName(value.name.slice())) r.read(named, .{ .name = value.name.slice() }, &t.duplicate);
                },
                .collapse => |value| if (group.validId(value.group)) r.read(by_id, .{ .id = value.group }, &t.selected),
                .leave, .automatic => {},
            }
            return .{ .round = .facts };
        }
        if (ran.? == .automatic) {
            if (!try scratch.grouping.advance(r)) return .{ .round = .automatic };
            return t.finish(r);
        }
        t.rejection = if (!session_id.valid(session)) .invalid_session_reference else if (!t.found.get()) .unknown_session else null;
        if (t.rejection != null) return t.finish(r);
        r.invalidateSessions();
        switch (command.action) {
            .assign => |*name| {
                if (!group.validName(name.slice())) {
                    t.rejection = .invalid_group_name;
                    return t.finish(r);
                }
                const id = if (t.duplicate) |row| row.group_id.get() else fresh: {
                    const id = try r.identity(.group_id);
                    r.write(insert_group, .{ .id = id, .name = name.slice(), .anchor = null });
                    break :fresh id;
                };
                r.write(set_member, .{ .session = t.target.session, .id = id, .manual = true, .evaluated = true });
            },
            .leave => r.write(set_member, .{ .session = t.target.session, .id = null, .manual = true, .evaluated = true }),
            .automatic => {
                r.write(set_member, .{ .session = t.target.session, .id = null, .manual = false, .evaluated = false });
                scratch.grouping.prepare(r, t.target.session, &scratch.next.workspace);
                return .{ .round = .automatic };
            },
            .rename_current => |*name| t.rename(r, name, if (t.target.group_id) |id| id.get() else null),
            .rename => |*value| {
                if (!group.validId(value.group)) t.rejection = .invalid_group_id else t.rename(r, &value.name, if (t.selected) |selected| selected.group_id.get() else null);
            },
            .collapse => |value| {
                if (!group.validId(value.group)) t.rejection = .invalid_group_id else if (t.selected == null) t.rejection = .unknown_group else if (t.selected.?.collapsed != value.collapsed) r.write(collapse_group, .{ .id = value.group, .collapsed = value.collapsed });
            },
        }
        return t.finish(r);
    }

    fn rename(t: *GroupSession, r: *transition.Round(GroupSession), name: *const group.Name, id: ?u64) void {
        if (!group.validName(name.slice())) t.rejection = .invalid_group_name else if (id == null) t.rejection = .unknown_group else if (t.duplicate) |duplicate| {
            if (duplicate.group_id.get() != id.?) t.rejection = .group_name_exists;
        } else r.write(rename_group, .{ .id = id.?, .name = name.slice() });
    }

    fn finish(t: *GroupSession, r: *transition.Round(GroupSession)) !transition.Next(GroupSession) {
        t.answer = .{ .accepted = t.rejection == null };
        if (t.rejection) |code| try t.answer.code.set(@tagName(code));
        try command_domain.queueCommand(r, t.input.command.key.slice(), .session_group, t.input.command.session.slice(), &t.digest, null, null, &t.answer);
        if (r.faults().before_commit) return error.InjectedCommitFailure;
        return .commit;
    }

    pub fn committed(t: *const GroupSession) Result {
        return if (t.rejection) |code| .{ .rejected = .{ .replayed = false, .code = code } } else .{ .accepted = .{ .replayed = false } };
    }
};

pub fn brief(row: anytype) error{CorruptStore}!?group.Brief {
    const id = row.group_id orelse return null;
    const name = row.group_name orelse return error.CorruptStore;
    if (!group.validName(name.slice())) return error.CorruptStore;
    return .{ .id = id.get(), .name = name, .collapsed = row.group_collapsed orelse return error.CorruptStore, .revision = (row.group_revision orelse return error.CorruptStore).get() };
}
