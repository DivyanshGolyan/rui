/// Advance this epoch whenever a pre-release durable encoding changes
/// incompatibly. Host Store admission and build fixtures share it so cached
/// fixture state cannot cross an incompatible format boundary.
pub const epoch: u32 = 12;
