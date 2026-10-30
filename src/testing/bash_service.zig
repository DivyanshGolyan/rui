//! A `test_poll.waitUntil` condition that services a test's Bash execution
//! one pass per check until it retires. `service` holds the `execution`, its
//! `scratch` and a copy `window`.

const std = @import("std");

pub fn retired(service: anytype) !bool {
    if (service.execution.retired()) return true;
    const progress = service.execution.service(service.scratch, service.window);
    try std.testing.expect(progress.fault == null);
    return service.execution.retired();
}
