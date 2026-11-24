pub const Use = enum { history, selected_base };

pub const Kind = enum(u8) {
    reasoning = 1,
    message = 2,
    function_call = 3,
    compaction = 4,
    web_search_call = 5,
};
