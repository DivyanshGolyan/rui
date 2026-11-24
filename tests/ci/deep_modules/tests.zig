//! The deep-modules test root: one test binary runs every unit's tests.

test {
    _ = @import("Allow.zig");
    _ = @import("Bodies.zig");
    _ = @import("Diagnostic.zig");
    _ = @import("Imports.zig");
    _ = @import("ItemSyntax.zig");
    _ = @import("Items.zig");
    _ = @import("Lints.zig");
    _ = @import("Names.zig");
    _ = @import("References.zig");
    _ = @import("ReferencesTest.zig");
    _ = @import("Wrappers.zig");
    _ = @import("WrappersTest.zig");
    _ = @import("Report.zig");
    _ = @import("Sources.zig");
    _ = @import("Types.zig");
    _ = @import("InferTest.zig");
    _ = @import("main.zig");
}
