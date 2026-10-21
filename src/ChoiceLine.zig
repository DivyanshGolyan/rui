//! A line typed at an Action's choice. It keeps the choice editor through its
//! Enter, even once the Action leaves or a page hides it, so none of it reaches
//! the draft, and nothing it keeps can decide. The editor and its bytes stay
//! with the caller.
const std = @import("std");
const Self = @This();

open: bool = false,

/// One event the choice editor applied. Typed, rejected or dropped input
/// begins a line; only a line end (Enter, the rejection Enter reports, end of
/// input or interrupt) ends it.
pub fn apply(self: *Self, began: bool, ended: bool) void {
    self.open = !ended and (self.open or began);
}

/// What of the line's text a change the choice did not see keeps: only a
/// slash command, which can never decide; other text could become a stale
/// decision. The line itself, with its rejection and paste custody, stays
/// open until Enter.
pub fn changed(text: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, text, "/")) text else text[0..0];
}

/// Whether the editor starts over after an event the choice saw while it
/// cannot decide: at a line end, or for text that is neither a slash command
/// nor typed beside an unread Action (reading its last row clears that).
/// A sequence still decoding keeps its editor.
pub fn end(ended: bool, text: []const u8, reading: bool, decoding: bool) bool {
    if (decoding) return false;
    return ended or (changed(text).len == 0 and !reading);
}

test "a choice line opens on typed input and closes only at its end" {
    var line: Self = .{};
    line.apply(false, false);
    try std.testing.expect(!line.open);
    line.apply(true, false);
    try std.testing.expect(line.open);
    // An event that types nothing keeps an open line open.
    line.apply(false, false);
    try std.testing.expect(line.open);
    // Text typed by the event that ends the line does not reopen it.
    line.apply(true, true);
    try std.testing.expect(!line.open);
    line.apply(false, true);
    try std.testing.expect(!line.open);
}

test "an unseen change keeps only a leading slash command" {
    try std.testing.expectEqualStrings("/status", changed("/status"));
    try std.testing.expectEqualStrings("/", changed("/"));
    try std.testing.expectEqualStrings("", changed("a"));
    try std.testing.expectEqualStrings("", changed("a/status"));
    try std.testing.expectEqualStrings("", changed(""));
}

test "the choice editor starts over at a line end or for text that cannot stay" {
    // A sequence still decoding keeps its editor, even at a line end.
    try std.testing.expect(!end(true, "a", false, true));
    try std.testing.expect(!end(false, "x", false, true));
    // Mid-line, a slash command stays, and so does text beside an unread Action.
    try std.testing.expect(!end(false, "/sta", false, false));
    try std.testing.expect(!end(false, "a", true, false));
    try std.testing.expect(end(false, "a", false, false));
    try std.testing.expect(end(false, "a/", false, false));
    // A line end always starts over.
    try std.testing.expect(end(true, "/status", false, false));
    try std.testing.expect(end(true, "a", true, false));
}
