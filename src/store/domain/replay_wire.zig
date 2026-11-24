//! The Store's reading of a replay Wire and Binding from its values. A provider and a codec
//! become a `replay_binding.Wire` only here; the sites that decide replay call these
//! helpers instead of spelling the connection name or the dialect themselves.
//!
//! Each stored Operation's Binding is read from its frozen revision (`session_revision`:
//! the connection, the codec and the model), so an item's producer is the revision that
//! wrote it, never the request's Wire.

const connection = @import("../../connection.zig");
const std = @import("std");
const provider_name = @import("../../provider_name.zig");
const codecs = @import("../../codecs.zig");
const replay_binding = @import("../../replay_binding.zig");

/// The Wire of a provider and codec. The Wire holds a copy of the connection name, so it
/// outlives the row the name was read from.
pub fn wireOf(provider: connection.Name, codec: provider_name.Codec) replay_binding.Wire {
    return .{ .connection = provider, .dialect = codecs.dialect(codec) };
}

/// The request's Binding: its Wire and the model it asks for.
pub fn bindingOf(wire: replay_binding.Wire, model: []const u8) replay_binding.Binding {
    return .{ .wire = wire, .model = model };
}

/// A Binding read from optional Store columns (a LEFT JOIN to a base or producer revision).
/// A missing column in a row that must have one is a corrupt Store.
pub fn optionalBinding(provider: ?connection.Name, codec: ?provider_name.Codec, model: ?[]const u8) error{CorruptStore}!replay_binding.Binding {
    return bindingOf(wireOf(provider orelse return error.CorruptStore, codec orelse return error.CorruptStore), model orelse return error.CorruptStore);
}

/// The SQL column list that reads one Operation's Binding (provider, codec and model) from a
/// revision alias. One owner of the spelling, so each reader names the same three columns.
pub fn operationBindingSql(comptime alias: []const u8) []const u8 {
    return alias ++ ".provider," ++ alias ++ ".codec," ++ alias ++ ".model";
}

/// The same three columns as `operationBindingSql`, named `<prefix>_provider`,
/// `<prefix>_codec` and `<prefix>_model` for a row that carries a base or producer Binding.
pub fn operationBindingAsSql(comptime alias: []const u8, comptime prefix: []const u8) []const u8 {
    return alias ++ ".provider AS " ++ prefix ++ "_provider," ++ alias ++ ".codec AS " ++ prefix ++ "_codec," ++ alias ++ ".model AS " ++ prefix ++ "_model";
}

/// One side of a SQL Binding comparison: a SQL expression for each of the three values.
/// A side is a revision alias (`revisionSide`) or a request's values held in a CTE.
pub const Side = struct {
    provider: []const u8,
    codec: []const u8,
    model: []const u8,
};

pub fn revisionSide(comptime alias: []const u8) Side {
    return .{ .provider = alias ++ ".provider", .codec = alias ++ ".codec", .model = alias ++ ".model" };
}

/// The dialect of a codec expression, as a CASE over the codec's stored text.
fn dialectSql(comptime codec: []const u8) []const u8 {
    comptime var out: []const u8 = "CASE";
    inline for (std.meta.tags(provider_name.Codec)) |tag| {
        out = out ++ " WHEN " ++ codec ++ "='" ++ @tagName(tag) ++ "' THEN '" ++ @tagName(codecs.dialect(tag)) ++ "'";
    }
    return out ++ " END";
}

/// SQL true when two sides name the same Binding: the same connection, the same dialect
/// (derived from each codec) and the same model. The one spelling of "same Binding" in SQL;
/// Zig callers use `Binding.eql`.
pub fn sameBindingSql(comptime left: Side, comptime right: Side) []const u8 {
    return "(" ++ left.provider ++ "=" ++ right.provider ++ " AND " ++ dialectSql(left.codec) ++ "=" ++ dialectSql(right.codec) ++
        " AND " ++ left.model ++ "=" ++ right.model ++ ")";
}
