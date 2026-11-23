pub const FindTools = struct {
    words: [8][]const u8 = @splat(""),
    count: usize = 0,
    /// True when the caller asked Rui to list every MCP server again before the search.
    reload: bool = false,
    /// The reload's report, written before any matches. The Host sets it when the reload asks, in the same pass.
    report: ?[]const u8 = null,
};
