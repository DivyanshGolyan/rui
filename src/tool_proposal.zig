//! A model's tool call proposal: the fields it certifies and why it can be
//! refused.

pub const Field = enum { name, call_id, arguments };
pub const Rejection = enum { unknown_tool, invalid_arguments };
