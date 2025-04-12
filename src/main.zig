const std = @import("std");
const json_rpc = @import("json_rpc.zig");
const Logger = @import("logger.zig").Logger;
const mcp = @import("mcp/server.zig");
const Managed = @import("managed.zig").Managed;

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

    var logger = Logger.init(allocator);
    defer logger.deinit();

    try logger.streams.append(
        std.io.getStdErr().writer().any(),
    );
    try logger.streams.append(log_file.writer().any());

    try logger.info("Starting MCP Server");

    const request_buffer = try allocator.alloc(u8, 4 * 1024 * 1024);
    defer allocator.free(request_buffer);

    var result_outputs = try std.ArrayList(
        std.io.AnyWriter,
    ).initCapacity(allocator, 3);
    try result_outputs.append(stdout.any());
    try result_outputs.appendSlice(logger.streams.items);

    const transport = mcp.Transport{
        .in = stdin.any(),
        .out = stdout.any(),
    };
    const mcp_server = try mcp.Server.init(allocator, .{
        .logger = logger,
        .transport = transport,
    });

    while (true) {
        const message = stdin.readUntilDelimiter(
            request_buffer,
            '\n',
        ) catch |err| {
            switch (err) {
                error.EndOfStream,
                error.StreamTooLong,
                => {
                    continue;
                },
                else => |e| return e,
            }
        };
        if (message.len > 0) {
            const requests = json_rpc.deserializeRequest(
                allocator,
                message,
            ) catch {
                try logger.err(message);
                continue;
            };
            defer requests.deinit();
            try logger.info(requests.value);
            if (requests.value.len == 0) continue;

            var responses = try allocator.alloc(
                Managed(json_rpc.Response),
                requests.value.len,
            );
            defer allocator.free(responses);
            defer for (responses) |res| {
                res.deinit();
            };

            for (requests.value, 0..) |req, idx| {
                responses[idx] = try mcp_server.handleRequest(
                    req,
                );
                for (result_outputs.items) |stream| {
                    try json_rpc.serializeResponse(
                        responses[idx].value,
                        stream,
                    );
                }
            }
        }
    }
}
