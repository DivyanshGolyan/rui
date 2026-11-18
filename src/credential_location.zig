const std = @import("std");
const Provider = @import("provider_name.zig").Provider;

pub fn variable(comptime provider: Provider) []const u8 {
    comptime var upper: [@tagName(provider).len]u8 = undefined;
    inline for (@tagName(provider), &upper) |byte, *to| to.* = comptime std.ascii.toUpper(byte);
    const name = upper;
    return "RUI_" ++ &name ++ (comptime if (provider.facts().credential == .api_key) "_KEY_FILE" else "_CREDENTIAL_FILE");
}

pub const variables = blk: {
    const providers = std.enums.values(Provider);
    var names: [providers.len][]const u8 = undefined;
    for (providers, 0..) |provider, i| names[i] = variable(provider);
    break :blk names;
};

pub const Error = error{ HomeRequired, InvalidCredentialPath };

pub fn default(environ: *const std.process.Environ.Map, comptime provider: Provider, buffer: []u8) Error![]const u8 {
    if (environ.get(comptime variable(provider))) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.InvalidCredentialPath;
        return path;
    }
    const home = environ.get("HOME") orelse return error.HomeRequired;
    if (!std.fs.path.isAbsolute(home)) return error.InvalidCredentialPath;
    const extension = comptime if (provider.facts().credential == .api_key) ".key" else ".json";
    return std.fmt.bufPrint(buffer, "{s}/.config/rui/" ++ @tagName(provider) ++ extension, .{home}) catch error.InvalidCredentialPath;
}

test "credential default covers each variable and home combination" {
    inline for (std.enums.values(Provider)) |provider| {
        for ([_]?[]const u8{ null, "/credential", "relative", "" }) |named| {
            for ([_]?[]const u8{ "/home/test", "relative", null }) |home| {
                var env: std.process.Environ.Map = .init(std.testing.allocator);
                defer env.deinit();
                if (named) |value| try env.put(variable(provider), value);
                if (home) |value| try env.put("HOME", value);
                var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const result = default(&env, provider, &buffer);
                if (named) |value| {
                    if (std.fs.path.isAbsolute(value)) try std.testing.expectEqualStrings(value, try result) else try std.testing.expectError(error.InvalidCredentialPath, result);
                } else if (home) |value| {
                    if (std.fs.path.isAbsolute(value)) {
                        const filename = @tagName(provider) ++ (comptime if (provider.facts().credential == .api_key) ".key" else ".json");
                        try std.testing.expectEqualStrings("/home/test/.config/rui/" ++ filename, try result);
                    } else try std.testing.expectError(error.InvalidCredentialPath, result);
                } else try std.testing.expectError(error.HomeRequired, result);
            }
        }
    }
}
