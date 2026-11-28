//! The character sets a column rule is written in: ranges and literals, as `@charset` writes them.

/// Whether `byte` is in a character set written as ranges and literals, as `@charset` writes it (`a-z0-9_-`):
/// `x-y` is a range except where the `-` leads or ends the set.
pub fn inSet(set: []const u8, byte: u8) bool {
    var at: usize = 0;
    while (at < set.len) {
        if (at + 2 < set.len and set[at + 1] == '-') {
            if (byte >= set[at] and byte <= set[at + 2]) return true;
            at += 3;
        } else {
            if (byte == set[at]) return true;
            at += 1;
        }
    }
    return false;
}
