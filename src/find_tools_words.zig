pub const FindTools = struct {
    words: [8][]const u8 = @splat(""),
    count: usize = 0,
    /// True when the caller asked Rui to list every MCP server again before the search.
    reload: bool = false,
    /// The reload's report, written before any matches. The Host sets it once the reload's lists have landed.
    report: ?[]const u8 = null,
};
