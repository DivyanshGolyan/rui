//! Every way the host OS changes what Rui does, outside the C sources.
//!
//! Linux CI predicts Mac CI because platform differences live in src/os/ and
//! nowhere else in Zig: tests/ci/platform_boundary.py rejects a platform name
//! or divergent syscall elsewhere, and a PR that changes src/os/ runs Mac
//! Selected.

const builtin = @import("builtin");

pub const tag = builtin.os.tag;

/// Rui's descriptor census, owner checks and process control are written for
/// these two kernels.
pub const supported = tag == .linux or tag == .macos;

/// Darwin's fsync leaves data in the drive cache; SQLite's fullfsync issues
/// F_FULLFSYNC so a committed Store survives power loss.
pub const full_fsync = tag == .macos;

/// curl verifies TLS against the Keychain on Darwin, where no CA bundle path
/// is conventional.
pub const native_trust_store = tag == .macos;

/// Linux's sysfs is read-only to every user, which tests use as a read-only
/// ancestor that no privilege can write.
pub const read_only_sysfs = tag == .linux;

/// Linux queues a connect beyond a full listen backlog until it times out;
/// Darwin refuses it at once.
pub const full_backlog_blocks_connect = tag == .linux;

/// Darwin may deliver a stack guard-page hit as SIGBUS, which Zig's handler
/// reports as a bus error; Linux delivers SIGSEGV.
pub const stack_guard_bus_error = tag == .macos;
