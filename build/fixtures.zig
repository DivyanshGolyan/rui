const std = @import("std");
const screen_module = @import("screen.zig");

/// A process fixture: one build step that runs one Python script against a
/// Rui executable. tests/ci/select_tests.py selects the fixture whose row an
/// edit changes, and every fixture here when an edit changes anything else, so
/// keep each fixture's whole wiring in its row, on one line.
pub const Fixture = struct {
    step: []const u8,
    description: []const u8,
    script: []const u8,
    /// The ReleaseSafe check build, or the Debug build.
    rui: enum { release_safe, debug } = .release_safe,
    /// Reads the terminal through the PTY screen observer.
    screen: bool = false,
    /// Arguments after the Rui executable.
    args: []const []const u8 = &.{},
};

pub const fixtures = [_]Fixture{
    .{ .step = "dispatch-integration", .description = "Run the targeted model dispatch, output, retry, and recovery shortcut", .script = "tests/integration/dispatch_integration.py" },
    .{ .step = "skills-integration", .description = "Run isolated native skills capture, replay and creation cases", .script = "tests/integration/skills_integration.py", .screen = true },
    .{ .step = "login-signal-integration", .description = "Run the Linux-only one-shot login signal loader witness", .script = "tests/integration/login_signal_integration.py" },
    .{ .step = "current-facts-integration", .description = "Run the real Current producer/consumer observation oracle", .script = "tests/integration/current_facts_integration.py" },
    .{ .step = "request-wait-integration", .description = "Run request wait completion, recovery and conditional polling witnesses", .script = "tests/integration/request_wait_integration.py" },
    .{ .step = "canonical-failure-integration", .description = "Run canonical invocation failure at real producer and caller boundaries", .script = "tests/integration/canonical_failure_integration.py", .screen = true },
    .{ .step = "server-delivery-integration", .description = "Run real reply inactivity, connection headroom and Host drain separately from load", .script = "tests/integration/server_delivery_integration.py" },
    .{ .step = "bash-integration", .description = "Run authorized Bash execution, stop, failure, and recovery cases", .script = "tests/integration/bash_integration.py" },
    .{ .step = "bash-walkthrough", .description = "Run the narrated public Bash approve-and-recover journey", .script = "tests/integration/bash_integration.py", .args = &.{"--walkthrough"} },
    .{ .step = "bash-environment-integration", .description = "Run Bash in the sending terminal's environment across terminals, peers and recovery", .script = "tests/integration/bash_environment_integration.py" },
    .{ .step = "bash-owner-integration", .description = "Run focused Bash owner transition cases", .script = "tests/integration/bash_owner_integration.py" },
    .{ .step = "bash-lifecycle-integration", .description = "Run Bash lifecycle syscall-failure and custody cases", .script = "tests/integration/bash_lifecycle_integration.py" },
    .{ .step = "bash-recovery-integration", .description = "Run fresh-Host Bash recovery cuts for admitted and committed Actions", .script = "tests/integration/bash_recovery_integration.py", .screen = true },
    .{ .step = "codex-integration", .description = "Run synthetic managed-route credentials, Bash continuation and fresh-Host caller journey", .script = "tests/integration/codex_integration.py" },
    .{ .step = "chatgpt-plan-integration", .description = "Run a synthetic ChatGPT plan sign-in: bearer only, codec 3, refresh at expiry and on a 401", .script = "tests/integration/chatgpt_plan_integration.py" },
    .{ .step = "codex-h2-integration", .description = "Run synthetic managed TLS/H2 negotiation and observed sequential reuse (requires h2==4.3.0)", .script = "tests/integration/codex_h2_integration.py" },
    .{ .step = "control-integration", .description = "Run Session-stop, exact-interruption, and protected-capacity cases", .script = "tests/integration/control_integration.py" },
    .{ .step = "descriptor-capacity-integration", .description = "Run reduced-limit startup rejection and adequate-limit fill/drain cases", .script = "tests/integration/descriptor_capacity_integration.py" },
    .{ .step = "host-launch-integration", .description = "Run detached Host launch, alias convergence and startup-failure cases", .script = "tests/integration/host_launch_integration.py", .screen = true },
    .{ .step = "installer-integration", .description = "Run source and release installer cases through the production publication owner", .script = "tests/integration/installer_integration.py" },
    // A bounded Debug subset of the dispatch scenarios: failure provenance
    // through SQLite. The full dispatch journey stays on ReleaseSafe.
    .{ .step = "dispatch-debug-integration", .description = "Run bounded model failure correlation through SQLite on the Debug artifact", .script = "tests/integration/dispatch_integration.py", .rui = .debug, .args = &.{"failure-correlation"} },
    // check runs these cases among its process integrations; each step runs
    // the same case alone, so selection can name only the ones a change reaches.
    .{ .step = "overview-integration", .description = "Run the overview's groups, counts line, memory and clicks as a real terminal shows them", .script = "tests/integration/overview_integration.py", .screen = true },
    .{ .step = "peer-integration", .description = "Run the peer round trip through Rui-launched Bash", .script = "tests/integration/peer_integration.py", .screen = true },
    .{ .step = "sender-identity-integration", .description = "Run Action sender authority through the installed CLI, exit, stop and restart", .script = "tests/integration/sender_identity_integration.py" },
    .{ .step = "conversation-page-integration", .description = "Run public Conversation wire reads against a real Host and canonical Store", .script = "tests/integration/conversation_page_integration.py" },
    .{ .step = "host-allocator-integration", .description = "Observe the Host allocator environment before main", .script = "tests/integration/host_allocator_test.py" },
};

pub fn add(b: *std.Build, screen: std.Build.LazyPath, release_safe: std.Build.LazyPath, debug: std.Build.LazyPath) void {
    for (fixtures) |fixture| {
        const run = if (fixture.screen) screen_module.screenCommand(b, screen, &.{"python3"}) else b.addSystemCommand(&.{"python3"});
        run.addFileArg(b.path(fixture.script));
        run.addFileArg(switch (fixture.rui) {
            .release_safe => release_safe,
            .debug => debug,
        });
        run.addArgs(fixture.args);
        b.step(fixture.step, fixture.description).dependOn(&run.step);
    }
}
