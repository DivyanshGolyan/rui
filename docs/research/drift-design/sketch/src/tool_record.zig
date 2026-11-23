//! Changes to src/tool_record.zig (sketch). Only changed declarations are shown.
//!
//! U0: the runner is derived in ONE place. Today it is derived three times
//! (Runner.of, action.nonBashCallSql, action.attemptRunnerSql) with Bash as the silent
//! fallthrough in each, so a new runner missing an SQL site is selected and recovered as
//! Bash. Here a single comptime table produces both the Zig answer and the SQL CASE;
//! a whole-domain test checks every owner × built-in name against both.

const std = @import("std");

pub const Owner = enum {
    rui,
    provider,
    mcp,
    /// Declared by an app for a Session lane (U6). Run by the app (U7).
    app,
    /// Written only by a sealed import (U10). Never runs.
    imported,
};

/// The execution policy of an app tool. Part of the record's identity (its digest), so a
/// call's frozen offer fixes the policy it runs under, and a re-declare that changes the
/// policy is a new record. Validated at the configure boundary; trusted inside.
pub const AppPolicy = struct {
    replay: Replay = .unsafe,
    /// pi-durable DEFAULT_RESTART_LIMIT is 5. 1..64. Meaningful only when replay = safe.
    restart_limit: u8 = 5,
    /// How long a ready call may wait for a claim and an answer, in total. 1 s .. 7 days.
    wait_ms: u32,

    pub const Replay = enum(u8) { unsafe = 0, safe = 1 };
};

pub const Record = struct {
    name: []const u8,
    description: []const u8 = "",
    input_schema: []const u8 = "",
    owner: Owner,
    server: []const u8 = "",
    /// Present exactly when owner = app. Encoded in the type: a non-app record cannot carry one.
    app: ?AppPolicy = null,

    pub fn runner(self: *const Record) Runner {
        return Runner.of(self);
    }
};

pub const Runner = enum {
    bash,
    read_image,
    core,
    mcp,
    provider,
    /// The app runs it; the Host holds no custody (store/domain/app_call.zig).
    app,
    /// Imported history: always resolved, never selected, never recovered.
    imported,

    pub fn resultProfile(self: Runner, bash_offered: bool) Profile {
        return switch (self) {
            .bash => .{ .excerpt_bytes = max_result_excerpt_bytes, .retain = true },
            .mcp, .app => .{ .excerpt_bytes = 10_000, .retain = bash_offered },
            .imported => .{ .excerpt_bytes = max_result_excerpt_bytes, .retain = true },
            .read_image => .{ .excerpt_bytes = 0, .retain = false },
            .core => .{ .excerpt_bytes = 0, .retain = false },
            .provider => unreachable,
        };
    }

    pub fn indeterminateText(self: Runner) []const u8 {
        return switch (self) {
            .app => "The app that ran this tool stopped before answering. The tool may have run; it was not automatically repeated.",
            .imported, .core, .provider => unreachable,
            else => @panic("not implemented: existing arms unchanged"),
        };
    }

    pub fn of(tool: *const Record) Runner {
        return derivation.zig(tool);
    }
};

pub const Profile = struct { excerpt_bytes: u32, retain: bool };
pub const max_result_excerpt_bytes: u32 = 20_000;

/// The one derivation. Ordered rules; the first match wins; there is no fallthrough:
/// a name the table does not cover under owner `rui` is a programmer error at comptime.
pub const derivation = struct {
    pub const Rule = union(enum) {
        owner: struct { owner: Owner, runner: Runner },
        built_in: struct { name: []const u8, runner: Runner },
    };

    /// owner rules first (mcp, provider, app, imported), then every built-in row.
    pub const rules: []const Rule = &.{};

    pub fn zig(tool: *const Record) Runner {
        _ = tool;
        @panic("not implemented");
    }

    /// `CASE WHEN t.owner='mcp' THEN 'mcp' WHEN ... WHEN t.name='bash' THEN 'bash' END`,
    /// generated from `rules`. Replaces nonBashCallSql, builtinCallSql and attemptRunnerSql;
    /// each becomes `runnerSql(t) IN (...)` or `= '...'`.
    pub fn runnerSql(comptime t: []const u8) []const u8 {
        _ = t;
        @compileError("not implemented");
    }
};
