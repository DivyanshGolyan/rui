//! Frozen MCP block classification for the independent excerpt oracle.
const document = @import("document.zig");

pub const Image = struct { data: []const u8, mime: []const u8 };
pub const Block = union(enum) {
    text: []const u8,
    image: Image,
    bad_image: []const u8,
    other: []const u8,
};

/// Input is a value from a checked JSON document. String contents remain escaped.
pub fn classify(block: []const u8) Block {
    if (document.kind(block) != .object) return .{ .other = block };
    const kind = document.member(block, "type") orelse return .{ .other = block };
    if (document.kind(kind) != .string) return .{ .other = block };
    const tag = document.contents(kind);
    if (document.keyIs(tag, "image")) {
        const data = document.member(block, "data") orelse return .{ .bad_image = "missing image data" };
        const mime = document.member(block, "mimeType") orelse return .{ .bad_image = "missing image MIME type" };
        if (document.kind(data) != .string) return .{ .bad_image = "image data is not a string" };
        if (document.kind(mime) != .string) return .{ .bad_image = "image MIME type is not a string" };
        return .{ .image = .{ .data = document.contents(data), .mime = document.contents(mime) } };
    }
    if (document.keyIs(tag, "text")) {
        const text = document.member(block, "text") orelse return .{ .other = block };
        if (document.kind(text) == .string) return .{ .text = document.contents(text) };
    }
    return .{ .other = block };
}
