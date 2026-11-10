//! A Store selector's canonical path.

// SQLite's Unix VFS needs eight bytes beyond the database path for journals.
// The Store selector plus "/rui.sqlite3" and the journal suffix must stay
// within its compiled 512-byte pathname limit.
pub const max_bytes = 492;
pub const database_suffix = "/rui.sqlite3";
pub const max_database_path_bytes = max_bytes + database_suffix.len;
