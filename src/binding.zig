const std = @import("std");

pub const Sha256 = [std.crypto.hash.sha2.Sha256.digest_length]u8;

fn Semantic(comptime domain_name: []const u8) type {
    return struct {
        bytes: Sha256,

        pub const domain = domain_name;
    };
}

pub const ModelDescriptor = Semantic("model-descriptor");
pub const ToolCatalog = Semantic("tool-catalog");
pub const ModelContract = Semantic("model-contract");
pub const BashDescriptor = Semantic("bash-descriptor");
pub const PatchDescriptor = Semantic("patch-descriptor");
pub const PatchIntent = Semantic("patch-intent");
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
    apply_patch: PatchIntent,

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
    const values = [_]Sha256{
        hash(ModelDescriptor, "echo onepage").bytes,
        hash(ToolCatalog, "echo onepage").bytes,
        hash(ModelContract, "echo onepage").bytes,
        hash(BashDescriptor, "echo onepage").bytes,
        hash(PatchDescriptor, "echo onepage").bytes,
        hash(PatchIntent, "echo onepage").bytes,
        hash(Preimage, "echo onepage").bytes,
        hash(Postimage, "echo onepage").bytes,
        hash(Result, "echo onepage").bytes,
        hash(Completion, "echo onepage").bytes,
        hash(Blob, "echo onepage").bytes,
        hash(LedgerRecord, "echo onepage").bytes,
    };
    const expected = [_][]const u8{
        "536b9053ad1cf7c790af671c779521e2e89b2c69848e61c0a0a3ed00091e919e",
        "eb0bea81a7e35fc37a12c9812cf68cba8d245a068d22e0cf6bc54ddeea8d0403",
        "07c88c295e537b326385a51d521d6c90f0da423bdaf67d8e6088b1b9e96402f2",
        "7fe7f013c5aec0fc2ab55221722c2fce0fd81d63a83498c377ccf32578c40301",
        "cdf6070e6871f050d023a9ff0059edc7fae700671d3d719ff37885a1ba7decf6",
        "e43caae38f8e52b4db1f4b52dca021c891ed2723344c13e61d58cf67be65e88d",
        "68e07bc3ac475f4ea5bbb937ef6a5fe0359e17d7af5ffd2d88ddd99d6490cab3",
        "7771002160873aa19d8185d89e1ccada1512959b376fc555910d0a435601602b",
        "5dcca21a410451185e1161b6b2895b8624125c2c9b07e5ecbd759c888497bae4",
        "1686a06c9bd917f70796d91813334bac19b305b0a06494d5b7c4a27548cc9ded",
        "1a2d54cf840b9860714cd2b0fcbc4335d9e6310e0e0658e05b9f7e6f9930f243",
        "9a5b3c4a62bb5b6477d3154c523a3215281a47d5ad22af5ca3b7b94963e8dd16",
    };
    for (values, expected) |value, expected_hex| {
        try std.testing.expectEqualStrings(expected_hex, &std.fmt.bytesToHex(value, .lower));
    }
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
