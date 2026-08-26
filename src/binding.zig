const std = @import("std");

pub const Sha256 = [std.crypto.hash.sha2.Sha256.digest_length]u8;

fn Semantic(comptime domain_name: []const u8) type {
    return struct {
        bytes: Sha256,

        pub const domain = domain_name;
    };
}

pub const ModelDescriptor = Semantic("model-descriptor");
pub const BashDescriptor = Semantic("bash-descriptor");
pub const PatchDescriptor = Semantic("patch-descriptor");
pub const PatchIntent = Semantic("patch-intent");
pub const WorkspaceState = Semantic("workspace-state");
pub const Preimage = Semantic("preimage");
pub const Postimage = Semantic("postimage");
pub const Result = Semantic("result");
pub const Completion = Semantic("completion");
pub const Blob = Semantic("blob");
pub const LedgerRecord = Semantic("ledger-record");

pub const DescriptorKind = enum(u8) {
    model = 1,
    bash = 2,
    apply_patch = 3,
};

pub const Descriptor = union(DescriptorKind) {
    model: ModelDescriptor,
    bash: BashDescriptor,
    apply_patch: PatchDescriptor,

    pub fn bytes(self: Descriptor) Sha256 {
        return switch (self) {
            inline else => |value| value.bytes,
        };
    }

    pub fn fromBytes(kind: DescriptorKind, bytes_value: Sha256) Descriptor {
        return switch (kind) {
            .model => .{ .model = .{ .bytes = bytes_value } },
            .bash => .{ .bash = .{ .bytes = bytes_value } },
            .apply_patch => .{ .apply_patch = .{ .bytes = bytes_value } },
        };
    }
};

pub fn descriptorEql(left: Descriptor, right: Descriptor) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return std.mem.eql(u8, &left.bytes(), &right.bytes());
}

pub fn Hasher(comptime T: type) type {
    requireSemantic(T);
    return struct {
        inner: std.crypto.hash.sha2.Sha256,

        pub fn init() @This() {
            var inner = std.crypto.hash.sha2.Sha256.init(.{});
            inner.update("onepage-binding-v1\x00");
            inner.update(T.domain);
            inner.update("\x00");
            return .{ .inner = inner };
        }

        pub fn update(self: *@This(), bytes: []const u8) void {
            self.inner.update(bytes);
        }

        pub fn final(self: *@This()) T {
            var bytes: Sha256 = undefined;
            self.inner.final(&bytes);
            return .{ .bytes = bytes };
        }
    };
}

pub fn hash(comptime T: type, bytes: []const u8) T {
    var hasher = Hasher(T).init();
    hasher.update(bytes);
    return hasher.final();
}

pub fn eql(comptime T: type, left: T, right: T) bool {
    requireSemantic(T);
    return std.mem.eql(u8, &left.bytes, &right.bytes);
}

fn requireSemantic(comptime T: type) void {
    comptime {
        if (!@hasDecl(T, "domain") or !@hasField(T, "bytes") or
            @TypeOf(@field(@as(T, undefined), "bytes")) != Sha256)
        {
            @compileError("expected a semantic SHA-256 binding type");
        }
    }
}

test "authoritative bindings use stable domain-separated SHA-256 vectors" {
    const bash = hash(BashDescriptor, "echo onepage");
    const result = hash(Result, "echo onepage");
    const values = [_]Sha256{
        hash(ModelDescriptor, "echo onepage").bytes,
        bash.bytes,
        hash(PatchDescriptor, "echo onepage").bytes,
        hash(PatchIntent, "echo onepage").bytes,
        hash(WorkspaceState, "echo onepage").bytes,
        hash(Preimage, "echo onepage").bytes,
        hash(Postimage, "echo onepage").bytes,
        result.bytes,
        hash(Completion, "echo onepage").bytes,
        hash(Blob, "echo onepage").bytes,
        hash(LedgerRecord, "echo onepage").bytes,
    };

    try std.testing.expectEqualStrings(
        "7fe7f013c5aec0fc2ab55221722c2fce0fd81d63a83498c377ccf32578c40301",
        &std.fmt.bytesToHex(bash.bytes, .lower),
    );
    try std.testing.expect(!std.mem.eql(u8, &bash.bytes, &result.bytes));
    try std.testing.expect(@TypeOf(bash) != @TypeOf(result));
    for (values, 0..) |left, left_index| {
        for (values[left_index + 1 ..]) |right| {
            try std.testing.expect(!std.mem.eql(u8, &left, &right));
        }
    }
    comptime {
        std.debug.assert(ModelDescriptor != BashDescriptor);
        std.debug.assert(PatchDescriptor != PatchIntent);
        std.debug.assert(Preimage != Postimage);
        std.debug.assert(Result != Completion);
        std.debug.assert(Blob != LedgerRecord);
    }
}

test "the all-zero SHA-256 value is data rather than absence" {
    const zero: Result = .{ .bytes = @splat(0) };
    const present: ?Result = zero;

    try std.testing.expect(present != null);
    try std.testing.expectEqual(@as(?Result, null), @as(?Result, null));
}
