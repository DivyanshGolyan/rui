//! The client side of SCRAM-SHA-256 (RFC 5802, RFC 7677), with the
//! tls-server-end-point channel binding of SCRAM-SHA-256-PLUS (RFC 5929).
const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const base64 = std.base64.standard;

pub const nonce_seed_bytes = 18;
const nonce_bytes = base64.Encoder.calcSize(nonce_seed_bytes);
/// Longer than any client message this file writes: the client-final
/// message repeats the server's nonce, which is capped by
/// `max_server_first_bytes`.
pub const max_message_bytes = 512;
const max_server_first_bytes = 256;
comptime {
    const binding = base64.Encoder.calcSize("p=tls-server-end-point,,".len + 64);
    std.debug.assert("c=".len + binding + ",r=".len + max_server_first_bytes + ",p=".len + base64.Encoder.calcSize(32) <= max_message_bytes);
}
const max_salt_bytes = 64;
/// Postgres's default is 4096. The cap bounds the PBKDF2 work a server can
/// ask of the Store worker before it answers anything, to well under a
/// second.
pub const max_iterations = 1_000_000;

/// The certificate hash SCRAM-SHA-256-PLUS binds (RFC 5929 section 4.1).
pub const ChannelBinding = struct {
    /// EVP_MAX_MD_SIZE.
    buffer: [64]u8,
    len: u8,

    pub fn bytes(self: *const ChannelBinding) []const u8 {
        return self.buffer[0..self.len];
    }
};

pub const Error = error{
    /// Not printable ASCII; see `checkPassword`.
    UnsupportedPassword,
    /// The server asked for more than `max_iterations`.
    UnsupportedIterations,
    AuthFailed,
    ProtocolViolation,
};

/// The server hashes the password after SASLprep, which maps and
/// normalizes non-ASCII text and is the identity on printable ASCII.
/// Accepting only printable ASCII keeps both sides equal without carrying
/// the Unicode tables.
pub fn checkPassword(password: []const u8) Error!void {
    for (password) |byte| if (byte < 0x20 or byte > 0x7e) return error.UnsupportedPassword;
}

pub const Binding = union(enum) {
    /// `n`: no TLS.
    unsupported,
    /// `y`: TLS without channel binding, because the server offered none.
    /// A server that does offer it then refuses the downgrade.
    unused,
    /// `p=tls-server-end-point`.
    server_end_point: ChannelBinding,

    fn gs2Header(self: *const Binding) []const u8 {
        return switch (self.*) {
            .unsupported => "n,,",
            .unused => "y,,",
            .server_end_point => "p=tls-server-end-point,,",
        };
    }
};

pub const Client = struct {
    binding: Binding,
    nonce_buffer: [nonce_bytes]u8,
    nonce_len: u8,
    user: []const u8,
    server_signature: [Hmac.mac_length]u8 = undefined,
    verified: bool = false,

    /// Postgres takes the user from the startup message and ignores the
    /// SCRAM one, so the Store sends it empty.
    pub fn init(seed: [nonce_seed_bytes]u8, binding: Binding) Client {
        var text: [nonce_bytes]u8 = undefined;
        return withNonce("", base64.Encoder.encode(&text, &seed), binding);
    }

    /// `user` holds no `,` or `=`, and `nonce` is printable without `,`.
    fn withNonce(user: []const u8, text: []const u8, binding: Binding) Client {
        var client: Client = .{ .binding = binding, .nonce_buffer = undefined, .nonce_len = @intCast(text.len), .user = user };
        @memcpy(client.nonce_buffer[0..text.len], text);
        return client;
    }

    fn nonce(self: *const Client) []const u8 {
        return self.nonce_buffer[0..self.nonce_len];
    }

    fn clientFirstBare(self: *const Client, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "n={s},r={s}", .{ self.user, self.nonce() }) catch unreachable;
    }

    pub fn clientFirst(self: *const Client, buffer: *[max_message_bytes]u8) []const u8 {
        const header = self.binding.gs2Header();
        @memcpy(buffer[0..header.len], header);
        return buffer[0 .. header.len + self.clientFirstBare(buffer[header.len..]).len];
    }

    /// The client-final message for `server_first`. Remembers the server
    /// signature `verifyServerFinal` expects.
    pub fn clientFinal(self: *Client, server_first: []const u8, password: []const u8, buffer: *[max_message_bytes]u8) Error![]const u8 {
        if (server_first.len > max_server_first_bytes) return error.ProtocolViolation;
        var attributes = std.mem.splitScalar(u8, server_first, ',');
        const combined = try attribute(attributes.next(), 'r');
        const salt_text = try attribute(attributes.next(), 's');
        const iterations_text = try attribute(attributes.next(), 'i');
        // A mandatory extension (m=) or anything else Rui cannot honour.
        if (attributes.next() != null) return error.ProtocolViolation;
        if (combined.len <= self.nonce_len or !std.mem.startsWith(u8, combined, self.nonce())) return error.ProtocolViolation;
        for (combined) |byte| if (byte < 0x21 or byte > 0x7e or byte == ',') return error.ProtocolViolation;
        var salt: [max_salt_bytes]u8 = undefined;
        const salt_len = base64.Decoder.calcSizeForSlice(salt_text) catch return error.ProtocolViolation;
        if (salt_len == 0 or salt_len > salt.len) return error.ProtocolViolation;
        base64.Decoder.decode(salt[0..salt_len], salt_text) catch return error.ProtocolViolation;
        const iterations = std.fmt.parseUnsigned(u32, iterations_text, 10) catch return error.ProtocolViolation;
        if (iterations == 0) return error.ProtocolViolation;
        if (iterations > max_iterations) return error.UnsupportedIterations;

        var salted: [Sha256.digest_length]u8 = undefined;
        std.crypto.pwhash.pbkdf2(&salted, password, salt[0..salt_len], iterations, Hmac) catch return error.ProtocolViolation;
        var client_key: [Hmac.mac_length]u8 = undefined;
        Hmac.create(&client_key, "Client Key", &salted);
        var stored_key: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(&client_key, &stored_key, .{});
        var server_key: [Hmac.mac_length]u8 = undefined;
        Hmac.create(&server_key, "Server Key", &salted);

        var binding_input: [64 + 32]u8 = undefined;
        const header = self.binding.gs2Header();
        @memcpy(binding_input[0..header.len], header);
        var binding_len = header.len;
        if (self.binding == .server_end_point) {
            const hash = self.binding.server_end_point.buffer[0..self.binding.server_end_point.len];
            @memcpy(binding_input[binding_len..][0..hash.len], hash);
            binding_len += hash.len;
        }
        var channel: [base64.Encoder.calcSize(binding_input.len)]u8 = undefined;
        const without_proof = std.fmt.bufPrint(buffer, "c={s},r={s}", .{
            base64.Encoder.encode(&channel, binding_input[0..binding_len]),
            combined,
        }) catch unreachable; // max_message_bytes covers the longest (comptime check above).

        var bare: [max_message_bytes]u8 = undefined;
        const first_bare = self.clientFirstBare(&bare);
        var client_signature: [Hmac.mac_length]u8 = undefined;
        authMessageMac(&client_signature, &stored_key, first_bare, server_first, without_proof);
        authMessageMac(&self.server_signature, &server_key, first_bare, server_first, without_proof);

        var proof: [Hmac.mac_length]u8 = undefined;
        for (&proof, client_key, client_signature) |*byte, key, signature| byte.* = key ^ signature;
        var proof_text: [base64.Encoder.calcSize(proof.len)]u8 = undefined;
        const tail = std.fmt.bufPrint(buffer[without_proof.len..], ",p={s}", .{base64.Encoder.encode(&proof_text, &proof)}) catch unreachable;
        return buffer[0 .. without_proof.len + tail.len];
    }

    pub fn verifyServerFinal(self: *Client, server_final: []const u8) Error!void {
        if (std.mem.startsWith(u8, server_final, "e=")) return error.AuthFailed;
        const text = try attribute(server_final, 'v');
        var signature: [Hmac.mac_length]u8 = undefined;
        if ((base64.Decoder.calcSizeForSlice(text) catch return error.ProtocolViolation) != signature.len) return error.ProtocolViolation;
        base64.Decoder.decode(&signature, text) catch return error.ProtocolViolation;
        if (!std.crypto.timing_safe.eql([Hmac.mac_length]u8, signature, self.server_signature)) return error.AuthFailed;
        self.verified = true;
    }
};

fn attribute(item: ?[]const u8, name: u8) Error![]const u8 {
    const text = item orelse return error.ProtocolViolation;
    if (text.len < 2 or text[0] != name or text[1] != '=') return error.ProtocolViolation;
    return text[2..];
}

fn authMessageMac(out: *[Hmac.mac_length]u8, key: []const u8, first_bare: []const u8, server_first: []const u8, final_without_proof: []const u8) void {
    var mac = Hmac.init(key);
    mac.update(first_bare);
    mac.update(",");
    mac.update(server_first);
    mac.update(",");
    mac.update(final_without_proof);
    mac.final(out);
}

test "SCRAM-SHA-256 matches the RFC 7677 example exchange" {
    var client = Client.withNonce("user", "rOprNGfwEbeRWgbNEkqO", .unsupported);
    var buffer: [max_message_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("n,,n=user,r=rOprNGfwEbeRWgbNEkqO", client.clientFirst(&buffer));
    const server_first = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";
    try std.testing.expectEqualStrings(
        "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=",
        try client.clientFinal(server_first, "pencil", &buffer),
    );
    try std.testing.expectError(error.AuthFailed, client.verifyServerFinal("v=AAAATRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="));
    try std.testing.expect(!client.verified);
    try client.verifyServerFinal("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=");
    try std.testing.expect(client.verified);
}

test "a server nonce that does not extend the client's, or a mandatory extension, is refused" {
    var buffer: [max_message_bytes]u8 = undefined;
    var client = Client.withNonce("", "abc", .unsupported);
    try std.testing.expectError(error.ProtocolViolation, client.clientFinal("r=abd123,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096", "pencil", &buffer));
    try std.testing.expectError(error.ProtocolViolation, client.clientFinal("r=abc,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096", "pencil", &buffer));
    try std.testing.expectError(error.ProtocolViolation, client.clientFinal("m=x,r=abc1,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096", "pencil", &buffer));
    try std.testing.expectError(error.ProtocolViolation, client.clientFinal("r=abc1,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=0", "pencil", &buffer));
    try std.testing.expectError(error.UnsupportedIterations, client.clientFinal("r=abc1,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=1000001", "pencil", &buffer));
    // The longest server nonce accepted still fits the client-final buffer.
    const longest = "r=abc" ++ @as([max_server_first_bytes - "r=abc,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=1".len]u8, @splat('x')) ++ ",s=W22ZaJ0SNY7soEsUEjb6gQ==,i=1";
    _ = try client.clientFinal(longest, "pencil", &buffer);
    try std.testing.expectError(error.ProtocolViolation, client.clientFinal("r=abcx" ++ longest[5..], "pencil", &buffer));
    try std.testing.expectError(error.AuthFailed, client.verifyServerFinal("e=invalid-proof"));
}

test "channel binding sends the certificate hash behind the p= header" {
    var hash: ChannelBinding = .{ .buffer = undefined, .len = 32 };
    @memset(hash.buffer[0..32], 0xab);
    var client = Client.withNonce("", "abc", .{ .server_end_point = hash });
    var buffer: [max_message_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("p=tls-server-end-point,,n=,r=abc", client.clientFirst(&buffer));
    const final = try client.clientFinal("r=abc1,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=1", "pencil", &buffer);
    var expected_input: [24 + 32]u8 = undefined;
    @memcpy(expected_input[0..24], "p=tls-server-end-point,,");
    @memset(expected_input[24..], 0xab);
    var expected: [base64.Encoder.calcSize(expected_input.len)]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, final[2..], base64.Encoder.encode(&expected, &expected_input)));
}

test "passwords outside printable ASCII are refused before any message" {
    try checkPassword("pencil ~!");
    try std.testing.expectError(error.UnsupportedPassword, checkPassword("p\xc3\xa9ncil"));
    try std.testing.expectError(error.UnsupportedPassword, checkPassword("pen\tcil"));
}
