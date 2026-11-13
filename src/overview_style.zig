//! Shared presentation values for overview rows.
pub const Colour = enum {
    strong,
    ink,
    normal,
    quiet,
    mark,
    rule,
    attention,
    failure,
    on_band,
};

pub const Background = enum { ground, bar, input_surface, selection, hover, band };

pub const Style = struct {
    colour: Colour = .normal,
    background: Background = .ground,
    bold: bool = false,
    reverse: bool = false,
};

pub const Segment = struct {
    text: []const u8,
    style: Style,
};
