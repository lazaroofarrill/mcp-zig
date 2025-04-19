const std = @import("std");

pub fn toJsonValue(value: anytype, allocator: std.mem.Allocator) anyerror!std.json.Parsed(
    std.json.Value,
) {
    const string_val = try std.json.stringifyAlloc(allocator, value, .{});
    defer allocator.free(string_val);

    const json_val = try std.json.parseFromSlice(std.json.Value, allocator, string_val, .{});

    return json_val;
}
