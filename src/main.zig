const std = @import("std");
const json_rpc = @import("json_rpc.zig");
const Logger = @import("logger.zig").Logger;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    var log_file = try std.fs.cwd().createFile("logs.txt", .{
        .truncate = false,
    });
    defer log_file.close();
    const stat = try log_file.stat();
    try log_file.seekTo(stat.size);

    var logger = Logger.initDefault(allocator);
    defer logger.deinit();

    try logger.streams.append(std.io.getStdErr());
    try logger.streams.append(log_file);

    try logger.info("Starting MCP Server");
    while (true) {
        const message = try stdin.readUntilDelimiterAlloc(
            allocator,
            '\n',
            1024 * 1024,
        );
        defer allocator.free(message);
        if (message.len > 0) {
            const parsed = json_rpc.deserializeRequest(
                allocator,
                message,
            ) catch {
                try logger.err(message);
                continue;
            };
            defer parsed.deinit();

            const result = json_rpc.Result{ .jsonrpc = try allocator.dupe(u8, "2.0"), .result = .{ .string = "nothing to do here" } };
            defer if (result.jsonrpc) |field| {
                allocator.free(field);
            };

            try stdout.writeAll(
                try json_rpc.serializeResponse(
                    allocator,
                    .{ .result = result },
                ),
            );

            try logger.info(parsed.value);
        }
    }
}
