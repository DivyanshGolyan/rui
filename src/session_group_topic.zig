const std = @import("std");

pub const Key = [32]u8;

// This is deliberately an exact classifier, not a fuzzy or transitive clusterer.
// Labels are at most 100 bytes. The fallback needs 2..16 distinct informative
// words and at least 8 word bytes, excluding separators and generic task words.
// Unsupported input yields no suggestion; callers own durable/manual grouping.
pub fn key(workspace: []const u8, label: []const u8) ?Key {
    if (label.len == 0 or label.len > 100 or !std.unicode.utf8ValidateSlice(label)) return null;
    var view = std.unicode.Utf8View.initUnchecked(label);
    var scalars = view.iterator();
    var ascii = true;
    while (scalars.nextCodepoint()) |scalar| {
        if (scalar < 0x20 or (scalar >= 0x7f and scalar <= 0x9f) or
            (scalar >= 0x2028 and scalar <= 0x202e) or
            (scalar >= 0x2066 and scalar <= 0x2069)) return null;
        if (scalar >= 0x80) ascii = false;
    }

    var lower: [100]u8 = undefined;
    for (label, 0..) |byte, i| lower[i] = std.ascii.toLower(byte);
    const text = lower[0..label.len];
    var reference: ?[]const u8 = null;
    var reference_kind: enum { github, ticket } = .ticket;
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "https://")) {
            // Never extract a valid-looking suffix from another hostname/URL.
            if (i > 0 and !referenceBoundary(text[i - 1])) return null;
            var end = i;
            while (end < text.len and !referenceBoundary(text[end])) : (end += 1) {}
            var url: []const u8 = text[i..end];
            url = std.mem.trimEnd(u8, url, ".");
            const identity = githubIdentity(url) orelse return null;
            if (reference) |previous| {
                if (reference_kind != .github or !std.mem.eql(u8, previous, identity)) return null;
            }
            reference = identity;
            reference_kind = .github;
            i = end;
            continue;
        }
        // A different scheme, malformed URL, or hostname must not become words.
        if (std.mem.startsWith(u8, text[i..], "://")) return null;
        if (std.ascii.isAlphanumeric(text[i]) or text[i] == '-') {
            const start = i;
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '-')) : (i += 1) {}
            const word = text[start..i];
            if (ticketIdentity(word)) {
                if (reference) |previous| {
                    if (reference_kind != .ticket or !std.mem.eql(u8, previous, word)) return null;
                }
                reference = word;
                reference_kind = .ticket;
            }
        } else i += 1;
    }
    if (reference) |identity| {
        // Non-ASCII text is not reduced to ASCII words or ticket fragments.
        if (!ascii and reference_kind != .github) return null;
        return digest(workspace, if (reference_kind == .github) "github" else "ticket", &.{identity});
    }
    if (!ascii) return null;

    var words: [16][]const u8 = undefined;
    var count: usize = 0;
    var informative_bytes: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, text, " !\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~");
    while (tokens.next()) |word| {
        if (word.len < 2 or generic(word)) continue;
        var has_letter = false;
        for (word) |byte| {
            if (std.ascii.isAlphabetic(byte)) has_letter = true;
        }
        if (!has_letter) continue;
        var position: usize = 0;
        while (position < count and std.mem.order(u8, words[position], word) == .lt) : (position += 1) {}
        if (position < count and std.mem.eql(u8, words[position], word)) continue;
        if (count == words.len) return null;
        var shift = count;
        while (shift > position) : (shift -= 1) words[shift] = words[shift - 1];
        words[position] = word;
        count += 1;
        informative_bytes += word.len;
    }
    if (count < 2 or informative_bytes < 8) return null;
    return digest(workspace, "words", words[0..count]);
}

fn referenceBoundary(byte: u8) bool {
    return byte == ' ' or std.mem.indexOfScalar(u8, "<>\"'()[]{},;!", byte) != null;
}

fn githubIdentity(url: []const u8) ?[]const u8 {
    const prefix = "https://github.com/";
    if (!std.mem.startsWith(u8, url, prefix)) return null;
    const path = std.mem.trimEnd(u8, url[prefix.len..], "/");
    // Only a single optional trailing slash is accepted.
    if (url.len - prefix.len - path.len > 1) return null;
    var parts = std.mem.splitScalar(u8, path, '/');
    const owner = parts.next() orelse return null;
    const repo = parts.next() orelse return null;
    const kind = parts.next() orelse return null;
    const number = parts.next() orelse return null;
    if (parts.next() != null or !githubPart(owner, false) or !githubPart(repo, true)) return null;
    if (!std.mem.eql(u8, kind, "issues") and !std.mem.eql(u8, kind, "pull")) return null;
    if (!positiveNumber(number)) return null;
    return path;
}

fn githubPart(part: []const u8, repository: bool) bool {
    if (part.len == 0 or !std.ascii.isAlphanumeric(part[0]) or !std.ascii.isAlphanumeric(part[part.len - 1])) return false;
    for (part) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and !(repository and (byte == '_' or byte == '.'))) return false;
    }
    return true;
}

fn positiveNumber(number: []const u8) bool {
    if (number.len == 0 or number[0] < '1' or number[0] > '9') return false;
    for (number) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn ticketIdentity(word: []const u8) bool {
    const hyphen = std.mem.indexOfScalar(u8, word, '-') orelse return false;
    if (hyphen < 2) return false;
    for (word[0..hyphen]) |byte| if (!std.ascii.isAlphabetic(byte)) return false;
    return positiveNumber(word[hyphen + 1 ..]);
}

fn generic(word: []const u8) bool {
    const excluded = [_][]const u8{
        "a",         "an",     "and",     "are",      "as",    "at",     "be",      "by",    "for",    "from",   "in",        "is",             "it",      "of",          "on",      "or",     "the",      "to",     "with",
        "add",       "adding", "check",   "checking", "code",  "create", "debug",   "fix",   "fixes",  "fixing", "implement", "implementation", "improve", "investigate", "latest",  "new",    "refactor", "remove", "review",
        "reviewing", "run",    "support", "task",     "tasks", "test",   "testing", "tests", "update", "verify", "work",      "bug",            "feature", "change",      "changes", "please", "start",    "chat",   "conversation",
        "hello",     "world",  "quick",   "look",     "take",  "help",   "me",      "this",  "that",   "some",   "general",
    };
    for (excluded) |value| if (std.mem.eql(u8, word, value)) return true;
    return false;
}

fn digest(workspace: []const u8, signal: []const u8, identities: []const []const u8) Key {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("rui.session-group-topic.v1");
    hashPart(&hash, signal);
    hashPart(&hash, workspace);
    for (identities) |identity| hashPart(&hash, identity);
    return hash.finalResult();
}

fn hashPart(hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(bytes.len), .big);
    hash.update(&length);
    hash.update(bytes);
}

fn expectSame(workspace: []const u8, a: []const u8, b: []const u8) !void {
    const left = key(workspace, a) orelse return error.ExpectedTopic;
    const right = key(workspace, b) orelse return error.ExpectedTopic;
    try std.testing.expectEqual(left, right);
}

fn expectDifferent(workspace: []const u8, a: []const u8, b: []const u8) !void {
    const left = key(workspace, a) orelse return error.ExpectedTopic;
    const right = key(workspace, b) orelse return error.ExpectedTopic;
    try std.testing.expect(!std.mem.eql(u8, &left, &right));
}

test "session topic salient words are exact sorted distinct case insensitive sets" {
    try expectSame("/project", "Fix session grouping", "Test GROUPING: session, session!");
    try expectSame("/project", "Review token refresh", "Implement refresh token");
    try expectDifferent("/project", "session grouping", "session rendering");
    try expectDifferent("/project", "session grouping", "session grouping storage");
    for ([_][]const u8{ "", "Fix", "latest code tests", "review the code", "implement new feature", "session", "fix bug", "123 456", "ab cde", "go home", "abc defg", "hello world", "start new conversation", "quick code review", "help me with this" }) |label| {
        try std.testing.expect(key("/same", label) == null);
    }
    try std.testing.expect(key("/same", "abc defgh") != null);
}

test "session topic strong references override surrounding task words" {
    try expectSame("w", "Fix AUTH-123", "review auth-123 auth-123");
    try expectDifferent("w", "AUTH-123", "AUTH-124");
    try expectDifferent("w", "AUTH-123", "BILL-123");
    try expectSame("w", "Fix https://github.com/Org/Repo/issues/12", "https://GITHUB.COM/org/repo/issues/12/.");
    try expectSame("w", "https://github.com/a/b/pull/1", "审查 https://github.com/a/b/pull/1");
    try expectDifferent("w", "https://github.com/a/b/issues/1", "https://github.com/a/b/pull/1");
    try expectDifferent("w", "https://github.com/a/b/issues/1", "https://github.com/a/b/issues/2");
    try expectDifferent("w", "https://github.com/a/b/issues/1", "https://github.com/c/b/issues/1");
    try expectDifferent("w", "https://github.com/a/b/issues/1", "https://github.com/a/c/issues/1");
    try expectSame("w", "https://github.com/a/b/issues/1", "https://github.com/a/b/issues/1 https://github.com/a/b/issues/1");
}

test "session topic refuses ambiguous malformed or spoofed references" {
    for ([_][]const u8{
        "AUTH-123 AUTH-124",                                               "AUTH-123 BILL-123",                     "AUTH-123 https://github.com/a/b/issues/1",
        "https://github.com/a/b/issues/1 https://github.com/a/b/issues/2", "https://github.com.evil/a/b/issues/1",  "https://evil/github.com/a/b/issues/1",
        "https://evil.com/https://github.com/a/b/issues/1",                "evilhttps://github.com/a/b/issues/1",   "https://github.com@evil.com/a/b/issues/1",
        "http://github.com/a/b/issues/1",                                  "https://github.com/a/b/issues/01",      "https://github.com/a/b/issues/0",
        "https://github.com/a/b/issues/1?x=y",                             "https://github.com/a/b/issues/1/extra", "https://github.com/a/b/issues/1//",
        "https://github.com/a/b/issues/1#fragment",
    }) |label| try std.testing.expect(key("w", label) == null);
}

test "session topic bounds unicode controls and exact workspace isolation" {
    for ([_][]const u8{ "résumé grouping", "session 分组", "session gro\xffuping", "session\x1b grouping", "session\n grouping", "session\t grouping", "session\x7f grouping", "session\xc2\x85 grouping", "AUTH-123 α", "session\xe2\x80\xae grouping" }) |label| {
        try std.testing.expect(key("w", label) == null);
    }
    const a = key("/w", "session grouping").?;
    const b = key("/w/", "session grouping").?;
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    const c = key("a\x00b", "session grouping").?;
    const d = key("a", "session grouping").?;
    try std.testing.expect(!std.mem.eql(u8, &c, &d));
    try std.testing.expect(key("w", "auth 123") == null);
    var exact: [100]u8 = @splat(' ');
    @memcpy(exact[0..16], "session grouping");
    try std.testing.expectEqual(@as(usize, 100), exact.len);
    try expectSame("w", "session grouping", &exact);
    try std.testing.expect(key("w", &(exact ++ " ".*)) == null);
    try std.testing.expect(key("w", "aa bb cc dd ee ff gg hh ii jj kk ll mm nn oo pp") != null);
    try std.testing.expect(key("w", "aa bb cc dd ee ff gg hh ii jj kk ll mm nn oo pp qq") == null);
    try expectSame("w", "aa bb cc dd ee ff gg hh ii jj kk ll mm nn oo pp", "aa bb cc dd ee ff gg hh ii jj kk ll mm nn oo pp aa");
}
