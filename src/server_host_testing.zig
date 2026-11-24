const platform = @import("platform.zig");
const server_host = @import("server_host.zig");

const Host = server_host.Host;
const Lifecycle = server_host.Lifecycle;

pub const TestParts = struct {
    lifecycle: Lifecycle,

    pub fn attach(self: *TestParts, host: *Host, lease: ?*platform.StoreLease) void {
        self.lifecycle = .init(host.io, lease, false, null);
        host.lifecycle = &self.lifecycle;
    }
};
