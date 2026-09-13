const provider = @import("provider.zig");

// This object is never linked or run. Cross-check compiles the enabled
// transport calls for every supported target so an unreachable partial-build
// seam cannot hide target-specific libcurl API mistakes.
export fn latifa_provider_api_check(
    reactor: *provider.Reactor,
    transfer: *provider.Transfer,
    request: *provider.PreparedRequest,
) void {
    provider.initialize() catch return;
    defer provider.deinitialize();
    transfer.start("https://example.invalid/responses", request.*) catch return;
    reactor.add(transfer) catch return;
    reactor.drive(0) catch return;
    if (reactor.nextCompletion()) |completion| _ = transfer.evidence(completion.result) catch return;
    reactor.remove(transfer);
    transfer.deinit();
}
