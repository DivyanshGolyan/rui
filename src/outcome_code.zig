//! Resolution, rejection and failure codes, and a failed Turn's report.

pub const max_bytes = 96;

/// A failed Turn outcome's report: the provider's code and message, each
/// at most 256 bytes plus a shortened mark, and their separator.
pub const max_report_bytes = 2 * 256 + ": ".len + 2 * "…".len;
