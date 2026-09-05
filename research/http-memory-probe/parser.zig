// Throwaway: use the installed Zig 0.16 standard HTTP header parser.
const std = @import("std");
export fn parse_head(bytes: [*]const u8, len: usize, body_len: *u64, large: *c_int) c_int {
    const head = std.http.Server.Request.Head.parse(bytes[0..len]) catch return -1;
    if (head.transfer_encoding != .none or head.transfer_compression != .identity) return -1;
    body_len.* = head.content_length orelse 0;
    large.* = if (std.mem.eql(u8, head.target, "/large")) 1 else 0;
    return 0;
}
