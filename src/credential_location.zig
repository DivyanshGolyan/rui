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

/// The file a connection's saved key lives in: `RUI_<NAME>_KEY_FILE` when set and absolute,
/// else `HOME/.config/rui/<name>.key`. The name is a connection name: lowercase letters,
/// digits and '-', so its variable spells with '_' in place of '-'.
pub fn connectionKeyFile(environ: *const std.process.Environ.Map, name: []const u8, buffer: []u8) Error![]const u8 {
    return connectionFile(environ, name, .key, buffer);
}

/// The file a sign-in connection's credential record lives in: `RUI_<NAME>_CREDENTIAL_FILE` when set and
/// absolute, else `HOME/.config/rui/<name>.json`. One record per name, so signing out one connection
/// never reaches another. The built-in sign-ins `codex` and `chatgpt` resolve to their own files through `default`.
pub fn connectionCredentialFile(environ: *const std.process.Environ.Map, name: []const u8, buffer: []u8) Error![]const u8 {
    return connectionFile(environ, name, .sign_in, buffer);
}

const FileKind = enum { key, sign_in };

fn connectionFile(environ: *const std.process.Environ.Map, name: []const u8, kind: FileKind, buffer: []u8) Error![]const u8 {
    var variable_buffer: [max_variable_bytes]u8 = undefined;
    const variable_name = connectionVariable(name, kind, &variable_buffer) orelse return error.InvalidCredentialPath;
    if (environ.get(variable_name)) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.InvalidCredentialPath;
        return path;
    }
    const home = environ.get("HOME") orelse return error.HomeRequired;
    if (!std.fs.path.isAbsolute(home)) return error.InvalidCredentialPath;
    const extension = switch (kind) {
        .key => "key",
        .sign_in => "json",
    };
    return std.fmt.bufPrint(buffer, "{s}/.config/rui/{s}.{s}", .{ home, name, extension }) catch error.InvalidCredentialPath;
}

const connection_name_bytes = @import("connection.zig").max_name_bytes;
const max_variable_bytes = "RUI_".len + connection_name_bytes + "_CREDENTIAL_FILE".len;

fn connectionVariable(name: []const u8, kind: FileKind, buffer: *[max_variable_bytes]u8) ?[]const u8 {
    if (name.len == 0 or name.len > connection_name_bytes) return null;
    @memcpy(buffer[0.."RUI_".len], "RUI_");
    for (name, buffer["RUI_".len..][0..name.len]) |byte, *to| to.* = if (byte == '-') '_' else std.ascii.toUpper(byte);
    const end = "RUI_".len + name.len;
    const suffix = switch (kind) {
        .key => "_KEY_FILE",
        .sign_in => "_CREDENTIAL_FILE",
    };
    @memcpy(buffer[end..][0..suffix.len], suffix);
    return buffer[0 .. end + suffix.len];
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

test "a connection's saved key file is RUI_<NAME>_KEY_FILE or HOME's key file for that name" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try env.put("HOME", "/home/test");
    try std.testing.expectEqualStrings("/home/test/.config/rui/my-alpha.key", try connectionKeyFile(&env, "my-alpha", &buffer));
    try env.put("RUI_MY_ALPHA_KEY_FILE", "/keys/alpha.key");
    try std.testing.expectEqualStrings("/keys/alpha.key", try connectionKeyFile(&env, "my-alpha", &buffer));
    try env.put("RUI_MY_ALPHA_KEY_FILE", "relative");
    try std.testing.expectError(error.InvalidCredentialPath, connectionKeyFile(&env, "my-alpha", &buffer));
}

test "a sign-in connection's record is RUI_<NAME>_CREDENTIAL_FILE or HOME's json file for that name, apart from every other name" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var other: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try env.put("HOME", "/home/test");
    try std.testing.expectEqualStrings("/home/test/.config/rui/work.json", try connectionCredentialFile(&env, "work", &buffer));
    try std.testing.expect(!std.mem.eql(u8, try connectionCredentialFile(&env, "work", &buffer), try connectionCredentialFile(&env, "personal", &other)));
    try env.put("RUI_WORK_CREDENTIAL_FILE", "/records/work.json");
    try std.testing.expectEqualStrings("/records/work.json", try connectionCredentialFile(&env, "work", &buffer));
    try std.testing.expectEqualStrings("/home/test/.config/rui/personal.json", try connectionCredentialFile(&env, "personal", &other));
    try env.put("RUI_WORK_CREDENTIAL_FILE", "relative");
    try std.testing.expectError(error.InvalidCredentialPath, connectionCredentialFile(&env, "work", &buffer));
}
