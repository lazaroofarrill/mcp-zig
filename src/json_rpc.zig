const std = @import("std");

const JsonRpcRequest = struct {
    jsonrpc: []u8,
    method: ?[]const u8 = null,
    params: std.json.Value,
    id: ?f64,
};

test "unmarshalling to struct" {
    const parsed = try std.json.parseFromSlice(
        JsonRpcRequest,
        std.testing.allocator,
        \\{
        \\    "id": 2,
        \\    "jsonrpc": "2.0",
        \\    "params": [
        \\        "baby"
        \\    ]
        // \\    "method": "give_me_data"
        \\}
    ,
        .{},
    );
    defer parsed.deinit();

    const result = parsed.value;

    try std.testing.expect(std.mem.eql(u8, result.jsonrpc, "2.0"));
    try std.testing.expectEqual(result.id, 2);

    const params = switch (result.params) {
        .array => |a| a,
        else => return error.UnexpectedTypeReceived,
    };

    const stringified_random = switch (params.items[0]) {
        .string => |s| s,
        else => return error.WrongTypeReceived,
    };

    try std.testing.expect(std.mem.eql(
        u8,
        stringified_random,
        "baby",
    ));
}
