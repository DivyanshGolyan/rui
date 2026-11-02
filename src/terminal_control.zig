//! Which code points must never reach a terminal raw: C0, DEL and C1
//! controls act on it, and bidi controls reorder the text the user reads.

pub fn isControl(scalar: u21) bool {
    return scalar < 0x20 or scalar >= 0x7f and scalar <= 0x9f or
        scalar == 0x061c or scalar == 0x200e or scalar == 0x200f or
        scalar >= 0x202a and scalar <= 0x202e or
        scalar >= 0x2066 and scalar <= 0x2069;
}
