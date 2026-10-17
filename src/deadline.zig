//! Awake-clock deadlines for value transitions that receive `now` from
//! their caller instead of reading a clock.
const std = @import("std");

pub const Timestamp = std.Io.Clock.Timestamp;

pub fn after(now: Timestamp, milliseconds: u64) Timestamp {
    return now.addDuration(.{
        .raw = .fromMilliseconds(@intCast(milliseconds)),
        .clock = .awake,
    });
}

pub fn reached(now: Timestamp, deadline: Timestamp) bool {
    return deadline.compare(.lte, now);
}
