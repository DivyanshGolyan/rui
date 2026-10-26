//! System trust on macOS: Apple SecTrust verifies the peer. Internal.
//!
//! The OpenSSL store stays empty and the handshake accepts the chain for
//! now. After the handshake, before any application byte, the connection
//! is `verifying`: a `job.Job` thread evaluates the full peer chain (leaf
//! first) with the TLS server policy for the host and the revocation
//! policy, so the system trust settings decide (keychains, user and admin
//! trust, Apple's distrust and revocation data). The evaluation may block
//! on trustd and the network, which is why it is off the execution thread.
//! A missing verdict is a failure.
//!
//! `.ca_file` does not come here: OpenSSL verifies it in the handshake, on
//! both platforms.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("h2_c");
const h2 = @import("h2.zig");
const Waker = @import("Waker.zig");
const job = @import("job.zig");

pub const enabled = builtin.os.tag.isDarwin();

/// `failed` is a local failure (out of memory), not the peer's.
pub const Verdict = enum { trusted, untrusted, failed };

pub const Job = job.Job(Verification);

/// Defers verification of every session from `ctx` to a `Verification`.
pub fn deferVerification(ctx: *c.SSL_CTX) void {
    c.SSL_CTX_set_cert_verify_callback(ctx, acceptForNow, null);
}

/// OpenSSL's verifier slot. The connection does not leave `verifying`
/// without SecTrust's verdict, so no application byte depends on this.
fn acceptForNow(_: ?*c.X509_STORE_CTX, _: ?*anyopaque) callconv(.c) c_int {
    return 1;
}

pub const Verification = struct {
    host: [h2.max_host_bytes]u8,
    host_len: u8,
    /// The peer's chain as DER, leaf first, in one allocation.
    der: []u8,
    /// Where each certificate ends in `der`.
    ends: []u32,
    verdict: Verdict,

    /// Starts evaluating the chain `ssl` received against `host`; null when
    /// it could not start (out of memory, or no thread).
    pub fn start(waker: *Waker, ssl: *c.SSL, host: []const u8) ?*Job {
        std.debug.assert(host.len <= h2.max_host_bytes);
        // No chain is the peer's failure, which `evaluate` reports.
        const chain: ?*c.OPENSSL_STACK = @ptrCast(c.SSL_get_peer_cert_chain(ssl));
        const count: usize = if (chain) |sent| @intCast(@max(0, c.OPENSSL_sk_num(sent))) else 0;
        var total: usize = 0;
        for (0..count) |index| total += @intCast(@max(0, c.i2d_X509(certificateAt(chain.?, index), null)));
        const allocator = std.heap.c_allocator;
        const der = allocator.alloc(u8, total) catch return null;
        const ends = allocator.alloc(u32, count) catch {
            allocator.free(der);
            return null;
        };
        var verification: Verification = .{ .host = undefined, .host_len = @intCast(host.len), .der = der, .ends = ends, .verdict = .failed };
        @memcpy(verification.host[0..host.len], host);
        var cursor: [*c]u8 = der.ptr;
        for (0..count) |index| {
            if (c.i2d_X509(certificateAt(chain.?, index), &cursor) < 0) {
                verification.deinit();
                return null;
            }
            ends[index] = @intCast(cursor - der.ptr);
        }
        return Job.start(waker, verification);
    }

    pub fn run(self: *Verification) void {
        self.verdict = self.evaluate();
    }

    pub fn deinit(self: *Verification) void {
        std.heap.c_allocator.free(self.der);
        std.heap.c_allocator.free(self.ends);
    }

    fn evaluate(self: *const Verification) Verdict {
        if (self.ends.len == 0) return .untrusted;
        const certificates = CFArrayCreateMutable(null, @intCast(self.ends.len), &kCFTypeArrayCallBacks) orelse return .failed;
        defer CFRelease(certificates);
        var start_offset: usize = 0;
        for (self.ends) |end| {
            const bytes = self.der[start_offset..end];
            start_offset = end;
            const data = CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return .failed;
            defer CFRelease(data);
            // Not a certificate SecTrust can read: the peer's to answer for.
            const certificate = SecCertificateCreateWithData(null, data) orelse return .untrusted;
            defer CFRelease(certificate);
            CFArrayAppendValue(certificates, certificate);
        }

        const host = CFStringCreateWithBytes(null, &self.host, self.host_len, kCFStringEncodingUTF8, 0) orelse return .failed;
        defer CFRelease(host);
        const policies = CFArrayCreateMutable(null, 2, &kCFTypeArrayCallBacks) orelse return .failed;
        defer CFRelease(policies);
        const ssl_policy = SecPolicyCreateSSL(1, host) orelse return .failed;
        defer CFRelease(ssl_policy);
        CFArrayAppendValue(policies, ssl_policy);
        const revocation = SecPolicyCreateRevocation(kSecRevocationUseAnyAvailableMethod) orelse return .failed;
        defer CFRelease(revocation);
        CFArrayAppendValue(policies, revocation);

        var trust: ?*SecTrust = null;
        if (SecTrustCreateWithCertificates(certificates, policies, &trust) != 0) return .failed;
        defer CFRelease(trust.?);
        var failure: ?*CFError = null;
        const trusted = SecTrustEvaluateWithError(trust.?, &failure);
        if (failure) |error_ref| CFRelease(error_ref);
        return if (trusted) .trusted else .untrusted;
    }
};

fn certificateAt(chain: *c.OPENSSL_STACK, index: usize) *c.X509 {
    return @ptrCast(c.OPENSSL_sk_value(chain, @intCast(index)).?);
}

// ------------------------------------------- CoreFoundation and Security

const CFArray = opaque {};
const CFData = opaque {};
const CFString = opaque {};
const CFError = opaque {};
const SecCertificate = opaque {};
const SecPolicy = opaque {};
const SecTrust = opaque {};

const kCFStringEncodingUTF8: u32 = 0x08000100;
/// kSecRevocationOCSPMethod | kSecRevocationCRLMethod.
const kSecRevocationUseAnyAvailableMethod: c_ulong = 3;

const CFArrayCallBacks = extern struct {
    version: c_long,
    retain: ?*const anyopaque,
    release: ?*const anyopaque,
    copy_description: ?*const anyopaque,
    equal: ?*const anyopaque,
};

extern const kCFTypeArrayCallBacks: CFArrayCallBacks;
extern fn CFRelease(object: *const anyopaque) void;
extern fn CFDataCreate(allocator: ?*anyopaque, bytes: [*]const u8, length: c_long) ?*CFData;
extern fn CFArrayCreateMutable(allocator: ?*anyopaque, capacity: c_long, callbacks: *const CFArrayCallBacks) ?*CFArray;
extern fn CFArrayAppendValue(array: *CFArray, value: *const anyopaque) void;
extern fn CFStringCreateWithBytes(allocator: ?*anyopaque, bytes: [*]const u8, length: c_long, encoding: u32, external: u8) ?*CFString;
extern fn SecCertificateCreateWithData(allocator: ?*anyopaque, data: *CFData) ?*SecCertificate;
extern fn SecPolicyCreateSSL(server: u8, hostname: *CFString) ?*SecPolicy;
extern fn SecPolicyCreateRevocation(flags: c_ulong) ?*SecPolicy;
extern fn SecTrustCreateWithCertificates(certificates: *CFArray, policies: *CFArray, trust: *?*SecTrust) i32;
extern fn SecTrustEvaluateWithError(trust: *SecTrust, failure: ?*?*CFError) bool;
