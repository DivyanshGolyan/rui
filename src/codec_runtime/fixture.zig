//! A tiny wasm32 module for codec_runtime's tests: each export provokes one
//! behaviour the sandbox must contain.
var calls: u32 = 0;

export fn count() u32 {
    calls += 1;
    return calls;
}

export fn add(a: u32, b: u32) u32 {
    return a +% b;
}

export fn spin(rounds: u32) u32 {
    var sink: u32 = 0;
    const total: *volatile u32 = &sink;
    var index: u32 = 0;
    while (index != rounds) : (index += 1) total.* +%= index;
    return total.*;
}

export fn forever() u32 {
    var sink: u32 = 0;
    while (true) {
        const step: *volatile u32 = &sink;
        step.* +%= 1;
    }
}

export fn fail() u32 {
    @trap();
}

export fn outside() u32 {
    const far: *volatile u32 = @ptrFromInt(0xffff_fff0);
    return far.*;
}

var recurse_through: *const fn (u32) callconv(.c) u32 = &recurse;

export fn recurse(depth: u32) u32 {
    if (depth == 0) return 0;
    const next: *volatile *const fn (u32) callconv(.c) u32 = &recurse_through;
    return next.*(depth - 1) +% 1;
}

export fn grow(pages: u32) i32 {
    return @wasmMemoryGrow(0, pages);
}

const greeting = "codec data segment";

export fn greetingAddress() u32 {
    return @intFromPtr(greeting.ptr);
}

export fn greetingLength() u32 {
    return greeting.len;
}

/// Sums `len` bytes the host wrote at `address`.
export fn sum(address: u32, len: u32) u32 {
    const bytes: [*]const u8 = @ptrFromInt(address);
    var total: u32 = 0;
    for (bytes[0..len]) |byte| total +%= byte;
    return total;
}

export fn scratchAddress() u32 {
    return @intFromPtr(&scratch);
}

var scratch: [4096]u8 = undefined;
