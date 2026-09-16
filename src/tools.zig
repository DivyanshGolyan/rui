const protocol = @import("protocol.zig");

pub const bash_definition_json =
    "{\"type\":\"function\",\"name\":\"bash\",\"description\":\"Run Bash\",\"strict\":true," ++
    "\"parameters\":{\"type\":\"object\",\"properties\":{\"cmd\":{\"type\":\"string\"}}," ++
    "\"required\":[\"cmd\"],\"additionalProperties\":false}}";

pub fn validBashArguments(source: anytype) !bool {
    source.expect('{') catch |err| return descriptorSyntax(err);
    var key: protocol.Bounded(16) = .{};
    source.string(&key) catch |err| return descriptorSyntax(err);
    if (!key.eql("cmd")) return false;
    source.expect(':') catch |err| return descriptorSyntax(err);
    source.string(null) catch |err| return descriptorSyntax(err);
    try source.space();
    const close = source.take() catch |err| return descriptorSyntax(err);
    if (close != '}') return false;
    try source.space();
    return try source.peek() == null;
}

fn descriptorSyntax(err: anyerror) anyerror!bool {
    return switch (err) {
        error.InvalidDescriptorJson, error.InvalidDescriptorShape, error.InvalidEncodedString => false,
        else => err,
    };
}
