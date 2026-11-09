/// The wire version every request and reply carries. It has this one owner,
/// so fixtures and harnesses read it here and a change to the protocol's
/// grammar selects no test that only needs the number.
pub const wire_version = "11";
