//! Compilation ownership, not a runtime skip policy: every test belongs to one
//! root. Keep each module's tests (and their process globals) together.
const std = @import("std");

// Two LLVM roots use ~5.5 GiB together; a third saved only 7% wall time but
// exceeded the 7 GiB Mac runner's safe memory budget. Store runs last because
// its MySQL migration/conformance checks own the final acceptance record.
pub const Root = enum { native, store };
pub const roots = std.enums.values(Root);

pub fn owner(name: []const u8) Root {
    return if (std.mem.startsWith(u8, name, "store.")) .store else .native;
}
