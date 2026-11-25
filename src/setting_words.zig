//! How the Permissions and Effort settings read to a person, and which choice index means which value.
//! App Settings and chat info both offer these choices; this is the one place that names them.
const std = @import("std");
const catalog = @import("model_catalog.zig");
const PermissionMode = @import("cli_value.zig").PermissionMode;

/// The order the Permissions choice lists its modes in: the choice index is the position here.
pub const permission_choices = [_]PermissionMode{ .bypass, .ask };

pub fn permission(mode: PermissionMode) []const u8 {
    return switch (mode) {
        .bypass => "run without asking",
        .ask => "ask first",
    };
}

pub const permission_labels: [permission_choices.len][]const u8 = labels: {
    var all: [permission_choices.len][]const u8 = undefined;
    for (permission_choices, 0..) |mode, at| all[at] = permission(mode);
    break :labels all;
};

pub fn permissionChoice(mode: PermissionMode) usize {
    return std.mem.indexOfScalar(PermissionMode, &permission_choices, mode).?;
}

pub fn permissionAt(choice: usize) PermissionMode {
    return permission_choices[choice];
}

pub const effort_default = "model default";

/// The Effort setting's words: the chosen effort's tag, or `effort_default` when the model's own is used.
pub fn effort(chosen: ?catalog.ReasoningEffort) []const u8 {
    return if (chosen) |value| @tagName(value) else effort_default;
}

test "SUI-170 both settings surfaces name Permissions and Effort from one owner" {
    for (std.enums.values(PermissionMode)) |mode| {
        try std.testing.expectEqual(mode, permissionAt(permissionChoice(mode)));
        try std.testing.expectEqualStrings(permission(mode), permission_labels[permissionChoice(mode)]);
    }
    try std.testing.expectEqual(std.enums.values(PermissionMode).len, permission_labels.len);
    try std.testing.expectEqualStrings("run without asking", permission_labels[0]);
    try std.testing.expectEqualStrings("ask first", permission_labels[1]);
    try std.testing.expectEqualStrings("model default", effort(null));
    for (std.enums.values(catalog.ReasoningEffort)) |chosen| try std.testing.expectEqualStrings(@tagName(chosen), effort(chosen));
}
