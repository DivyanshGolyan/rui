//! INS-9: the certified parts list of a Session-scoped Message or Action owner.
const std = @import("std");
const tools = @import("../../tools.zig");
const content_value = @import("../../content_value.zig");
const input_parts = @import("../../input_parts.zig");
const core = @import("../Store.zig");
const public_parts = @import("../domain/public_parts.zig");
const ContentReader = @import("../domain/content.zig").ContentReader;
const testing = @import("../testing.zig");
const shared = @import("../tests.zig");
const propose = @import("action_parts.zig").propose;
const Session = @import("../../bounded.zig").Bounded(@import("../../session_id.zig").max_reference_bytes);

const png = @embedFile("../../codecs/fixtures/image-input/pixel.png");
const jpeg = @embedFile("../../testing/fixtures/input-baseline.jpg");

/// An independent spelling of the Store content digest: SHA-256 over the
/// eight-byte big-endian domain length, the `rui/content/v1` domain and the bytes.
fn expectedDigest(bytes: []const u8) [32]u8 {
    const domain = "rui/content/v1";
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var prefix: [8]u8 = undefined;
    std.mem.writeInt(u64, &prefix, domain.len, .big);
    hash.update(&prefix);
    hash.update(domain);
    hash.update(bytes);
    return hash.finalResult();
}

/// The fixture images' dimensions, read from their PNG IHDR and JPEG SOF0 headers.
const Expected = struct { bytes: []const u8, image: ?struct { format: @import("../../input_media.zig").Format, width: u32, height: u32, name: ?[]const u8 = null } = null };

fn mixedParts(name: *input_parts.Name) ![5]testing.MessagePart {
    try name.set("cat 雪.png");
    return .{
        .{ .bytes = "before \"quoted\"\n雪\x00" },
        .{ .bytes = png, .kind = .{ .image = .{ .assertion = .png, .name = name.* } } },
        .{ .bytes = "between" },
        .{ .bytes = jpeg, .kind = .{ .image = .{ .assertion = .jpeg } } },
        .{ .bytes = "" },
    };
}
const mixed_expected = [_]Expected{
    .{ .bytes = "before \"quoted\"\n雪\x00" },
    .{ .bytes = png, .image = .{ .format = .png, .width = 1, .height = 1, .name = "cat 雪.png" } },
    .{ .bytes = "between" },
    .{ .bytes = jpeg, .image = .{ .format = .jpeg, .width = 3, .height = 2 } },
    .{ .bytes = "" },
};
const many_expected: [input_parts.max_parts]Expected = @splat(.{ .bytes = "x" });

const Outcome = union(enum) { listed, refused: anyerror };

/// Walks the list as the Host does: one Store step per call, each within one round.
/// Checks the certified head comes once, before part 0, then every part in order.
fn expectList(storage: *core.Store, session: Session, owner: content_value.Owner, expected: []const Expected, outcome: Outcome) !void {
    var reader = try public_parts.Reader.init(session, owner);
    defer reader.deinit();
    var certified = false;
    var ordinal: u32 = 0;
    while (true) {
        const work = shared.ViewRounds.start(storage);
        const progress = storage.readPublicParts(&reader) catch |err| {
            if (outcome != .refused) return err;
            try std.testing.expectEqual(outcome.refused, err);
            try std.testing.expect(!certified and ordinal == 0);
            try std.testing.expectEqual(err == error.CorruptStore, storage.isFenced());
            return;
        };
        const taken = work.taken();
        try std.testing.expect(taken.rounds + taken.content_rounds <= 1);
        switch (progress) {
            .pending => {},
            .certified => |value| {
                try std.testing.expect(!certified and ordinal == 0);
                try std.testing.expect(std.meta.eql(owner, value.owner));
                certified = true;
            },
            .part => |part| {
                try std.testing.expect(certified);
                const want = expected[ordinal];
                try std.testing.expectEqual(ordinal, part.ordinal);
                try std.testing.expectEqual(@as(u64, want.bytes.len), part.reference.length);
                try std.testing.expectEqualSlices(u8, &expectedDigest(want.bytes), &part.reference.digest);
                if (want.image) |image| {
                    try std.testing.expect(part.kind == .image);
                    const media = part.kind.image.media;
                    try std.testing.expectEqual(image.format, media.format);
                    try std.testing.expectEqual(image.width, media.width);
                    try std.testing.expectEqual(image.height, media.height);
                    if (image.name) |name| try std.testing.expectEqualStrings(name, part.kind.image.name.?.slice()) else try std.testing.expect(part.kind.image.name == null);
                } else try std.testing.expect(part.kind == .text);
                if (ordinal < 8 or ordinal + 1 == expected.len) try expectPartBytes(storage, session, owner, ordinal, want.bytes);
                ordinal += 1;
            },
            .done => break,
        }
    }
    try std.testing.expect(outcome == .listed and certified);
    try std.testing.expectEqual(expected.len, ordinal);
    try std.testing.expect(!storage.isFenced());
}

/// The indexed open serves the same part the list certified, with its exact bytes.
fn expectPartBytes(storage: *core.Store, session: Session, owner: content_value.Owner, ordinal: u32, bytes: []const u8) !void {
    const location = try storage.openPublicPart(session.slice(), owner, ordinal, 0);
    try std.testing.expectEqual(@as(u64, bytes.len), location.reference.length);
    var reader: ContentReader = undefined;
    reader.open(location);
    defer reader.close();
    var buffer: [257]u8 = undefined;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = try reader.read(offset, &buffer);
        try std.testing.expect(count > 0);
        try std.testing.expectEqualSlices(u8, bytes[offset..][0..count], buffer[0..count]);
        offset += count;
    }
}

const Value = enum { text, mixed, many };
const Damage = enum { none, manifest_bytes, missing_last, extra_index_row, wrong_identity, private_part };

/// Three Sessions share one deduplicated parts value. `own` receives one Message
/// and resolves the Action; `peer` receives a second Message that `own` sent.
/// `stranger` holds neither.
const World = struct {
    storage: core.Store,
    own: Session,
    peer: Session,
    stranger: Session,
    received: u64,
    sent: u64,
    action: u64,
    content: u64,
};

fn build(world: *World, case: *testing.Case, tmp: *std.testing.TmpDir, value: Value) !void {
    var name: input_parts.Name = .{};
    var mixed = try mixedParts(&name);
    const many: [input_parts.max_parts]testing.MessagePart = @splat(.{ .bytes = "x" });
    const text = [_]testing.MessagePart{.{ .bytes = "one Text remains bytes 雪" }};
    const parts: []const testing.MessagePart = switch (value) {
        .text => &text,
        .mixed => &mixed,
        .many => &many,
    };
    const storage = &world.storage;
    try testing.testingStoreWith(case, storage, tmp, std.testing.io, .{ .host_tool_set = &tools.built_in_tool_set });
    world.own = try propose(storage, tmp, .bash);
    world.peer = try testing.configureTestSession(storage, "public-parts-peer");
    world.stranger = try testing.configureTestSession(storage, "public-parts-stranger");
    const selected = (try storage.nextAction(.bash, .fromFree(2, true))).?;
    const binding = (try storage.admitActionAttempt(selected, 30_000, .{})).?.permit.binding;
    world.action = selected.action_id;
    try testing.settleTestActionParts(storage, tmp, binding, parts);
    try testing.submitTestMessageParts(storage, tmp, "public-received", world.own.slice(), parts);
    try testing.submitTestMessageParts(storage, tmp, "public-sent", world.peer.slice(), parts);
    world.received = try testing.queryU64(storage, "SELECT admission_id FROM message_admission WHERE command_key=?1", .{"public-received"});
    world.sent = try testing.queryU64(storage, "SELECT admission_id FROM message_admission WHERE command_key=?1", .{"public-sent"});
    try testing.exec(storage, "UPDATE message_admission SET source_kind=2,sender_session_ref=?1 WHERE admission_id=?2", .{ world.own.slice(), world.sent });
    world.content = try testing.queryU64(storage, "SELECT content_id FROM message_admission WHERE admission_id=?1", .{world.received});
    // Deduplication: both Messages and the Resolution hold one content row.
    try std.testing.expectEqual(world.content, try testing.queryU64(storage, "SELECT content_id FROM message_admission WHERE admission_id=?1", .{world.sent}));
    try std.testing.expectEqual(world.content, try testing.queryU64(storage, "SELECT resolution_content_id FROM action_operation WHERE action_id=?1", .{world.action}));
}

fn damage(world: *World, kind: Damage) !void {
    const storage = &world.storage;
    const last = 4;
    switch (kind) {
        .none => {},
        .manifest_bytes => try testing.zeroContent(storage, "SELECT content_id FROM message_admission WHERE command_key='public-received'"),
        .missing_last => try testing.exec(storage, "DELETE FROM content_part WHERE content_id=?1 AND ordinal=?2", .{ world.content, last }),
        .extra_index_row => try testing.exec(storage, "INSERT INTO content_part(content_id,ordinal,part_content_id) SELECT content_id,5,part_content_id FROM content_part WHERE content_id=?1 AND ordinal=0", .{world.content}),
        .wrong_identity => {
            const first = try testing.queryU64(storage, "SELECT part_content_id FROM content_part WHERE content_id=?1 AND ordinal=0", .{world.content});
            try testing.exec(storage, "UPDATE content_part SET part_content_id=?2 WHERE content_id=?1 AND ordinal=?3", .{ world.content, first, last });
        },
        .private_part => {
            const part = try testing.queryU64(storage, "SELECT part_content_id FROM content_part WHERE content_id=?1 AND ordinal=?2", .{ world.content, last });
            try testing.exec(storage, "UPDATE content SET private=1 WHERE content_id=?1", .{part});
        },
    }
}

test "INS-9 public parts list certifies then yields every part" {
    try testing.forEachEngine(struct {
        fn run(case: *testing.Case) !void {
            for (std.enums.values(Value)) |value| for (std.enums.values(Damage)) |kind| {
                if (kind != .none and value != .mixed) continue;
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                var world: World = undefined;
                try build(&world, case, &tmp, value);
                defer world.storage.close() catch unreachable;
                try damage(&world, kind);
                const expected: []const Expected = switch (value) {
                    .text => &.{},
                    .mixed => &mixed_expected,
                    .many => &many_expected,
                };
                const served: Outcome = switch (kind) {
                    .none => if (value == .text) .{ .refused = error.ContentIsText } else .listed,
                    else => .{ .refused = error.CorruptStore },
                };
                const absent: Outcome = .{ .refused = error.ContentNotFound };
                const Read = struct { session: Session, owner: content_value.Owner, outcome: Outcome };
                const reads = [_]Read{
                    .{ .session = world.own, .owner = .{ .message = world.received }, .outcome = served },
                    .{ .session = world.peer, .owner = .{ .message = world.sent }, .outcome = served },
                    .{ .session = world.own, .owner = .{ .message = world.sent }, .outcome = served },
                    .{ .session = world.own, .owner = .{ .action = world.action }, .outcome = served },
                    .{ .session = world.peer, .owner = .{ .message = world.received }, .outcome = absent },
                    .{ .session = world.peer, .owner = .{ .action = world.action }, .outcome = absent },
                    .{ .session = world.stranger, .owner = .{ .message = world.received }, .outcome = absent },
                    .{ .session = world.stranger, .owner = .{ .message = world.sent }, .outcome = absent },
                    .{ .session = world.stranger, .owner = .{ .action = world.action }, .outcome = absent },
                    .{ .session = world.own, .owner = .{ .message = world.sent + 1000 }, .outcome = absent },
                    .{ .session = world.own, .owner = .{ .action = 0 }, .outcome = absent },
                };
                for (reads, 0..) |read, read_index| {
                    // A fenced Store refuses everything after its first fault.
                    if (world.storage.isFenced()) break;
                    expectList(&world.storage, read.session, read.owner, expected, read.outcome) catch |err| {
                        std.debug.print("INS-9 {t} value, {t} damage, read {d}: {t}\n", .{ value, kind, read_index, err });
                        return err;
                    };
                }
                try std.testing.expectEqual(kind != .none, world.storage.isFenced());
            };
        }
    }.run);
}

test "seed CLI mixed parts fixture" {
    // INS-10: seed the Store the CLI part reads observe.
    const path = std.c.getenv("RUI_PARTS_SEED_DIR") orelse return;
    const directory = try std.Io.Dir.openDirAbsolute(std.testing.io, std.mem.span(path), .{});
    defer directory.close(std.testing.io);
    var tmp: std.testing.TmpDir = .{ .dir = directory, .parent_dir = .cwd(), .sub_path = @splat(0) };
    var storage: core.Store = undefined;
    try testing.testingStoreToolSet(&storage, &tmp, std.testing.io, &tools.built_in_tool_set);
    var name: input_parts.Name = .{};
    const mixed = try mixedParts(&name);
    const session = try propose(&storage, &tmp, .bash);
    const foreign = try testing.configureTestSession(&storage, "cli-foreign");
    const selected = (try storage.nextAction(.bash, .fromFree(2, true))).?;
    const binding = (try storage.admitActionAttempt(selected, 30_000, .{})).?.permit.binding;
    try testing.settleTestActionParts(&storage, &tmp, binding, &mixed);
    try testing.submitTestMessageParts(&storage, &tmp, "cli-mixed-message", session.slice(), &mixed);
    try testing.submitTestMessageParts(&storage, &tmp, "cli-text-message", session.slice(), &.{.{ .bytes = "only text" }});
    const admission = try testing.queryU64(&storage, "SELECT admission_id FROM message_admission WHERE command_key=?1", .{"cli-mixed-message"});
    const text_admission = try testing.queryU64(&storage, "SELECT admission_id FROM message_admission WHERE command_key=?1", .{"cli-text-message"});
    var output: [256]u8 = undefined;
    const receipt = try std.fmt.bufPrint(&output, "{{\"session\":\"{s}\",\"foreign\":\"{s}\",\"admission\":\"{d}\",\"text_admission\":\"{d}\",\"action\":\"{d}\"}}\n", .{ session.slice(), foreign.slice(), admission, text_admission, selected.action_id });
    try storage.close();
    try directory.writeFile(std.testing.io, .{ .sub_path = "parts-seed.json", .data = receipt });
}
