//! The deep-modules test root: one test binary runs every unit's tests.

test {
    _ = @import("Allow.zig");
    _ = @import("Bodies.zig");
    _ = @import("Circle.zig");
    _ = @import("Components.zig");
    _ = @import("Diagnostic.zig");
    _ = @import("FieldLeak.zig");
    _ = @import("FieldLeakTest.zig");
    _ = @import("Graph.zig");
    _ = @import("HandSetFlag.zig");
    _ = @import("HandSetFlagTest.zig");
    _ = @import("TestCode.zig");
    _ = @import("Imports.zig");
    _ = @import("ItemSyntax.zig");
    _ = @import("Items.zig");
    _ = @import("Lints.zig");
    _ = @import("ModuleCycle.zig");
    _ = @import("Names.zig");
    _ = @import("References.zig");
    _ = @import("ReferencesTest.zig");
    _ = @import("Wrappers.zig");
    _ = @import("WrappersTest.zig");
    _ = @import("Report.zig");
    _ = @import("Shallow.zig");
    _ = @import("Sources.zig");
    _ = @import("Tangle.zig");
    _ = @import("Types.zig");
    _ = @import("InferTest.zig");
    _ = @import("main.zig");
}
