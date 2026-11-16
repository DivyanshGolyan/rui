const std = @import("std");

pub fn retired(service: anytype) !bool {
    if (service.execution.retired()) return true;
    const progress = service.execution.service(service.scratch, service.window);
    try std.testing.expect(progress.fault == null);
    return service.execution.retired();
}
