pub const max_bytes = 96;

/// A provider failure report keeps its code and its message, each at most this many bytes.
pub const max_report_part_bytes = 256;
pub const max_report_bytes = 2 * max_report_part_bytes + ": ".len + 2 * "…".len;
