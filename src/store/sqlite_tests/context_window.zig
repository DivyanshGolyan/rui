//! Context window SQLite mechanism tests.

const shared_fixtures = @import("../sqlite_tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const product_defaults = @import("../../product_defaults.zig");
const store_core = @import("../Store.zig");
const Store = store_core.Store;
const store_testing = @import("../testing.zig");
const canonicalCwd = store_testing.canonicalCwd;
const completeConfiguration = store_testing.completeConfiguration;
const submitTestMessage = store_testing.submitTestMessage;
const testingStore = store_testing.testingSqliteStore;
const TestingSteps = shared_fixtures.TestingSteps;

test "frozen context window lookup work is independent of catalog population" {
    const Measure = struct {
        const Variant = enum { missing, late, null_window, stale };
        const Cost = struct { configuration: u64, admission: u64 };

        fn run(population: usize, variant: Variant) !Cost {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var storage: Store = undefined;
            try testingStore(&storage, &tmp, std.testing.io);
            defer storage.close() catch unreachable;
            try storage.saveModelFacts(&.{}, null);
            // Half the unrelated facts are retained from an older generation.
            // Neither they nor the selected generation may turn a point lookup
            // into a scan. Insert the requested model last when it exists.
            try store_testing.sqlite_only.exec(&storage, "WITH RECURSIVE sequence(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM sequence WHERE value<?1) " ++
                "INSERT INTO model_fact(model_id,context_window,efforts,openai_listed,generation) " ++
                "SELECT printf('catalog-noise-%05d',value),256000,0,0,value%2 FROM sequence", .{population});
            const model = "zz-window-target";
            const saved_window: u32 = 256000;
            if (variant != .missing) try store_testing.sqlite_only.exec(&storage, "INSERT INTO model_fact(model_id,context_window,efforts,openai_listed,generation) " ++
                "VALUES(?1,CASE WHEN ?2=1 THEN NULL ELSE ?3 END,0,0,?4)", .{ model, @intFromBool(variant == .null_window), saved_window, @as(u64, if (variant == .stale) 0 else 1) });

            var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
            const create = try completeConfiguration("indexed-window-config", "", try canonicalCwd(std.testing.io, &workspace_buffer), model);
            var configuration_steps: TestingSteps = .{};
            const session = blk: {
                configuration_steps.begin(storage.sqliteDatabase());
                defer configuration_steps.end(storage.sqliteDatabase());
                const reply = try storage.configure(&create, .{});
                try std.testing.expect(reply == .accepted);
                break :blk reply.accepted.session;
            };
            try submitTestMessage(&storage, &tmp, "indexed-window-input", "indexed-window-input", session.slice(), "first");
            var admission_steps: TestingSteps = .{};
            const binding = blk: {
                admission_steps.begin(storage.sqliteDatabase());
                defer admission_steps.end(storage.sqliteDatabase());
                break :blk (try storage.admitModelAttempt(.message, .{})).?.permit.binding;
            };
            const expected = if (variant == .late) saved_window else product_defaults.unlisted_context_window;
            try std.testing.expectEqual(@as(u64, expected), try store_testing.sqlite_only.queryU64(&storage, "SELECT context_window FROM model_operation WHERE operation_id=?1", .{binding.operation_id}));
            return .{ .configuration = configuration_steps.steps, .admission = admission_steps.steps };
        }
    };
    for (std.enums.values(Measure.Variant)) |variant| {
        const small = try Measure.run(32, variant);
        const large = try Measure.run(10000, variant);
        // Meter the real Operation INSERT and the sibling single-model reader,
        // not a restated predicate or just their unchanged Store round counts.
        try std.testing.expectEqual(small.admission, large.admission);
        try std.testing.expectEqual(small.configuration, large.configuration);
    }
}
