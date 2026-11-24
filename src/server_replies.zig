//! The answers a Host gives its requests. Intake admits a request and hands it to `Replies.prepare`, which
//! reads the Store and writes one Answer into the request's Reply. A report captured into report scratch
//! is sealed whole or discarded whole.

const std = @import("std");
const os = @import("os");
const socket_os = os.socket;
const platform = @import("platform.zig");
const protocol = @import("protocol.zig");
const command_spec = @import("command_spec.zig");
const core_tools = @import("core_tools.zig");
const execution = @import("execution.zig");
const failed_responses = @import("failed_responses.zig");
const host_drain = @import("host_drain.zig");
const host_reply = @import("host_reply.zig");
const host_settings = @import("host_settings.zig");
const output_retention = @import("output_retention.zig");
const SessionEnvironments = @import("SessionEnvironments.zig");
const server_mcp_relist = @import("server_mcp_relist.zig");
const server_host = @import("server_host.zig");
const server_reply = @import("server_reply.zig");
const server_mcp_settings = @import("server_mcp_settings.zig");
const TestObservation = @import("TestObservation.zig");
const session_list_reply = @import("session_list_reply.zig");
const session_report_reply = @import("session_report_reply.zig");
const store_module = @import("store.zig");
const wire_request = @import("wire_request.zig");
const heap_unfilled = @import("heap_unfilled.zig");
const activity_reply = @import("activity_reply.zig");
const builtin = @import("builtin");
const TestParts = if (builtin.is_test) @import("server_host_testing.zig").TestParts else void;
const sendReply = server_reply.sendReply;
const Host = server_host.Host;
const Lifecycle = server_host.Lifecycle;
const Probes = server_host.Probes;
const Answer = server_reply.Answer;
const Reply = server_reply.Reply;
const ControlTiming = server_reply.ControlTiming;
const refuse = server_reply.refuse;
const createUnfilled = heap_unfilled.createUnfilled;
const executionFacts = server_host.executionFacts;
const nowNs = server_host.nowNs;

/// Where a request is answered: the Store identity and Host instance it must match, the admission drop
/// the test hooks ask for, and the request itself with the environment and input its Intake has read.
pub const Prepared = struct {
    socket: std.posix.fd_t,
    drop: DropMode,
    /// The Host instance the request named, when it named one.
    instance: ?protocol.InstanceId,
    /// Whether the request's route is host_stop, which must name its Host instance.
    needs_instance: bool,
    number: u64,
    accepted_at_ns: u64,
    request: *wire_request.Request,
    environment: ?*SessionEnvironments.Offer,
    parts: ?@import("InputCapture.zig").Loan,
};

pub const DropMode = enum { none, before_admission, during_admission, after_commit };

/// The Host's answers. `init` reads the Host once, for the facts a reply shows. The Store, Lifecycle and Probes are
/// shared, and `host` is read only for the Execution facts of a report, the MCP listings a request asks for, and the
/// model lists.
pub const Replies = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    host: *Host,
    lease: *const platform.StoreLease,
    store: *store_module.Store,
    lifecycle: *Lifecycle,
    probes: *Probes,
    retention: *output_retention.Queue,
    custody: *const execution.CustodyPool,
    scratch_used: *const std.atomic.Value(u64),
    instance: protocol.InstanceId,
    intake_capacity: usize,
    descriptor_soft_limit: ?usize,
    started_at: u64,
    settings_digest: ?@import("host_settings_handoff.zig").Digest,
    routes: protocol.Routes,
    presets: []const core_tools.Preset,
    environments: ?*SessionEnvironments,
    bash_home: ?[]const u8,

    /// A send that failed while the Store is fenced fences the Host dispatch on the phase that failed.
    fn fenceIfStoreFailed(self: *Replies, phase: []const u8, err: anyerror) void {
        if (self.store.isFenced()) self.lifecycle.fenceDispatch(phase, err);
    }

    pub fn init(host: *Host) Replies {
        return .{
            .io = host.io,
            .allocator = host.allocator,
            .host = host,
            .lease = host.lease,
            .store = host.store,
            .lifecycle = host.lifecycle,
            .probes = host.probes,
            .retention = host.retention,
            .custody = &host.custody,
            .scratch_used = &host.scratch_used,
            .instance = host.instance,
            .intake_capacity = host.intake_capacity,
            .descriptor_soft_limit = host.descriptor_soft_limit,
            .started_at = host.started_at,
            .settings_digest = host.settings_digest,
            .routes = routes: {
                const served_set = host.providers.served();
                break :routes protocol.routesOf(&served_set);
            },
            .presets = host.presets,
            .environments = host.environments,
            .bash_home = host.bash_facts.home,
        };
    }

    /// Answers one admitted request into `reply`. The Store identity, the Host instance and the admission drops
    /// are judged here; each request kind is then answered by its own reader.
    pub fn prepare(self: *Replies, reply: *Reply, prepared: Prepared) !void {
        const request = prepared.request;
        if (!matchesStore(std.meta.activeTag(request.*), request.store(), self.lease.paths.store_identity.slice())) {
            return refuse(reply, 409, .invocation_error, "wrong_store_identity");
        }
        if (prepared.instance) |instance| {
            if (!std.mem.eql(u8, &instance, &self.instance)) return refuse(reply, 409, .invocation_error, "host_instance_changed");
        }
        if (prepared.needs_instance and prepared.instance == null) {
            return refuse(reply, 400, .invocation_error, "host_instance_required");
        }
        if (prepared.drop == .before_admission) return;
        if (prepared.drop == .during_admission and socket_os.shutdown(prepared.socket, std.c.SHUT.RDWR) == .failed) {
            return error.InjectedDisconnectFailed;
        }
        const number = prepared.number;
        switch (request.*) {
            .host_info => try Replies.replyHostInfo(self, reply),
            .host_pause => |pause| try Replies.replyHostPause(self, reply, pause),
            .host_stop => |stop| try Replies.replyHostStop(self, reply, stop, prepared.drop),
            .configure => |*command| try Replies.prepareConfigure(self, reply, prepared.drop, command),
            .message => |*command| try Replies.replyMessage(self, reply, command, prepared.drop, prepared.environment, prepared.parts),
            inline .session_stop, .session_archive, .session_pin, .model_interruption, .permission_decision, .action_background, .action_stop => |*command, tag| try Replies.replyControl(self, reply, prepared.drop, prepared.accepted_at_ns, comptime @field(command_spec.CommandKind, @tagName(tag)), command),
            .action_publish => |*command| try Replies.replyActionPublish(self, reply, command),
            .observe_command => |*command| try Replies.replyObserveCommand(self, reply, command),
            .read_result => |*command| try Replies.replyReadResult(self, reply, command),
            .read_action => |*command| try Replies.replyReadAction(self, reply, command),
            .read_action_arguments => |*command| Replies.deliverActionContent(self, reply, command, false),
            .read_action_call_id => |*command| Replies.deliverActionContent(self, reply, command, true),
            .inspect_session => |*request_value| try Replies.replyInspectSession(self, reply, request_value, number),
            .list_sessions => |*request_value| try Replies.replyListSessions(self, reply, request_value, number),
            .conversation_page => |*command| try Replies.replyConversationPage(self, reply, command),
            .conversation_content => |*command| try Replies.prepareConversationContent(self, reply, command),
            .activity_page => |*command| try Replies.replyActivityPage(self, reply, command),
            .activity_search => |*command| try Replies.replyActivitySearch(self, reply, command),
            .public_parts => |*command| try Replies.replyPublicParts(self, reply, command, number),
            .public_part_content => |*command| try Replies.replyPublicPartContent(self, reply, command),
            .activity_content => |*command| try Replies.replyActivityContent(self, reply, command),
            .skill_suggestions => |*command| try Replies.replySkillSuggestions(self, reply, command),
            .model_list => try Replies.replyModelList(self, reply),
            .tools_reload => |*reload| try Replies.replyToolsReload(self, reply, reload),
            .tools_status => try Replies.replyToolsStatus(self, reply),
        }
    }

    fn publishControlHint(self: *Replies, command_key: []const u8) void {
        if (self.probes.suppressFirstControlHint()) {
            self.probes.traceSubject("control_hint_suppressed", "command_key", command_key);
            return;
        }
        self.lifecycle.noteControlsChanged();
        self.probes.traceSubject("control_hint_published", "command_key", command_key);
    }

    pub noinline fn submitMessage(self: *Replies, command: *const wire_request.MessageCommand, offer: *SessionEnvironments.Offer, receipt: ?*@import("creation_receipt.zig").Configuration) error{OutOfMemory}!store_module.MessageReply {
        return Replies.submitMessageInput(self, command, offer, null, receipt);
    }

    fn submitMessageInput(self: *Replies, command: *const wire_request.MessageCommand, offer: *SessionEnvironments.Offer, loan: ?@import("InputCapture.zig").Loan, receipt: ?*@import("creation_receipt.zig").Configuration) error{OutOfMemory}!store_module.MessageReply {
        std.debug.assert(offer.value() != null);
        defer offer.deinit(self.allocator);
        var memory: std.heap.ArenaAllocator = .init(self.allocator);
        defer memory.deinit();
        const skill_owner = @import("session_skills.zig");
        const prepared = (if (loan) |parts|
            skill_owner.prepareMessageParts(memory.allocator(), self.allocator, self.io, self.store, command, self.bash_home, parts)
        else
            skill_owner.prepareMessage(memory.allocator(), self.allocator, self.io, self.store, command, self.bash_home)) catch |err| {
            if (self.store.isFenced()) return .infrastructure_failure;
            return if (err == error.OutOfMemory) error.OutOfMemory else .infrastructure_failure;
        };
        const initial_skills = prepared.initial;
        const captured_skill = prepared.captured;
        const faults = self.probes.storeFaults(.command);
        if (command.configuration) |*configuration| if (configuration.parent.state == .value) {
            var inheritance = @import("child_environment.zig").Inheritance.init(self.environments, configuration.parent.value.slice(), self.allocator, memory.allocator()) catch |err| {
                if (self.store.isFenced()) return .infrastructure_failure;
                return if (err == error.OutOfMemory) error.OutOfMemory else .infrastructure_failure;
            };
            defer inheritance.deinit(self.allocator);
            return submitMessageInputToStore(self.store, command, loan, inheritance.messageCallback(), initial_skills, if (captured_skill) |*value| value else null, receipt, faults);
        };
        const environments = self.environments orelse return submitMessageInputToStore(self.store, command, loan, null, initial_skills, if (captured_skill) |*value| value else null, receipt, faults);
        const Install = struct {
            environments: *SessionEnvironments,
            offer: *SessionEnvironments.Offer,

            fn call(context: *anyopaque, admission: store_module.Store.MessageAdmission) void {
                const install: *@This() = @ptrCast(@alignCast(context));
                install.environments.offer(admission.session, .{
                    .origin = if (admission.from_peer) .peer else .person,
                    .admission = admission.admission_id,
                }, install.offer);
            }
        };
        var install: Install = .{ .environments = environments, .offer = offer };
        return submitMessageInputToStore(self.store, command, loan, .{ .context = &install, .call = Install.call }, initial_skills, if (captured_skill) |*value| value else null, receipt, faults);
    }

    pub noinline fn submitConfigure(self: *Replies, command: *const wire_request.ConfigureCommand, receipt: ?*@import("creation_receipt.zig").Configuration) error{OutOfMemory}!store_module.ConfigureReply {
        const name = command.preset orelse return Replies.configureCapturedSkills(self, command, null, receipt);
        var decision: store_module.PresetDecision = .{ .request_digest = command.presetRequestDigest() };
        if (command.session.len != 0) {
            decision.rejection = .preset_on_update;
            return try self.store.configureWithCreationCommittedInto(command, &decision, null, null, self.allocator, null, receipt, self.probes.storeFaults(.command));
        }
        const preset = for (self.presets) |*entry| {
            if (std.mem.eql(u8, entry.name, name.slice())) break entry;
        } else {
            decision.rejection = .unknown_preset;
            return try self.store.configureWithCreationCommittedInto(command, &decision, null, null, self.allocator, null, receipt, self.probes.storeFaults(.command));
        };
        var memory: std.heap.ArenaAllocator = .init(self.allocator);
        defer memory.deinit();
        const arena = memory.allocator();
        const resolved = try arena.create(wire_request.ConfigureCommand);
        resolved.* = .{
            .store = command.store,
            .key = command.key,
            .session = command.session,
            .require_model = command.require_model,
            .reload_skills = command.reload_skills,
        };
        const checked = core_tools.parseAgentSpec(arena, preset.spec, &resolved.configuration) catch |err| return Replies.configureFailure(self, err);
        std.debug.assert(checked == .accepted);
        overlayConfiguration(&resolved.configuration, &command.configuration);
        return Replies.configureCapturedSkills(self, resolved, &decision, receipt);
    }

    fn configureFailure(self: *Replies, err: anyerror) error{OutOfMemory}!store_module.ConfigureReply {
        if (self.store.isFenced()) return .infrastructure_failure;
        return if (err == error.OutOfMemory) error.OutOfMemory else .infrastructure_failure;
    }

    noinline fn configureCapturedSkills(self: *Replies, command: *const wire_request.ConfigureCommand, preset: ?*const store_module.PresetDecision, receipt: ?*@import("creation_receipt.zig").Configuration) error{OutOfMemory}!store_module.ConfigureReply {
        var memory: std.heap.ArenaAllocator = .init(self.allocator);
        defer memory.deinit();
        const reload_capture: ?store_module.CapturedSkill = if (command.reload_skills and !(self.store.commandExists(command.key.slice()) catch return .infrastructure_failure))
            @import("session_skills.zig").capture(memory.allocator(), self.allocator, self.io, self.store, command.session.slice(), &.{ .operation = .reload }, self.bash_home) catch |err| return Replies.configureFailure(self, err)
        else
            null;
        const initial_skills = if (command.session.len == 0 and !command.reload_skills)
            @import("session_skills.zig").initial(memory.allocator(), self.allocator, self.io, self.store, command.key.slice(), &command.configuration, self.bash_home) catch |err| return Replies.configureFailure(self, err)
        else
            null;
        var inheritance = if (command.session.len == 0 and command.configuration.parent.state == .value)
            @import("child_environment.zig").Inheritance.init(self.environments, command.configuration.parent.value.slice(), self.allocator, memory.allocator()) catch |err| return Replies.configureFailure(self, err)
        else
            @import("child_environment.zig").Inheritance{ .environments = null };
        defer inheritance.deinit(self.allocator);
        return self.store.configureWithCreationCommittedInto(command, preset, initial_skills, if (reload_capture) |*value| value else null, self.allocator, inheritance.creationCallback(), receipt, self.probes.storeFaults(.command));
    }

    fn submitControl(self: *Replies, comptime kind: command_spec.CommandKind, command: *const @FieldType(wire_request.Request, @tagName(kind)), faults: store_module.Faults) host_reply.MutationResult(kind) {
        return switch (kind) {
            .session_stop => self.store.stopSession(command, faults),
            .session_archive => self.store.archiveSession(command, faults),
            .session_pin => self.store.pinSession(command, faults),
            .model_interruption => self.store.interruptModel(command, faults),
            .permission_decision => self.store.decidePermission(command, faults),
            .action_background => self.store.backgroundAction(.{ .command = command }, faults),
            .action_stop => self.store.requestActionStop(command, faults),
            .configure, .message => @compileError("control admission requires a control kind"),
        };
    }

    // Returns false only for the deliberate post-commit drop, so controls keep the
    // original timing lifetime even when reply allocation itself cannot succeed.
    /// The answer to a mutation's result, or null for the deliberate post-commit drop.
    fn mutationAnswer(self: *Replies, allocator: std.mem.Allocator, drop: DropMode, comptime kind: command_spec.CommandKind, subject: host_reply.MutationSubject(kind), result: host_reply.MutationResult(kind)) !?Answer {
        if (result == .infrastructure_failure) self.lifecycle.fenceDispatch(command_spec.spec(kind).fence_message, error.CanonicalStoreFailure);
        if (drop == .after_commit and result != .infrastructure_failure) return null;
        return try Answer.json(allocator, host_reply.httpStatus(result), @max(command_spec.spec(kind).Reply(protocol).max_bytes, protocol.max_control_error_response_bytes), .reserved, host_reply.renderMutationReply(kind), .{ subject, result });
    }

    fn answerMutation(self: *Replies, fd: *Reply, drop: DropMode, comptime kind: command_spec.CommandKind, subject: host_reply.MutationSubject(kind), result: host_reply.MutationResult(kind)) !bool {
        const answer = (try Replies.mutationAnswer(self, server_reply.allocatorOf(fd), drop, kind, subject, result)) orelse return false;
        _ = try fd.start(answer, .{});
        return true;
    }

    fn answerControl(self: *Replies, fd: *Reply, drop: DropMode, comptime kind: command_spec.CommandKind, subject: host_reply.MutationSubject(kind), result: host_reply.MutationResult(kind), timing: ControlTiming, key: []const u8) !void {
        comptime std.debug.assert(command_spec.spec(kind).is_control);
        // Acceptance and infrastructure failure are disjoint. The hint precedes
        // every reply effect, including the deliberate post-commit drop.
        if (result == .accepted) Replies.publishControlHint(self, key);
        const answer = (try Replies.mutationAnswer(self, server_reply.allocatorOf(fd), drop, kind, subject, result)) orelse return;
        _ = try fd.start(answer, .{ .timing = timing });
    }

    noinline fn prepareConfigure(self: *Replies, fd: *Reply, drop: DropMode, command: *const wire_request.ConfigureCommand) !void {
        // One bounded receipt per active creating exchange; ordinary exchanges
        // are limited by Host intake capacity. It lives only through encoding.
        const receipt = if (command.session.len == 0) try createUnfilled(self.allocator, @import("creation_receipt.zig").Configuration) else null;
        defer if (receipt) |value| self.allocator.destroy(value);
        _ = try Replies.answerMutation(self, fd, drop, .configure, command.session.slice(), try Replies.submitConfigure(self, command, receipt));
    }

    noinline fn replyHostInfo(self: *Replies, fd: *Reply) !void {
        if (!self.lifecycle.launchAllowed()) return refuse(fd, 503, .host_unavailable, "dispatch_fenced");
        try replyJson(fd, 200, protocol.max_host_info_response_bytes, host_reply.renderHostInfo, .{host_reply.HostInfo{
            .store = self.lease.paths.store_identity.slice(),
            .instance = self.instance,
            .active_capacity = self.custody.records.len,
            .intake_capacity = self.intake_capacity,
            .descriptor_soft_limit = self.descriptor_soft_limit,
            .started_at = self.started_at,
            .custody_occupied = self.custody.held(),
            .paused = self.lifecycle.turnsHeld(),
            .routes = self.routes,
            .doublewrite = self.store.admissionDiagnostic().doublewrite,
            .settings_digest = self.settings_digest,
        }});
    }

    noinline fn replyHostPause(self: *Replies, fd: *Reply, pause: @FieldType(wire_request.Request, "host_pause")) !void {
        if (!self.lifecycle.launchAllowed()) return refuse(fd, 503, .host_unavailable, "dispatch_fenced");
        self.lifecycle.setTurnsPaused(pause.paused);
        // A drain's hold outlasts an operator's release; reply the hold in force.
        try replyJson(fd, 200, comptime protocol.shapeBytes(protocol.host_pause_reply), host_reply.renderHostPause, .{self.lifecycle.turnsHeld()});
    }

    noinline fn replyHostStop(self: *Replies, fd: *Reply, stop: @FieldType(wire_request.Request, "host_stop"), drop: DropMode) !void {
        const bound = host_drain.Bound.seconds(stop.drain_seconds) catch unreachable;
        const answer = self.lifecycle.askStop(bound);
        if (answer == .stop_now) self.lifecycle.wakeListener();
        if (drop == .after_commit) return;
        switch (answer) {
            .stop_now, .already_stopping => try replyJson(fd, 200, protocol.host_stop_ack.len, protocol.JsonOut.append, .{protocol.host_stop_ack}),
            .drain => |drain| {
                const left_ms = (drain.until_ns -| nowNs(self.io)) / std.time.ns_per_ms;
                const until_unix_ms = (std.math.cast(u64, store_module.readUnixMilliseconds(self.io) catch 0) orelse 0) +| left_ms;
                try replyJson(fd, 200, comptime protocol.shapeBytes(protocol.host_drain_reply), host_reply.renderHostDrain, .{until_unix_ms});
            },
        }
    }

    noinline fn replyMessage(self: *Replies, fd: *Reply, command: *@FieldType(wire_request.Request, "message"), drop: DropMode, client_environment: ?*SessionEnvironments.Offer, parts: ?@import("InputCapture.zig").Loan) !void {
        if ((command.text.state == .value) == (parts != null)) return error.InvalidMessage;
        const receipt = if (command.configuration != null) try createUnfilled(self.allocator, @import("creation_receipt.zig").Configuration) else null;
        defer if (receipt) |value| self.allocator.destroy(value);
        _ = try Replies.answerMutation(self, fd, drop, .message, command.session.slice(), try Replies.submitMessageInput(self, command, client_environment.?, parts, receipt));
    }

    noinline fn replyControl(self: *Replies, fd: *Reply, drop: DropMode, accepted_at_ns: u64, comptime kind: command_spec.CommandKind, command: *const @FieldType(wire_request.Request, @tagName(kind))) !void {
        var timing = ControlTiming.init(self.probes, self.io, command.key, @tagName(kind), accepted_at_ns);
        const result = Replies.submitControl(self, kind, command, self.probes.storeFaults(.{ .control = timing.storeTrace() }));
        try Replies.answerControl(self, fd, drop, kind, controlSubject(kind, command), result, timing, command.key.slice());
    }

    noinline fn replyActionPublish(self: *Replies, fd: *Reply, command: *@FieldType(wire_request.Request, "action_publish")) !void {
        if (command.text.length > protocol.max_action_value_bytes) return refuse(fd, 409, .invocation_error, "too_large");
        const bytes = try self.allocator.alloc(u8, @intCast(command.text.length));
        defer self.allocator.free(bytes);
        const count = try command.text.file.?.readPositionalAll(self.io, bytes, 0);
        if (count != bytes.len) return error.UnexpectedEndOfFile;
        const result = self.store.publishActionValue(command.handle.slice(), command.key.slice(), bytes) catch |err| {
            self.lifecycle.fenceDispatch("action value publication", err);
            return refuse(fd, 500, .invocation_error, "canonical_store_failure");
        };
        switch (result) {
            .accepted => |receipt| try replyJson(fd, 200, comptime protocol.shapeBytes(protocol.action_publish_reply), renderActionValueReceipt, .{receipt}),
            .refused => |reason| return refuse(fd, 409, .invocation_error, @tagName(reason)),
        }
    }

    noinline fn replyObserveCommand(self: *Replies, fd: *Reply, command: *@FieldType(wire_request.Request, "observe_command")) !void {
        var observation: store_module.Observed = undefined;
        self.store.observeCommand(command.key.slice(), command.since, &observation) catch |err| return Replies.refuseRead(self, fd, "command observation", err);
        switch (observation) {
            .full => self.probes.traceCommandObservation(command.key.slice(), "request_observation_full"),
            .not_modified => |token| if (command.since) |since| {
                self.probes.traceCommandObservation(command.key.slice(), if (token.generation > since.generation)
                    "request_observation_tier2"
                else
                    "request_observation_tier1");
            },
        }
        try replyJson(fd, 200, host_reply.commandObservationBytes(&observation), host_reply.renderCommandObservation, .{ command.key.slice(), &observation });
    }

    noinline fn replyReadResult(self: *Replies, fd: *Reply, command: *@FieldType(wire_request.Request, "read_result")) !void {
        const reference = self.store.commandResult(command.key.slice()) catch |err| switch (err) {
            error.ResultNotFound => return refuse(fd, 409, .result_unavailable, "result_not_found"),
            error.ResultNotReady => return refuse(fd, 409, .result_unavailable, "result_not_ready"),
            error.ResultFailed => return refuse(fd, 409, .result_unavailable, "result_failed"),
            else => return Replies.refuseRead(self, fd, "result observation", err),
        };
        const location = self.store.openContent(reference) catch |err| return Replies.refuseRead(self, fd, "result content read", err);
        _ = try fd.start(.{ .content = .{ .location = location, .start = 0, .stream = true, .public = false } }, .{});
    }

    noinline fn replyReadAction(self: *Replies, fd: *Reply, command: *@FieldType(wire_request.Request, "read_action")) !void {
        const value = try createUnfilled(self.allocator, @import("action_read.zig").Read);
        defer self.allocator.destroy(value);
        self.store.readAction(command, value) catch |err| switch (err) {
            error.ActionNotFound => return refuse(fd, 404, .action_unavailable, "action_not_found"),
            error.InvalidCursor => return refuse(fd, 400, .action_unavailable, "invalid_cursor"),
            else => return Replies.refuseRead(self, fd, "Action status observation", err),
        };
        try replyJson(fd, 200, protocol.action_read_reply.max_bytes, host_reply.renderActionRead, .{value});
    }

    noinline fn replyInspectSession(self: *Replies, fd: *Reply, request_value: *@FieldType(wire_request.Request, "inspect_session"), request_number: u64) !void {
        if (request_value.failed_response != null) return Replies.replyFailedResponse(self, fd, request_value, request_number);
        const state = createUnfilled(self.allocator, SessionReportState) catch |err| return Replies.refuseRead(self, fd, "session inspection", err);
        defer self.allocator.destroy(state);
        const report = (ReportScratch{ .replies = self }).capture(&state.capture, request_number, SessionReportExport{
            .replies = self,
            .request = request_value,
            .reply = &state.reply,
        }) catch |err| {
            if (err == error.ReportScratchCleanupFailed) return ReportScratch.cleanupFailed(self, fd, "session report scratch cleanup", err);
            return Replies.refuseRead(self, fd, "session inspection", err);
        };
        const gated = try fd.start(.{ .report = .{ .status = 200, .content_type = "application/json", .value = report } }, .{ .hold = self.probes.hooks.inspection_reply });
        self.probes.traceSubject("inspection_captured", "session", request_value.session.slice());
        self.probes.traceSqliteDiagnostic(self.store, request_value.session.slice());
        if (gated) self.probes.traceSubject("test_gate_waiting", "path", self.probes.hooks.inspection_reply.gate_path.?);
    }

    /// Answers a failed-response export. The binding is read before any scratch exists, and the capture stays on this
    /// frame (noinline) so that session inspections do not carry its 4 KiB buffer.
    noinline fn replyFailedResponse(self: *Replies, fd: *Reply, request: *const protocol.InspectSession, request_number: u64) !void {
        const selection = request.failed_response.?;
        const binding = self.store.failedResponseBinding(request.session.slice(), selection.operation, selection.attempt) catch |err| return Replies.failedResponseRefused(self, fd, err);
        var storage: store_module.SessionReportCapture = undefined;
        const capture = (ReportScratch{ .replies = self }).capture(&storage, request_number, FailedResponseExport{
            .replies = self,
            .binding = binding,
            .part = selection.part,
        }) catch |err| {
            if (err == error.ReportScratchCleanupFailed) return ReportScratch.cleanupFailed(self, fd, "failed response export scratch cleanup", err);
            return Replies.failedResponseRefused(self, fd, err);
        };
        _ = try fd.start(.{ .report = .{ .status = 200, .content_type = "application/octet-stream", .value = capture } }, .{});
    }

    fn failedResponseRefused(self: *Replies, fd: *Reply, err: anyerror) void {
        if (self.store.isFenced()) {
            self.lifecycle.fenceDispatch("failed response identity", err);
            return refuse(fd, 500, .invocation_error, "canonical_store_failure");
        }
        refuse(fd, 409, .failed_response_unavailable, @errorName(err));
    }

    noinline fn replyListSessions(self: *Replies, fd: *Reply, request_value: *@FieldType(wire_request.Request, "list_sessions"), request_number: u64) !void {
        if (request_value.since) |since| {
            if (request_value.changed == null and self.store.notModified(since)) {
                return replyJson(fd, 200, protocol.max_response_bytes, host_reply.renderSessionsNotModified, .{since});
            }
        }
        request_value.validate() catch |err| return Replies.refuseRead(self, fd, "Session list", err);
        var storage: store_module.SessionReportCapture = undefined;
        const page = (ReportScratch{ .replies = self }).capture(&storage, request_number, SessionListExport{ .replies = self, .request = request_value }) catch |err| {
            if (err == error.ReportScratchCleanupFailed) return ReportScratch.cleanupFailed(self, fd, "Session list scratch cleanup", err);
            return Replies.refuseRead(self, fd, "Session list", err);
        };
        _ = try fd.start(.{ .report = .{ .status = 200, .content_type = "application/json", .value = page } }, .{});
    }

    noinline fn replyConversationPage(self: *Replies, fd: *Reply, command: *@FieldType(wire_request.Request, "conversation_page")) !void {
        const page = try createUnfilled(self.allocator, store_module.PublicConversationPage);
        defer self.allocator.destroy(page);
        self.store.publicConversationPage(command, page, self.allocator) catch |err| switch (err) {
            error.SessionNotFound, error.InvalidCursor => return refuse(fd, 409, .conversation_unavailable, @errorName(err)),
            else => return Replies.refuseRead(self, fd, "conversation page", err),
        };
        try replyJson(fd, 200, protocol.max_conversation_page_response_bytes, host_reply.renderConversationPage, .{page});
    }

    noinline fn replyActivityPage(self: *Replies, fd: *Reply, command: *@FieldType(wire_request.Request, "activity_page")) !void {
        const page = try createUnfilled(self.allocator, protocol.ActivityFacts);
        defer self.allocator.destroy(page);
        self.store.activityPage(command, page) catch |err| switch (err) {
            error.SessionNotFound, error.InvalidCursor => return refuse(fd, 409, .activity_unavailable, @errorName(err)),
            else => return Replies.refuseRead(self, fd, "activity page", err),
        };
        try replyJson(fd, 200, host_reply.activityPageBytes(page), host_reply.renderActivityPage, .{page});
    }

    noinline fn replyActivitySearch(self: *Replies, fd: *Reply, command: *@FieldType(wire_request.Request, "activity_search")) !void {
        const page = try createUnfilled(self.allocator, protocol.ActivitySearchFacts);
        defer self.allocator.destroy(page);
        self.store.searchActivity(command, page) catch |err| switch (err) {
            error.SessionNotFound, error.InvalidCursor => return refuse(fd, 409, .activity_unavailable, @errorName(err)),
            else => return Replies.refuseRead(self, fd, "activity search", err),
        };
        try replyJson(fd, 200, activity_reply.max_search_bytes, host_reply.renderActivitySearch, .{page});
    }

    noinline fn replyPublicParts(self: *Replies, fd: *Reply, command: *@FieldType(wire_request.Request, "public_parts"), request_number: u64) !void {
        var storage: store_module.SessionReportCapture = undefined;
        const report = (ReportScratch{ .replies = self }).capture(&storage, request_number, PublicPartsExport{ .replies = self, .command = command }) catch |err| switch (err) {
            error.ContentNotFound, error.ContentIsText => return refuse(fd, 409, .parts_unavailable, @errorName(err)),
            error.ReportScratchCleanupFailed => return ReportScratch.cleanupFailed(self, fd, "public parts scratch cleanup", err),
            else => return Replies.refuseRead(self, fd, "public parts", err),
        };
        _ = try fd.start(.{ .report = .{ .status = 200, .content_type = "application/json", .value = report } }, .{});
    }

    noinline fn replyPublicPartContent(self: *Replies, fd: *Reply, command: *@FieldType(wire_request.Request, "public_part_content")) !void {
        const location = self.store.openPublicPart(command.session.slice(), command.owner, command.part, command.start) catch |err| switch (err) {
            error.ContentNotFound, error.ContentIsText, error.RangeOutOfBounds => return refuse(fd, 409, .parts_unavailable, @errorName(err)),
            else => return Replies.refuseRead(self, fd, "public part content", err),
        };
        try Replies.deliverPublicContent(self, fd, location, command.start, command.stream);
    }

    noinline fn replyActivityContent(self: *Replies, fd: *Reply, command: *@FieldType(wire_request.Request, "activity_content")) !void {
        const location = self.store.openActivityContent(command) catch |err| switch (err) {
            error.ContentNotFound, error.ContentIsParts => return refuse(fd, 409, .activity_unavailable, @errorName(err)),
            else => return Replies.refuseRead(self, fd, "activity content", err),
        };
        try Replies.deliverPublicContent(self, fd, location, 0, true);
    }

    noinline fn replySkillSuggestions(self: *Replies, fd: *Reply, command: *@FieldType(wire_request.Request, "skill_suggestions")) !void {
        const scope: @import("skill_suggestions.zig").Scope = if (command.session) |*session| .{ .session = session.slice() } else .{ .workspace = command.workspace.?.slice() };
        var page = Replies.readSkillSuggestions(self, self.allocator, scope, command.prefix.slice()) catch |err| {
            if (err == error.CanonicalStoreFailure) return refuse(fd, 500, .invocation_error, "canonical_store_failure");
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return refuse(fd, 409, .activity_unavailable, if (err == error.SessionNotFound) "SessionNotFound" else "skills_unavailable");
        };
        defer page.deinit(self.allocator);
        try replyJsonGrowing(fd, 200, protocol.skill_suggestions_reply.max_bytes, host_reply.renderSkillSuggestions, .{&page});
    }

    noinline fn replyModelList(self: *Replies, fd: *Reply) !void {
        self.host.listings_requested.store(true, .release);
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const facts = self.store.readModelCatalog(arena.allocator()) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            self.lifecycle.fenceDispatch("model catalog", err);
            return refuse(fd, 500, .invocation_error, "canonical_store_failure");
        };
        try replyJsonGrowing(fd, 200, protocol.model_list_reply.maxBytes(facts), renderModelList, .{ self, facts });
    }

    pub fn readSkillSuggestions(self: *Replies, allocator: std.mem.Allocator, scope: @import("skill_suggestions.zig").Scope, prefix: []const u8) !@import("skill_suggestions.zig").Page {
        return @import("session_skills.zig").suggestions(allocator, self.allocator, self.io, self.store, scope, prefix, self.bash_home) catch |err| {
            if (scope == .session and self.store.isFenced()) {
                self.lifecycle.fenceDispatch("skill suggestions", err);
                return error.CanonicalStoreFailure;
            }
            return err;
        };
    }

    /// Asks the execution owner to list one server, or every configured server. Asking only records a
    /// request, so the reply needs no wait: the caller polls tools_status for each asked generation.
    noinline fn replyToolsReload(self: *Replies, fd: *Reply, request: *const @FieldType(wire_request.Request, "tools_reload")) !void {
        if (!self.lifecycle.launchAllowed()) return refuse(fd, 503, .host_unavailable, "dispatch_fenced");
        var asked_by_owner: [host_settings.max_mcp_servers]server_mcp_relist.Relist.Asked = undefined;
        const count = server_host.askMcpLists(self.host, if (request.server) |name| name.slice() else null, &asked_by_owner);
        if (request.server != null and count == 0) return refuse(fd, 400, .invocation_error, "unknown_mcp_server");
        var asked: [host_settings.max_mcp_servers]host_reply.ToolAsk = undefined;
        for (asked_by_owner[0..count], asked[0..count]) |ask, *each| each.* = .{ .server = ask.server, .generation = ask.generation };
        try replyJson(fd, 200, protocol.tools_reload_reply.maxBytes(host_settings.max_mcp_servers), host_reply.renderToolsReload, .{ self.instance, asked[0..count] });
    }

    /// Reads every configured server's published list status. Lock-free: it never waits for the owner.
    noinline fn replyToolsStatus(self: *Replies, fd: *Reply) !void {
        var rows: [host_settings.max_mcp_servers]host_reply.ToolServerStatus = undefined;
        var count: usize = 0;
        if (self.host.mcp_relist) |owner| {
            for (owner.servers, 0..) |*server, index| {
                rows[count] = .{ .server = server.name.slice(), .status = owner.status(index), .listen = owner.streamState(index) };
                count += 1;
            }
        }
        try replyJson(fd, 200, protocol.tools_status_reply.maxBytes(host_settings.max_mcp_servers), host_reply.renderToolsStatus, .{ self.instance, rows[0..count] });
    }

    fn deliverConversationContent(self: *Replies, fd: std.posix.fd_t, command: protocol.ConversationContent) !void {
        var reply: Reply = undefined;
        reply.init(self.io, self.allocator, null);
        defer reply.deinit();
        try Replies.prepareConversationContent(self, &reply, &command);
        sendReply(self.io, fd, &reply) catch |err| self.fenceIfStoreFailed("public content", err);
    }

    noinline fn prepareConversationContent(self: *Replies, fd: *Reply, command: *const protocol.ConversationContent) !void {
        const location = self.store.openPublicConversationContent(command) catch |err| switch (err) {
            error.ContentNotFound, error.RangeOutOfBounds, error.ContentIsParts => return refuse(fd, 409, .conversation_unavailable, @errorName(err)),
            else => return Replies.refuseRead(self, fd, "conversation content", err),
        };
        return Replies.deliverPublicContent(self, fd, location, command.start, command.stream);
    }

    fn deliverPublicContent(self: *Replies, fd: *Reply, location: store_module.ContentLocation, start: u64, stream: bool) !void {
        _ = fd.start(.{ .content = .{ .location = location, .start = start, .stream = stream, .public = true } }, .{}) catch |err| {
            self.lifecycle.fenceDispatch("public content", err);
            fd.deinit();
            return refuse(fd, 500, .invocation_error, "canonical_store_failure");
        };
    }

    noinline fn deliverActionContent(self: *Replies, fd: *Reply, command: anytype, comptime call_id: bool) void {
        const phase = if (call_id) "Action call identity observation" else "Action argument observation";
        const reference = if (call_id)
            self.store.actionCallId(command.session.slice(), command.action_id)
        else
            self.store.actionArguments(command.session.slice(), command.action_id);
        const resolved = reference catch |err| switch (err) {
            error.ActionNotFound => return refuse(fd, 404, .action_unavailable, "action_not_found"),
            else => return Replies.refuseRead(self, fd, phase, err),
        };
        const location = self.store.openContent(resolved) catch |err| return Replies.refuseRead(self, fd, phase, err);
        _ = fd.start(.{ .content = .{ .location = location, .start = 0, .stream = true, .public = false } }, .{}) catch {};
    }

    /// The Store owns which read failures are fatal: it fences itself for those and returns the
    /// rest as ordinary refusals. Dispatch fences only after it.
    fn refuseRead(self: *Replies, reply: *Reply, phase: []const u8, err: anyerror) void {
        if (self.store.isFenced()) {
            self.lifecycle.fenceDispatch(phase, err);
            return refuse(reply, 500, .invocation_error, "canonical_store_failure");
        }
        refuse(reply, if (err == error.ReportScratchExhausted) 507 else 500, .observation_error, @errorName(err));
    }
};

/// The one owner of report scratch. A capture takes its budget from the live retention queue, creates its file
/// under the lease's scratch path, and is sealed whole or discarded whole. The caller supplies the storage, so each
/// reply keeps its own allocation points: heap where the reply already holds state, stack otherwise.
const ReportScratch = struct {
    replies: *Replies,

    fn capture(self: ReportScratch, storage: *store_module.SessionReportCapture, request_number: u64, producer: anytype) !store_module.SessionReport {
        storage.* = .{ .io = self.replies.io, .writer = null, .budget = self.replies.retention.sharedBudget() };
        try storage.create(self.replies.lease.paths.scratch.slice(), request_number, self.replies.probes.fails(.report_unlink));
        errdefer storage.deinit();
        try producer.produce(storage);
        return storage.seal();
    }

    /// The one answer for a report whose scratch could not be cleaned up: dispatch fences on the read's phase and
    /// the read answers 500.
    fn cleanupFailed(replies: *Replies, reply: *Reply, phase: []const u8, err: anyerror) void {
        replies.lifecycle.fenceDispatch(phase, err);
        refuse(reply, 500, .observation_error, "report_scratch_cleanup_failed");
    }
};

/// Failed-response export of one record; its binding was read before any scratch existed.
const FailedResponseExport = struct {
    replies: *Replies,
    binding: store_module.AttemptBinding,
    part: protocol.FailedResponsePart,

    fn produce(self: FailedResponseExport, storage: *store_module.SessionReportCapture) !void {
        try failed_responses.exportRecord(self.replies.io, self.replies.lease.store_dir, self.binding, self.part, storage);
    }
};

/// Heap state of one session report: the Store fills `reply` while the capture holds the bytes.
const SessionReportState = struct {
    capture: store_module.SessionReportCapture,
    reply: session_report_reply.Reply(store_module.SessionReportCapture),
};

const SessionReportExport = struct {
    replies: *Replies,
    request: *const protocol.InspectSession,
    reply: *session_report_reply.Reply(store_module.SessionReportCapture),

    fn produce(self: SessionReportExport, storage: *store_module.SessionReportCapture) !void {
        self.reply.init(storage, executionFacts(self.replies.host));
        try self.replies.store.readSessionReport(self.request.session.slice(), self.request.profile, self.reply);
    }
};

const SessionListExport = struct {
    replies: *Replies,
    request: *const protocol.ListSessions,

    fn produce(self: SessionListExport, storage: *store_module.SessionReportCapture) !void {
        const reply = try createUnfilled(self.replies.allocator, session_list_reply.Reply(store_module.SessionReportCapture));
        defer self.replies.allocator.destroy(reply);
        reply.capture = storage;
        reply.rows = 0;
        const list_pages = try createUnfilled(self.replies.allocator, store_module.SessionListPages);
        defer self.replies.allocator.destroy(list_pages);
        try self.replies.store.readSessionList(self.request, reply, list_pages);
    }
};

/// Certifies the owner's parts once, then writes the whole list into the capture. A fault mid-walk discards the
/// capture, so no partial list is ever delivered.
const PublicPartsExport = struct {
    replies: *Replies,
    command: *const protocol.PublicParts,

    fn produce(self: PublicPartsExport, storage: *store_module.SessionReportCapture) !void {
        var reader = try store_module.PublicParts.Reader.init(self.command.session, self.command.owner);
        defer reader.deinit();
        var writer: protocol.public_parts_reply.Writer(store_module.SessionReportCapture) = .{ .capture = storage, .session = self.command.session.slice() };
        while (true) switch (try self.replies.store.readPublicParts(&reader)) {
            .pending => {},
            .certified => |value| try writer.head(value),
            .part => |part| try writer.part(part),
            .done => break,
        };
        try writer.finish();
    }
};

fn submitMessageInputToStore(
    store: *store_module.Store,
    command: *const wire_request.MessageCommand,
    loan: ?@import("InputCapture.zig").Loan,
    committed: ?store_module.Store.MessageCommitted,
    initial: ?*const store_module.InitialSkills,
    captured: ?*const store_module.CapturedMessageSkills,
    receipt: ?*@import("creation_receipt.zig").Configuration,
    faults: store_module.Faults,
) store_module.MessageReply {
    if (loan) |parts| return store.submitMessagePartsCapturedSkillsInto(command, parts, committed, initial, captured, receipt, faults) catch .infrastructure_failure;
    return store.submitMessageCapturedSkillsInto(command, committed, initial, captured, receipt, faults);
}

fn overlayConfiguration(base: *wire_request.Configuration, override: *const wire_request.Configuration) void {
    inline for (@import("session_settings.zig").spec_entries) |entry| {
        const field = &@field(override, entry.field);
        if (field.state != .omitted) @field(base, entry.field) = field.*;
    }
    if (override.preferences) |preferences| base.preferences = preferences;
}

test "preset overlay retains or replaces the whole preferences object" {
    var base: wire_request.Configuration = .{ .preferences = .{} };
    base.preferences.?.reasoning_effort.state = .value;
    try base.preferences.?.reasoning_effort.value.set("high");
    overlayConfiguration(&base, &.{});
    try std.testing.expectEqualStrings("high", base.preferences.?.reasoning_effort.value.slice());
    overlayConfiguration(&base, &.{ .preferences = .{} });
    try std.testing.expectEqual(protocol.FieldState.omitted, base.preferences.?.reasoning_effort.state);
}

fn controlSubject(comptime kind: command_spec.CommandKind, command: *const @FieldType(wire_request.Request, @tagName(kind))) host_reply.MutationSubject(kind) {
    return switch (kind) {
        .session_stop, .session_archive, .session_pin => command.session.slice(),
        .model_interruption => .{ .session = command.session, .turn_id = command.turn_id, .operation_id = command.operation_id },
        .permission_decision => .{ .session = command.session, .action_id = command.action_id, .decision = command.decision },
        .action_background, .action_stop => .{ .session = command.session, .action_id = command.action_id },
        .configure, .message => @compileError("control subject requires a control kind"),
    };
}

fn matchesStore(kind: std.meta.Tag(wire_request.Request), supplied: []const u8, expected: []const u8) bool {
    return (kind == .host_info and supplied.len == 0) or std.mem.eql(u8, supplied, expected);
}

test "settings readiness discovers the canonical Store only through host info" {
    for (std.enums.values(std.meta.Tag(wire_request.Request))) |kind| {
        for ([_][]const u8{ "/canonical/sqlite", "0123456789abcdef0123456789abcdef" }) |identity| {
            try std.testing.expect(matchesStore(kind, identity, identity));
            try std.testing.expect(!matchesStore(kind, "wrong-identity", identity));
            try std.testing.expectEqual(kind == .host_info, matchesStore(kind, "", identity));
        }
    }
}

fn renderModelList(out: protocol.JsonOut, self: *Replies, facts: []const @import("model_catalog.zig").Entry) error{BufferTooLarge}!void {
    out.writer.writeAll(protocol.model_list_reply.head) catch return error.BufferTooLarge;
    self.host.model_lists.render(out.writer, facts) catch return error.BufferTooLarge;
    out.writer.writeAll(protocol.model_list_reply.tail) catch return error.BufferTooLarge;
}

fn renderActionValueReceipt(out: protocol.JsonOut, receipt: anytype) !void {
    try out.appendShape(protocol.action_publish_reply, .{ receipt.action_id, receipt.ordinal, receipt.admission_id, receipt.replayed });
}

/// Answers a JSON body rendered by `render`, sized up front. A reply whose allocation fails sends nothing.
fn replyJson(fd: *Reply, status: u16, max_bytes: usize, comptime render: anytype, args: anytype) !void {
    _ = try fd.start(try Answer.json(server_reply.allocatorOf(fd), status, max_bytes, .reserved, render, args), .{});
}

/// Answers a JSON body rendered by `render`, grown as it is written.
fn replyJsonGrowing(fd: *Reply, status: u16, max_bytes: usize, comptime render: anytype, args: anytype) !void {
    _ = try fd.start(try Answer.json(server_reply.allocatorOf(fd), status, max_bytes, .growing, render, args), .{});
}

test "Conversation stream native delivery reads each byte once and closes on failed handoff" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/store.sqlite", .{root});
    var storage: store_module.Store = undefined;
    try storage.open(std.testing.io, path, root);
    defer storage.close() catch unreachable;
    const expected = @as([8189]u8, @splat('x')) ++ @as([257 * "é中🙂\n\\\"/".len]u8, @bitCast(@as([257]["é中🙂\n\\\"/".len]u8, @splat("é中🙂\n\\\"/".*)))) ++ "tail";
    var command = try store_module.testingPublicProjection(&storage, &tmp, &.{
        .{ .encoded = &@as([8189]u8, @splat('x')), .decoded = &@as([8189]u8, @splat('x')) },
        .{ .encoded = @as([257 * "\\u00e9\\u4e2d\\ud83d\\ude42\\n\\\\\\\"\\/".len]u8, @bitCast(@as([257]["\\u00e9\\u4e2d\\ud83d\\ude42\\n\\\\\\\"\\/".len]u8, @splat("\\u00e9\\u4e2d\\ud83d\\ude42\\n\\\\\\\"\\/".*)))) ++ "tail", .decoded = @as([257 * "é中🙂\n\\\"/".len]u8, @bitCast(@as([257]["é中🙂\n\\\"/".len]u8, @splat("é中🙂\n\\\"/".*)))) ++ "tail" },
    });
    command.stream = true;
    var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = &storage };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);
    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets));
    defer _ = std.c.close(sockets[0]);
    defer _ = std.c.close(sockets[1]);
    const Peer = struct {
        fd: std.posix.fd_t,
        returned: std.posix.fd_t,
        received: [expected.len + 320]u8 = undefined,
        used: usize = 0,
        failed: bool = false,

        /// Darwin can mark a Unix socket's end without waking a reader
        /// blocked on it: in #934, recv saw EOF while this peer's read slept
        /// 1200 s. So the peer never waits for EOF. It waits for bytes or
        /// for delivery to return, and reads only what is already queued.
        fn drain(self: *@This()) void {
            while (true) {
                var ready = [_]std.c.pollfd{
                    .{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 },
                    .{ .fd = self.returned, .events = std.posix.POLL.IN, .revents = 0 },
                };
                const polled = std.c.poll(&ready, ready.len, -1);
                if (polled < 0) {
                    if (std.posix.errno(polled) == .INTR) continue;
                    self.failed = true;
                    return;
                }
                while (true) {
                    if (self.used == self.received.len) {
                        self.failed = true;
                        return;
                    }
                    const count = std.c.recv(self.fd, self.received[self.used..].ptr, self.received.len - self.used, std.c.MSG.DONTWAIT);
                    if (count < 0) switch (std.posix.errno(count)) {
                        .INTR => continue,
                        .AGAIN => break,
                        else => {
                            self.failed = true;
                            return;
                        },
                    };
                    if (count == 0) return;
                    self.used += @intCast(count);
                }
                if (ready[1].revents != 0) return;
            }
        }
    };
    var returned: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&returned));
    defer _ = std.c.close(returned[0]);
    defer _ = std.c.close(returned[1]);
    var peer = Peer{ .fd = sockets[1], .returned = returned[0] };
    storage.testing_content_work = .{};
    {
        const thread = try std.Thread.spawn(.{}, Peer.drain, .{&peer});
        defer {
            std.debug.assert(std.c.write(returned[1], "r", 1) == 1);
            thread.join();
        }
        var replies = Replies.init(&host);
        try Replies.deliverConversationContent(&replies, sockets[0], command);
    }
    try std.testing.expectEqual(@as(u64, expected.len), storage.testing_content_work.read.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), storage.testing_content_work.closes.load(.monotonic));
    try std.testing.expect(!storage.isFenced());
    try std.testing.expect(!peer.failed);
    const body_start = (std.mem.indexOf(u8, peer.received[0..peer.used], "\r\n\r\n") orelse return error.MissingHeaders) + 4;
    try std.testing.expectEqualStrings(expected, peer.received[body_start..peer.used]);
    storage.testing_content_work = .{};
    var replies = Replies.init(&host);
    try Replies.deliverConversationContent(&replies, -1, command);
    try std.testing.expectEqual(@as(u64, protocol.content_window_bytes), storage.testing_content_work.read.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), storage.testing_content_work.closes.load(.monotonic));
    try std.testing.expect(!storage.isFenced());
}

test "presets seed configure before Store validation and idempotency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var path_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/store.sqlite", .{root});
    var storage: store_module.Store = undefined;
    try storage.open(std.testing.io, path, root);
    defer storage.close() catch unreachable;
    var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer memory.deinit();
    const arena = memory.allocator();
    const spec = (try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"model":"gpt-6.1-sol","effort":"low","compactAt":10000,"tools":[],"permissionMode":"ask","provider":"openai","instructions":"Preset instructions","outputSchema":{"type":"object"},"label":"Preset label"}
    , .{})).object;
    const presets = [_]core_tools.Preset{.{ .name = "review", .spec = spec }};
    var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = &storage, .presets = &presets };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);
    const create = try arena.create(wire_request.ConfigureCommand);
    create.* = .{ .preset = .{} };
    try create.preset.?.set("review");
    try create.key.set("preset-create");
    create.configuration.workspace.state = .value;
    try create.configuration.workspace.value.set(root);
    const reload = try arena.create(wire_request.ConfigureCommand);
    reload.* = .{ .preset = create.preset, .reload_skills = true };
    try reload.key.set("skills-reload-preset-empty");
    var replies = Replies.init(&host);
    const reload_refused = try Replies.submitConfigure(&replies, reload, null);
    try std.testing.expect(reload_refused == .rejected);
    try std.testing.expectEqual(protocol.ConfigurationRejection.unknown_session, reload_refused.rejected.code);
    replies = Replies.init(&host);
    try std.testing.expect((try Replies.submitConfigure(&replies, reload, null)).rejected.replayed);
    reload.reload_skills = false;
    replies = Replies.init(&host);
    try std.testing.expect(try Replies.submitConfigure(&replies, reload, null) == .conflict);
    replies = Replies.init(&host);
    const first = try Replies.submitConfigure(&replies, create, null);
    try std.testing.expect(first == .accepted);
    try std.testing.expect(!first.accepted.replayed);
    const session = first.accepted.session;
    var observed = try storage.inspectSessionForTesting(session.slice());
    try std.testing.expectEqualStrings("gpt-6.1-sol", observed.model.slice());
    try std.testing.expectEqual(@as(?u64, 10000), observed.compaction_trigger_override);
    try std.testing.expectEqual(protocol.ReasoningEffort.low, observed.reasoning_effort_override.?);
    try std.testing.expectEqualStrings("ask", observed.permission_mode.slice());
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest("Preset instructions"), &observed.instructions.digest);
    try std.testing.expect(observed.output_schema != null);
    replies = Replies.init(&host);
    const replay = try Replies.submitConfigure(&replies, create, null);
    try std.testing.expect(replay == .accepted and replay.accepted.replayed);
    try std.testing.expectEqualStrings(session.slice(), replay.accepted.session.slice());
    try std.testing.expectEqual(first.accepted.revision, replay.accepted.revision);

    const override = try arena.create(wire_request.ConfigureCommand);
    override.* = .{ .preset = create.preset };
    try override.key.set("preset-overrides");
    override.configuration.model.state = .value;
    try override.configuration.model.value.set("preset-override-model");
    override.configuration.provider.state = .value;
    try override.configuration.provider.value.set("codex");
    override.configuration.workspace.state = .value;
    try override.configuration.workspace.value.set(root);
    override.configuration.reasoning_effort.state = .explicit_null;
    override.configuration.compaction_trigger.state = .value;
    try override.configuration.compaction_trigger.value.set("12000");
    override.configuration.tools = try .of(&.{"start_agent"});
    override.configuration.permission_mode.state = .value;
    try override.configuration.permission_mode.value.set("bypass");
    override.configuration.label.state = .explicit_null;
    override.configuration.output_schema.state = .explicit_null;
    override.configuration.instructions = .{
        .state = .value,
        .borrowed = "Overridden instructions".ptr,
        .length = "Overridden instructions".len,
        .digest = protocol.contentDigest("Overridden instructions"),
    };
    replies = Replies.init(&host);
    const overridden = try Replies.submitConfigure(&replies, override, null);
    try std.testing.expect(overridden == .accepted);
    try storage.inspectSession(overridden.accepted.session.slice(), &observed);
    try std.testing.expectEqualStrings("preset-override-model", observed.model.slice());
    try std.testing.expectEqualStrings("codex", observed.provider.?.slice());
    try std.testing.expectEqualStrings(root, observed.workspace.slice());
    try std.testing.expectEqual(@as(?u64, 12000), observed.compaction_trigger_override);
    try std.testing.expectEqual(@import("configuration_defaults.zig").startEffort(@import("model_catalog.zig").shipped, "preset-override-model"), observed.reasoning_effort_override);
    try std.testing.expectEqualStrings("bypass", observed.permission_mode.slice());
    try std.testing.expectEqual(@as(u64, 1), try store_module.testing.queryU64(&storage, "SELECT count(*) FROM tool_set_member WHERE tool_set_id=?1", .{observed.tool_set_id}));
    try std.testing.expectEqual(@as(u64, 1), try store_module.testing.queryU64(&storage, "SELECT count(*) FROM tool_set_member member JOIN tool_record tool ON tool.tool_record_id=member.tool_record_id WHERE member.tool_set_id=?1 AND tool.name='start_agent'", .{observed.tool_set_id}));
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest("Overridden instructions"), &observed.instructions.digest);
    try std.testing.expect(observed.output_schema == null);

    const edited_spec = (try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"model":"gpt-6-sol","effort":"low","compactAt":10000,"tools":[],"permissionMode":"ask","provider":"openai","instructions":"Preset instructions","outputSchema":{"type":"object"},"label":"Preset label"}
    , .{})).object;
    const edited_presets = [_]core_tools.Preset{.{ .name = "review", .spec = edited_spec }};
    host.presets = &edited_presets;
    replies = Replies.init(&host);
    const same = try Replies.submitConfigure(&replies, override, null);
    try std.testing.expect(same == .accepted and same.accepted.replayed);
    try std.testing.expectEqualStrings(overridden.accepted.session.slice(), same.accepted.session.slice());
    replies = Replies.init(&host);
    try std.testing.expect(try Replies.submitConfigure(&replies, create, null) == .conflict);
    try storage.inspectSession(session.slice(), &observed);
    try std.testing.expectEqualStrings("gpt-6.1-sol", observed.model.slice());

    const invalid = try arena.create(wire_request.ConfigureCommand);
    invalid.* = .{ .preset = create.preset };
    try invalid.key.set("preset-invalid-resolved");
    invalid.configuration.workspace.state = .value;
    try invalid.configuration.workspace.value.set(root);
    invalid.configuration.compaction_trigger.state = .value;
    try invalid.configuration.compaction_trigger.value.set("0");
    replies = Replies.init(&host);
    const refused = try Replies.submitConfigure(&replies, invalid, null);
    try std.testing.expect(refused == .rejected);
    try std.testing.expectEqual(protocol.ConfigurationRejection.invalid_compaction_trigger, refused.rejected.code);
    host.presets = &.{};
    replies = Replies.init(&host);
    try std.testing.expect(try Replies.submitConfigure(&replies, create, null) == .conflict);
    const missing = try arena.create(wire_request.ConfigureCommand);
    missing.* = .{ .preset = create.preset };
    try missing.key.set("preset-missing");
    replies = Replies.init(&host);
    const unknown = try Replies.submitConfigure(&replies, missing, null);
    try std.testing.expect(unknown == .rejected);
    try std.testing.expectEqual(protocol.ConfigurationRejection.unknown_preset, unknown.rejected.code);
    host.presets = &presets;
    replies = Replies.init(&host);
    const refused_again = try Replies.submitConfigure(&replies, missing, null);
    try std.testing.expect(refused_again == .rejected and refused_again.rejected.replayed);
    try std.testing.expectEqual(protocol.ConfigurationRejection.unknown_preset, refused_again.rejected.code);
    invalid.session = session;
    try invalid.key.set("preset-on-update");
    replies = Replies.init(&host);
    const update = try Replies.submitConfigure(&replies, invalid, null);
    try std.testing.expect(update == .rejected);
    try std.testing.expectEqual(protocol.ConfigurationRejection.preset_on_update, update.rejected.code);
    replies = Replies.init(&host);
    const update_replay = try Replies.submitConfigure(&replies, invalid, null);
    try std.testing.expect(update_replay == .rejected and update_replay.rejected.replayed);
    try std.testing.expectEqual(protocol.ConfigurationRejection.preset_on_update, update_replay.rejected.code);
}

test "MCP list routes ask one named server or every server, refuse unknown or fenced asks, and report the Host instance" {
    const io = std.testing.io;
    const instance_hex = "7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e";
    var docs: server_mcp_settings.Server = .{};
    try docs.name.set("docs");
    var notes: server_mcp_settings.Server = .{};
    try notes.name.set("notes");
    const servers = [_]server_mcp_settings.Server{ docs, notes };
    var owner = server_mcp_relist.Relist.init(std.testing.allocator, &servers, 1);
    defer owner.deinit();
    var host = Host{ .io = io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .mcp_relist = &owner, .instance = @splat(0x7e) };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);

    // An unknown server is refused, and no list is asked.
    var request: @FieldType(wire_request.Request, "tools_reload") = .{};
    request.server = .{};
    try request.server.?.set("missing");
    {
        var reply: Reply = undefined;
        reply.init(io, std.testing.allocator, null);
        defer reply.deinit();
        var replies = Replies.init(&host);
        try Replies.replyToolsReload(&replies, &reply, &request);
        const wire = try server_reply.sentWire(io, std.testing.allocator, &reply);
        defer std.testing.allocator.free(wire);
        try std.testing.expect(std.mem.startsWith(u8, wire, "HTTP/1.1 400 "));
        try std.testing.expect(std.mem.indexOf(u8, server_reply.bodyOf(wire), "\"code\":\"unknown_mcp_server\"") != null);
    }
    try std.testing.expectEqual(@as(u64, 0), owner.asks[0].load(.acquire) + owner.asks[1].load(.acquire));
    try std.testing.expect(!host.lifecycle.dispatchWakeIsSet());

    // A fenced Host refuses the ask before recording it.
    _ = host.lifecycle.advance(.stopping);
    {
        var reply: Reply = undefined;
        reply.init(io, std.testing.allocator, null);
        defer reply.deinit();
        request.server = null;
        var replies = Replies.init(&host);
        try Replies.replyToolsReload(&replies, &reply, &request);
        const wire = try server_reply.sentWire(io, std.testing.allocator, &reply);
        defer std.testing.allocator.free(wire);
        try std.testing.expect(std.mem.startsWith(u8, wire, "HTTP/1.1 503 "));
        try std.testing.expect(std.mem.indexOf(u8, server_reply.bodyOf(wire), "dispatch_fenced") != null);
    }
    try std.testing.expectEqual(@as(u64, 0), owner.asks[0].load(.acquire) + owner.asks[1].load(.acquire));
    host_parts.attach(&host, undefined);

    // A named server asks only its own list, and the reply carries the Host instance.
    request.server = .{};
    try request.server.?.set("notes");
    {
        var reply: Reply = undefined;
        reply.init(io, std.testing.allocator, null);
        defer reply.deinit();
        var replies = Replies.init(&host);
        try Replies.replyToolsReload(&replies, &reply, &request);
        const wire = try server_reply.sentWire(io, std.testing.allocator, &reply);
        defer std.testing.allocator.free(wire);
        try std.testing.expect(std.mem.startsWith(u8, wire, "HTTP/1.1 200 "));
        try std.testing.expectEqualStrings("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"tools_reload_reply\",\"instance\":\"" ++ instance_hex ++ "\",\"asked\":[{\"server\":\"notes\",\"generation\":\"1\"}]}", server_reply.bodyOf(wire));
    }
    try std.testing.expectEqual(@as(u64, 0), owner.asks[0].load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), owner.asks[1].load(.acquire));
    try std.testing.expect(host.lifecycle.dispatchWakeIsSet());

    // Without a server name every configured server is asked, in configured order.
    host.lifecycle.resetDispatchWake();
    request.server = null;
    {
        var reply: Reply = undefined;
        reply.init(io, std.testing.allocator, null);
        defer reply.deinit();
        var replies = Replies.init(&host);
        try Replies.replyToolsReload(&replies, &reply, &request);
        const wire = try server_reply.sentWire(io, std.testing.allocator, &reply);
        defer std.testing.allocator.free(wire);
        try std.testing.expectEqualStrings("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"tools_reload_reply\",\"instance\":\"" ++ instance_hex ++ "\",\"asked\":[{\"server\":\"docs\",\"generation\":\"1\"},{\"server\":\"notes\",\"generation\":\"2\"}]}", server_reply.bodyOf(wire));
    }
    try std.testing.expect(host.lifecycle.dispatchWakeIsSet());

    // The status reply lists every configured server, lock-free, with the same instance.
    {
        var reply: Reply = undefined;
        reply.init(io, std.testing.allocator, null);
        defer reply.deinit();
        var replies = Replies.init(&host);
        try Replies.replyToolsStatus(&replies, &reply);
        const wire = try server_reply.sentWire(io, std.testing.allocator, &reply);
        defer std.testing.allocator.free(wire);
        try std.testing.expectEqualStrings("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"tools_status\",\"instance\":\"" ++ instance_hex ++ "\",\"servers\":[{\"server\":\"docs\",\"state\":\"idle\",\"last\":\"never\",\"finished\":\"0\",\"tools\":\"0\",\"left_out\":\"0\",\"listen\":\"off\"},{\"server\":\"notes\",\"state\":\"idle\",\"last\":\"never\",\"finished\":\"0\",\"tools\":\"0\",\"left_out\":\"0\",\"listen\":\"off\"}]}", server_reply.bodyOf(wire));
    }

    // A Host with no MCP servers answers empty lists, and an unnamed ask asks nothing.
    var bare = Host{ .io = io, .allocator = std.testing.allocator, .lease = undefined, .store = undefined, .instance = @splat(0x7e) };
    var bare_parts: TestParts = undefined;
    bare_parts.attach(&bare, undefined);
    {
        var reply: Reply = undefined;
        reply.init(io, std.testing.allocator, null);
        defer reply.deinit();
        var bare_replies = Replies.init(&bare);
        try Replies.replyToolsReload(&bare_replies, &reply, &.{});
        const wire = try server_reply.sentWire(io, std.testing.allocator, &reply);
        defer std.testing.allocator.free(wire);
        try std.testing.expectEqualStrings("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"tools_reload_reply\",\"instance\":\"" ++ instance_hex ++ "\",\"asked\":[]}", server_reply.bodyOf(wire));
    }
    {
        var reply: Reply = undefined;
        reply.init(io, std.testing.allocator, null);
        defer reply.deinit();
        var bare_replies = Replies.init(&bare);
        try Replies.replyToolsStatus(&bare_replies, &reply);
        const wire = try server_reply.sentWire(io, std.testing.allocator, &reply);
        defer std.testing.allocator.free(wire);
        try std.testing.expectEqualStrings("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"tools_status\",\"instance\":\"" ++ instance_hex ++ "\",\"servers\":[]}", server_reply.bodyOf(wire));
    }
    try std.testing.expect(!bare.lifecycle.dispatchWakeIsSet());
}

test "configure parent inherits the Host environment only after a fresh creation" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var lease: platform.StoreLease = undefined;
    lease.paths = .{};
    try lease.paths.scratch.set(root);
    try lease.paths.store_identity.set("s");
    var storage: store_module.Store = undefined;
    try store_module.testing.testingSqliteStore(&storage, &tmp, io);
    defer storage.close() catch unreachable;
    var environments: SessionEnvironments = undefined;
    try environments.init(io, allocator);
    defer environments.deinit();
    var host: Host = .{ .io = io, .allocator = allocator, .lease = &lease, .store = &storage, .environments = &environments };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, &lease);
    var create = try store_module.testing.completeConfiguration("env-parent", "", root, "model-a");
    create.configuration.tools = try .of(&.{"bash"});
    const parent_reply = try storage.configure(&create, .{});
    const parent = parent_reply.accepted.session;
    var offer = try SessionEnvironments.Offer.init(allocator, 4);
    defer offer.deinit(allocator);
    @memcpy(offer.room(), "A=1\x00");
    environments.offer(parent.slice(), .{ .origin = .person, .admission = 1 }, &offer);
    var child: wire_request.ConfigureCommand = .{};
    try child.key.set("env-child");
    child.configuration = (try store_module.testingCompleteConfiguration("unused", "", root, "model-a")).configuration;
    child.configuration.workspace.state = .omitted;
    child.configuration.provider.state = .omitted;
    child.configuration.tools = try .of(&.{"bash"});
    try child.configuration.permission_mode.value.set("ask");
    child.configuration.parent.state = .value;
    try child.configuration.parent.value.set(parent.slice());
    var replies = Replies.init(&host);
    const result = try Replies.submitConfigure(&replies, &child, null);
    try std.testing.expect(result == .accepted);
    const session = result.accepted.session;
    const copied = (try environments.copy(session.slice(), allocator)).?;
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("A=1\x00", copied);
    const count = environments.len;
    var newer = try SessionEnvironments.Offer.init(allocator, 4);
    defer newer.deinit(allocator);
    @memcpy(newer.room(), "B=2\x00");
    environments.offer(parent.slice(), .{ .origin = .person, .admission = 2 }, &newer);
    replies = Replies.init(&host);
    const replay = try Replies.submitConfigure(&replies, &child, null);
    try std.testing.expect(replay == .accepted and replay.accepted.replayed);
    const retained = (try environments.copy(session.slice(), allocator)).?;
    defer allocator.free(retained);
    try std.testing.expectEqualStrings("A=1\x00", retained);
    try child.key.set("env-child-refused");
    child.configuration.provider.state = .value;
    try child.configuration.provider.value.set("codex");
    replies = Replies.init(&host);
    const refusal = try Replies.submitConfigure(&replies, &child, null);
    try std.testing.expect(refusal == .rejected);
    try std.testing.expectEqual(protocol.ConfigurationRejection.parent_provider_forbidden, refusal.rejected.code);
    try std.testing.expectEqual(count, environments.len);
}

test "every accepted control publishes exactly one hint before reply handling" {
    const native = @import("posix");
    const Probe = struct {
        host: *Host,
        observation: *TestObservation,
        accepted: bool,
        allocations: usize = 0,
        ordered: bool = true,

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
        }

        fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.allocations += 1;
            self.ordered = self.ordered and self.host.lifecycle.controlsChangedPending() == self.accepted and
                self.observation.shared.state.load(.acquire) == @as(u64, if (self.accepted) 2 else 0);
            return std.testing.allocator.rawAlloc(len, alignment, ret_addr);
        }

        fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            return std.testing.allocator.rawResize(memory, alignment, new_len, ret_addr);
        }

        fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            return std.testing.allocator.rawRemap(memory, alignment, new_len, ret_addr);
        }

        fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            std.testing.allocator.rawFree(memory, alignment, ret_addr);
        }
    };
    var covered: std.EnumSet(command_spec.CommandKind) = .empty;
    inline for (comptime std.meta.tags(command_spec.CommandKind)) |kind| {
        if (comptime !command_spec.spec(kind).is_control) continue;
        covered.insert(kind);
        const Result = host_reply.MutationResult(kind);
        const rejected: Result = .{ .rejected = .{ .replayed = false, .code = .invalid_session_reference } };
        for ([_]Result{ MutationWitness.accepted(kind), rejected, .conflict, .infrastructure_failure }) |initial| {
            for ([_]bool{ false, true }) |replayed| {
                for ([_]bool{ false, true }) |drop| {
                    var descriptors: [2]c_int = undefined;
                    try std.testing.expectEqual(@as(c_int, 0), native.pipe(&descriptors));
                    defer _ = native.close(descriptors[0]);
                    for (descriptors) |fd| try std.testing.expectEqual(@as(c_int, 0), native.fcntl(fd, native.F_SETFL, @as(c_int, native.O_NONBLOCK)));
                    const backing = native.tmpfile() orelse return error.TestUnexpectedResult;
                    defer _ = native.fclose(backing);
                    try std.testing.expectEqual(@as(c_int, 0), native.ftruncate(native.fileno(backing), TestObservation.state_bytes));
                    var observation = try TestObservation.init(descriptors[1], native.dup(native.fileno(backing)), .control, 37);
                    defer observation.close();
                    var host = Host{
                        .io = std.testing.io,
                        .allocator = std.testing.allocator,
                        .lease = undefined,
                        .store = undefined,
                    };
                    var host_parts: TestParts = undefined;
                    host_parts.attach(&host, undefined);
                    host_parts.probes.hooks = .{ .phase_trace = true };
                    host_parts.probes.observation = observation;
                    var replies = Replies.init(&host);
                    var result = initial;
                    switch (result) {
                        .accepted => |*value| value.replayed = replayed,
                        .rejected => |*value| value.replayed = replayed,
                        else => {},
                    }
                    const accepted = result == .accepted;
                    var probe: Probe = .{ .host = &host, .observation = &observation, .accepted = accepted };
                    var reply: Reply = undefined;
                    reply.init(std.testing.io, probe.allocator(), null);
                    defer reply.deinit();
                    const key = try protocol.Bounded(protocol.max_key_bytes).from("control-domain");
                    const timing = ControlTiming.init(host.probes, host.io, key, @tagName(kind), 1);
                    try Replies.answerControl(&replies, &reply, if (drop) .after_commit else .none, kind, MutationWitness.subject(kind), result, timing, key.slice());
                    try std.testing.expectEqual(accepted, host.lifecycle.controlsChangedPending());
                    try std.testing.expectEqual(@as(u64, if (accepted) 2 else 0), observation.shared.state.load(.acquire));
                    try std.testing.expect(probe.ordered);
                    const dropped = drop and result != .infrastructure_failure;
                    try std.testing.expectEqual(dropped, reply.body == .none);
                    try std.testing.expectEqual(!dropped, reply.timing != null);
                    const sent = try server_reply.sentWire(std.testing.io, std.testing.allocator, &reply);
                    defer std.testing.allocator.free(sent);
                    try std.testing.expectEqual(dropped, sent.len == 0);
                    try std.testing.expectEqual(!dropped, probe.allocations != 0);
                    try std.testing.expectEqual(result != .infrastructure_failure, host.lifecycle.launchAllowed());
                    var bytes: [TestObservation.record_bytes]u8 = undefined;
                    const count = native.read(descriptors[0], &bytes, bytes.len);
                    if (accepted) {
                        try std.testing.expect(count > 0);
                        try std.testing.expect(std.mem.indexOf(u8, bytes[0..@intCast(count)], "control_hint_published") != null);
                        try std.testing.expect(std.mem.indexOf(u8, bytes[0..@intCast(count)], key.slice()) != null);
                    } else try std.testing.expect(count < 0 and std.posix.errno(count) == .AGAIN);
                }
            }
        }
    }
    const expected: std.EnumSet(command_spec.CommandKind) = .initMany(&.{
        .session_stop, .session_archive,   .model_interruption, .permission_decision,
        .session_pin,  .action_background, .action_stop,
    });
    try std.testing.expectEqual(expected, covered);
}

test "SH-61 Host submits a sealed ordered input through Message admission" {
    const Capture = @import("InputCapture.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    var storage: store_module.Store = undefined;
    try storage.open(std.testing.io, try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite", .{root}), root);
    defer storage.close() catch unreachable;
    const configure = try store_module.testingCompleteConfiguration("parts-host-config", "", root, "model-a");
    const configured = try storage.configure(&configure, .{});
    try std.testing.expect(configured == .accepted);
    var lease: platform.StoreLease = undefined;
    lease.paths = .{};
    try lease.paths.store_identity.set(root);
    try lease.paths.scratch.set(root);
    var host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = &lease, .store = &storage };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, &lease);
    var used: std.atomic.Value(u64) = .init(0);
    const spool = try tmp.dir.createFile(std.testing.io, "parts-spool", .{ .read = true });
    const index = try tmp.dir.createFile(std.testing.io, "parts-index", .{ .read = true });
    var capture: Capture = undefined;
    capture.init(std.testing.io, spool, index, .{ .used = &used, .limit = 100000 });
    defer capture.close();
    const jpeg = @embedFile("testing/fixtures/input-baseline.jpg");
    for ([_][]const u8{ "before", jpeg, "after" }, 0..) |bytes, ordinal| {
        try capture.begin(if (ordinal == 1) .{ .image = .{ .assertion = .jpeg } } else .text, bytes.len);
        var offset: usize = 0;
        while (offset < bytes.len) {
            var allowance = bytes.len - offset;
            offset += try capture.append(bytes[offset..], &allowance, false);
        }
        try capture.end();
    }
    const loan = try capture.seal();
    var command: wire_request.MessageCommand = .{ .session = configured.accepted.session };
    try command.key.set("parts-host-message");
    var offer = try SessionEnvironments.Offer.init(std.testing.allocator, 0);
    var replies = Replies.init(&host);
    const result = try Replies.submitMessageInput(&replies, &command, &offer, loan, null);
    try std.testing.expect(result == .accepted);
    const content = result.accepted.content;
    try std.testing.expect(content == .parts);
    try std.testing.expectEqualSlices(u8, &loan.digest, &content.parts.identity.digest);
    try std.testing.expectEqualDeep(@import("content_value.zig").Owner{ .message = result.accepted.admission_id }, content.parts.owner);
    var observed: store_module.Observed = undefined;
    try storage.observeCommand(command.key.slice(), null, &observed);
    try std.testing.expectEqualDeep(content, observed.full.observation.kind.message.?.content);
}

// Captured against 5472ccf5 before the decoder refactor. This oracle checks
// exact producer bytes and complete typed outcomes for matching/mismatched
// bindings. ReplyDomainWitness independently freezes individual field edits.
pub const MutationWitness = struct {
    pub const reply = @import("protocol_reply.zig");
    pub const session = "k7m2qx";
    pub const content: store_module.ContentReference = .{ .length = 9, .digest = .{ 0xc8, 0x84, 0x92, 0x9e, 0xdd, 0xc9, 0x45, 0x02, 0xb8, 0x37, 0x7e, 0x33, 0x3d, 0xcd, 0x72, 0x80, 0x64, 0xdc, 0xb2, 0xc4, 0x57, 0xe1, 0x0c, 0x4a, 0x3c, 0xc9, 0x82, 0xde, 0xde, 0xfd, 0xcb, 0xcd } };
    pub const Hash = std.crypto.hash.sha2.Sha256;
    pub const frozen_wire_version = "20";

    pub fn named() protocol.Bounded(protocol.max_session_bytes) {
        var value: protocol.Bounded(protocol.max_session_bytes) = .{};
        value.set(session) catch unreachable;
        return value;
    }

    pub fn subject(comptime kind: command_spec.CommandKind) @typeInfo(@TypeOf(host_reply.renderMutationReply(kind))).@"fn".param_types[1].? {
        return switch (kind) {
            .model_interruption => .{ .session = named(), .turn_id = 3, .operation_id = 11 },
            .permission_decision => .{ .session = named(), .action_id = 7, .decision = .deny },
            .action_background, .action_stop => .{ .session = named(), .action_id = 7 },
            else => session,
        };
    }

    pub fn target(comptime kind: command_spec.CommandKind, wrong: bool) reply.MutationTarget {
        return switch (kind) {
            .configure => if (wrong) .session_stop else .configure,
            .message => .{ .message = .{ .bytes = content.length + @intFromBool(wrong), .digest = content.digest } },
            .session_stop => if (wrong) .configure else .session_stop,
            .session_archive => .{ .session_archive = .{ .archived = !wrong } },
            .session_pin => .{ .session_pin = .{ .pinned = wrong } },
            .model_interruption => .{ .model_interruption = .{ .turn = 3, .operation = if (wrong) 12 else 11 } },
            .permission_decision => .{ .permission_decision = .{ .action = 7, .decision = if (wrong) .allow_once else .deny } },
            .action_background => .{ .action_background = if (wrong) 8 else 7 },
            .action_stop => .{ .action_stop = if (wrong) 8 else 7 },
        };
    }

    pub fn accepted(comptime kind: command_spec.CommandKind) @typeInfo(@TypeOf(host_reply.renderMutationReply(kind))).@"fn".param_types[2].? {
        return .{ .accepted = switch (kind) {
            .configure => .{ .replayed = false, .revision = 13, .created = false, .session = named() },
            .message => .{ .replayed = false, .admission_id = 17, .content = .{ .text = content }, .session = named() },
            .session_stop => .{ .replayed = false, .selection = .{ .selected_turn_id = 19, .admission_cutoff = 23 }, .completion = .pending },
            .session_archive => .{ .replayed = false, .archived = true, .completion = .pending },
            .session_pin => .{ .replayed = false, .pinned = false },
            .model_interruption, .permission_decision => .{ .replayed = false },
            .action_background => .{ .replayed = false, .action_id = 7, .selection = .{ .kind = .background, .position = 29 } },
            .action_stop => .{ .replayed = false, .action_id = 7, .resolution = 29 },
        } };
    }

    pub fn requireFields(comptime T: type, comptime expected: []const []const u8) void {
        const actual_fields = @typeInfo(T).@"struct".field_names;
        if (actual_fields.len != expected.len) @compileError("Mutation witness field inventory changed: " ++ @typeName(T));
        for (actual_fields, expected) |field, name| {
            if (!std.mem.eql(u8, field, name)) @compileError("Mutation witness field inventory changed: " ++ @typeName(T));
        }
    }

    // The frozen producer-byte oracle was captured at the released wire version. Verify the
    // actual version first, then retain those captured bytes in the digest.
    pub fn hashResponse(hash: *Hash, body: []const u8) !void {
        const current = "{\"version\":\"" ++ protocol.wire_version ++ "\",";
        try std.testing.expect(std.mem.startsWith(u8, body, current));
        hash.update("{\"version\":\"" ++ frozen_wire_version ++ "\",");
        hash.update(body[current.len..]);
    }

    pub fn observe(hash: *Hash, body: []const u8, status: u16, supplied_session: []const u8, binding: reply.MutationTarget) !void {
        const decoded = reply.decodeMutationReply(.{ .status = status, .body = body }, supplied_session, binding);
        if (decoded.answer) |answer| {
            hash.update(@tagName(answer.result));
            hash.update(&.{@intFromBool(answer.replayed)});
            switch (answer.result) {
                .accepted => |value| {
                    // Preserve the frozen pre-receipt projection for existing
                    // replies. Hash receipt slices explicitly: Bounded backing
                    // arrays contain unused bytes and are not stable witnesses.
                    const OldConfigure = union(enum) { configure: struct { revision: u64, created: bool, skills: ?@import("mutation_answer.zig").SkillsReloadStatus } };
                    const OldMessage = union(enum) { message: struct { admission: u64 } };
                    const bytes = switch (value) {
                        .configure => |item| blk: {
                            comptime requireFields(@TypeOf(item), &.{ "revision", "created", "skills", "configuration" });
                            break :blk try std.json.Stringify.valueAlloc(std.testing.allocator, OldConfigure{ .configure = .{ .revision = item.revision, .created = item.created, .skills = item.skills } }, .{});
                        },
                        .message => |item| blk: {
                            comptime requireFields(@TypeOf(item), &.{ "admission", "configuration" });
                            break :blk try std.json.Stringify.valueAlloc(std.testing.allocator, OldMessage{ .message = .{ .admission = item.admission } }, .{});
                        },
                        else => try std.json.Stringify.valueAlloc(std.testing.allocator, value, .{}),
                    };
                    defer std.testing.allocator.free(bytes);
                    hash.update(bytes);
                    const configuration = switch (value) {
                        .configure => |item| item.configuration,
                        .message => |item| item.configuration,
                        else => null,
                    };
                    if (configuration) |item| {
                        comptime requireFields(@TypeOf(item), &.{ "provider", "model", "reasoning_effort", "workspace", "tools", "loaded_tools", "permission_mode", "compaction_trigger" });
                        const receipt = try std.json.Stringify.valueAlloc(std.testing.allocator, .{
                            .provider = item.provider,
                            .model = item.model.slice(),
                            .reasoning_effort = item.reasoning_effort,
                            .workspace = item.workspace.slice(),
                            .tools = item.tools.slice(),
                            .loaded_tools = item.loaded_tools.slice(),
                            .permission_mode = item.permission_mode,
                            .compaction_trigger = item.compaction_trigger,
                        }, .{});
                        defer std.testing.allocator.free(receipt);
                        hash.update(receipt);
                    }
                },
                .rejected => |code| hash.update(code.slice()),
                .conflict => {},
            }
            // The frozen witness hashes the original text receipt fields.
            const receipt: ?@import("mutation_answer.zig").ContentReference = if (answer.input) |value| switch (value) {
                .accepted => |accepted_input| blk: {
                    try std.testing.expect(accepted_input == .text);
                    break :blk .{ .bytes = accepted_input.text.length, .digest = accepted_input.text.digest };
                },
                .rejected => |rejected_input| blk: {
                    try std.testing.expectEqual(.text, rejected_input.form);
                    break :blk rejected_input.content;
                },
            } else null;
            const input = try std.json.Stringify.valueAlloc(std.testing.allocator, receipt, .{});
            defer std.testing.allocator.free(input);
            hash.update(input);
        } else |err| hash.update(@errorName(err));
        hash.update("\x00");
        hash.update(decoded.context.session.slice());
        hash.update("\x00");
        if (decoded.diagnostic) |diagnostic| {
            hash.update(diagnostic.type.slice());
            hash.update(diagnostic.code.slice());
        }
        hash.update("\x00");
    }

    pub const Field = struct { path: []const []const u8, value: []const u8 };
    pub const fields = [_]Field{
        .{ .path = &.{"version"}, .value = "\"" ++ protocol.wire_version ++ "\"" },
        .{ .path = &.{"type"}, .value = "\"session_pin_reply\"" },
        .{ .path = &.{"code"}, .value = "\"canonical_store_failure\"" },
        .{ .path = &.{"answer"}, .value = "{\"status\":\"accepted\",\"replayed\":false,\"session\":\"k7m2qx\"}" },
        .{ .path = &.{"input"}, .value = "{\"type\":\"text\",\"bytes\":\"9\",\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"}" },
        .{ .path = &.{"queue"}, .value = "{\"status\":\"queued\",\"admission\":\"17\"}" },
        .{ .path = &.{"execution"}, .value = "{\"status\":\"queued\"}" },
        .{ .path = &.{"completion"}, .value = "{\"status\":\"pending\"}" },
        .{ .path = &.{ "answer", "status" }, .value = "\"accepted\"" },
        .{ .path = &.{ "answer", "replayed" }, .value = "true" },
        .{ .path = &.{ "answer", "session" }, .value = "\"k7m2qx\"" },
        .{ .path = &.{ "answer", "code" }, .value = "\"unknown_session\"" },
        .{ .path = &.{ "answer", "message" }, .value = "\"detail\"" },
        .{ .path = &.{ "answer", "revision" }, .value = "\"13\"" },
        .{ .path = &.{ "answer", "created" }, .value = "false" },
        .{ .path = &.{ "answer", "skills" }, .value = "\"unchanged\"" },
        .{ .path = &.{ "answer", "admission" }, .value = "\"17\"" },
        .{ .path = &.{ "answer", "archived" }, .value = "true" },
        .{ .path = &.{ "answer", "pinned" }, .value = "false" },
        .{ .path = &.{ "answer", "action" }, .value = "\"7\"" },
        .{ .path = &.{ "answer", "decision" }, .value = "\"deny\"" },
        .{ .path = &.{ "answer", "selection" }, .value = "{\"turn\":\"19\",\"admission_cutoff\":\"23\"}" },
        .{ .path = &.{ "answer", "action_selection" }, .value = "{\"kind\":\"background\",\"position\":\"29\"}" },
        .{ .path = &.{ "answer", "target" }, .value = "{\"session\":\"k7m2qx\",\"turn\":\"3\",\"operation\":\"11\"}" },
        .{ .path = &.{ "input", "type" }, .value = "\"text\"" },
        .{ .path = &.{ "input", "bytes" }, .value = "\"9\"" },
        .{ .path = &.{ "input", "sha256" }, .value = "\"0000000000000000000000000000000000000000000000000000000000000000\"" },
        .{ .path = &.{ "queue", "status" }, .value = "\"queued\"" },
        .{ .path = &.{ "queue", "admission" }, .value = "\"17\"" },
        .{ .path = &.{ "execution", "status" }, .value = "\"unavailable\"" },
        .{ .path = &.{ "execution", "reason" }, .value = "\"direct_reply_does_not_wait_for_model_processing\"" },
        .{ .path = &.{ "completion", "status" }, .value = "\"completed\"" },
        .{ .path = &.{ "answer", "selection", "turn" }, .value = "null" },
        .{ .path = &.{ "answer", "selection", "admission_cutoff" }, .value = "\"23\"" },
        .{ .path = &.{ "answer", "target", "session" }, .value = "\"k7m2qx\"" },
        .{ .path = &.{ "answer", "target", "turn" }, .value = "\"3\"" },
        .{ .path = &.{ "answer", "target", "operation" }, .value = "\"11\"" },
        .{ .path = &.{ "answer", "action_selection", "kind" }, .value = "\"final\"" },
        .{ .path = &.{ "answer", "action_selection", "position" }, .value = "\"29\"" },
    };
};

test "SH-123 report scratch is sealed whole or discarded whole within the shared budget and a cleanup failure answers once with a fence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [platform.max_scratch_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var lease: platform.StoreLease = undefined;
    lease.paths = .{};
    try lease.paths.scratch.set(root);
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    var storage: store_module.Store = undefined;
    try storage.open(std.testing.io, try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite", .{root}), root);
    defer storage.close() catch unreachable;
    var host = Host{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = &lease, .store = &storage };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, &lease);
    var inspect: protocol.InspectSession = .{};
    try inspect.session.set("k7m2qx");
    const Row = struct {
        budget: u64,
        armed_unlink: bool = false,
        /// The Replies heap fails its first allocation.
        heap_fails: bool = false,
        status: u16,
        /// Text the sealed report carries, when one is delivered.
        carries: ?[]const u8 = null,
        fenced: bool = false,
    };
    const rows = [_]Row{
        .{ .budget = 9000, .status = 200, .carries = "session_not_found" },
        .{ .budget = 1, .status = 507 },
        .{ .budget = 9000, .heap_fails = true, .status = 500 },
        .{ .budget = 9000, .armed_unlink = true, .status = 500, .fenced = true },
    };
    for (rows) |row| {
        var retention = output_retention.Queue.initialize(host.io, root, .{ .used = &host.scratch_used, .limit = row.budget }, &.{});
        host.retention = &retention;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        host.allocator = if (row.heap_fails) failing.allocator() else std.testing.allocator;
        defer host.allocator = std.testing.allocator;
        host_parts.attach(&host, &lease);
        var replies = Replies.init(&host);
        var request: wire_request.Request = .{ .inspect_session = inspect };
        {
            var reply: Reply = undefined;
            reply.init(host.io, std.testing.allocator, null);
            defer reply.deinit();
            if (row.armed_unlink) host.probes.arm(.report_unlink);
            try replies.prepare(&reply, .{ .socket = -1, .drop = .none, .instance = null, .needs_instance = false, .number = 1, .accepted_at_ns = 0, .request = &request, .environment = null, .parts = null });
            // A sealed report holds its whole scratch until the reply releases it.
            try std.testing.expectEqual(row.carries != null, host.scratch_used.load(.acquire) != 0);
            const wire = try server_reply.sentWire(host.io, std.testing.allocator, &reply);
            defer std.testing.allocator.free(wire);
            var status_line: [32]u8 = undefined;
            try std.testing.expect(std.mem.startsWith(u8, wire, try std.fmt.bufPrint(&status_line, "HTTP/1.1 {d} ", .{row.status})));
            if (row.carries) |text| try std.testing.expect(std.mem.indexOf(u8, server_reply.bodyOf(wire), text) != null);
        }
        try std.testing.expectEqual(@as(u64, 0), host.scratch_used.load(.acquire));
        try std.testing.expectEqual(row.fenced, !host.lifecycle.launchAllowed());
    }
}
