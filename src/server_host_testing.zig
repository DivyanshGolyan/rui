const std = @import("std");
const platform = @import("platform.zig");
const server_host = @import("server_host.zig");
const ModelLists = @import("ModelLists.zig");
const SessionEnvironments = @import("SessionEnvironments.zig");
const bash = @import("bash.zig");
const core_tools = @import("core_tools.zig");
const environment = @import("environment.zig");
const output_retention = @import("output_retention.zig");
const product_defaults = @import("product_defaults.zig");
const providers_module = @import("providers.zig");
const protocol = @import("protocol.zig");
const settings_handoff = @import("host_settings_handoff.zig");
const store_module = @import("store.zig");

const Lifecycle = server_host.Lifecycle;
const Probes = server_host.Probes;

/// The parts a served Host carried, with the fields and defaults tests set by name. Tests build one
/// as a literal and hand it to the testing_parts helpers of the owners that take Shared and Settings.
pub const Fixture = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    lease: *platform.StoreLease,
    store: *store_module.Store,
    lifecycle: *Lifecycle = undefined,
    /// Set by TestParts.attach before any owner reads probes.
    probes: *Probes = undefined,
    instance: protocol.InstanceId = undefined,
    limits: server_host.Limits = .{},
    providers: *const providers_module.Providers = &providers_module.none,
    presets: []const core_tools.Preset = &.{},
    model_lists: ModelLists = .{},
    bash_facts: environment.HostFacts = bash.default_facts,
    environments: ?*SessionEnvironments = null,
    mcp_servers: @import("mcp/servers.zig").Servers = .{},
    retention: *output_retention.Queue = undefined,
    intake_capacity: usize = product_defaults.intake_capacity,
    descriptor_soft_limit: ?usize = null,
    scratch_used: std.atomic.Value(u64) = .init(0),
    started_at: u64 = 0,
    settings_digest: ?settings_handoff.Digest = null,
    allowance_diagnostic: server_host.AllowanceDiagnostic = .{},
};

pub const TestParts = struct {
    lifecycle: Lifecycle,
    probes: Probes = .{},

    pub fn attach(self: *TestParts, host: *Fixture, lease: *platform.StoreLease) void {
        self.attachWithWake(host, lease, null);
    }

    pub fn attachWithWake(self: *TestParts, host: *Fixture, lease: *platform.StoreLease, intake_wake: ?@import("std").posix.fd_t) void {
        self.lifecycle = .init(host.io, lease, false, intake_wake);
        host.lifecycle = &self.lifecycle;
        self.probes = .{ .io = host.io };
        host.probes = &self.probes;
    }
};
