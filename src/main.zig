const std = @import("std");
const json_rpc = @import("json_rpc.zig");
const Logger = @import("logger.zig").Logger;
const mcp = @import("mcp/server.zig");
const Managed = @import("managed.zig").Managed;
const ManagedResponse = Managed(json_rpc.Response);
const Response = json_rpc.Response;
const builtin = @import("builtin");

const use_log_file = switch (builtin.target.os.tag) {
    .linux => true,
    .macos => true,
    else => false,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const main_allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("Memory LEAK");
    }

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    var logger = Logger.init(main_allocator);
    defer logger.deinit();

    try logger.streams.append(
        std.io.getStdErr().writer().any(),
    );

    const log_file: ?std.fs.File = if (use_log_file) try std.fs.cwd().createFile("logs.txt", .{
        .truncate = false,
    }) else null;
    defer if (log_file) |f| {
        f.close();
    };

    if (log_file) |f| {
        const stat = try f.stat();
        try f.seekTo(stat.size);
        try logger.streams.append(f.writer().any());
    }

    try logger.info("Starting MCP Server");

    const request_buffer = try main_allocator.alloc(u8, 4 * 1024 * 1024);
    defer main_allocator.free(request_buffer);

    var result_outputs = try std.ArrayList(
        std.io.AnyWriter,
    ).initCapacity(main_allocator, 3);
    try result_outputs.append(stdout.any());
    try result_outputs.appendSlice(logger.streams.items);

    const transport = mcp.Transport{
        .in = stdin.any(),
        .out = stdout.any(),
    };

    var mcp_server = try mcp.Server.init(main_allocator, transport);

    const Hello = struct {
        const Params = struct {
            name: []const u8,
        };

        fn handle(
            allocator: std.mem.Allocator,
            params: Params,
        ) !Response {
            var content = try std.json.Array.initCapacity(
                allocator,
                1,
            );
            var hello_message = std.ArrayList(u8).init(
                allocator,
            );

            try hello_message.writer().writeAll("Hello ");
            try hello_message.writer().writeAll(params.name);
            try hello_message.writer().writeAll("\nHow are youd doing?");

            var content_item = std.json.ObjectMap.init(allocator);
            try content_item.put("type", .{ .string = "text" });
            try content_item.put("text", .{ .string = hello_message.items });
            try content.append(.{ .object = content_item });

            var result = std.json.ObjectMap.init(allocator);
            try result.put("content", .{ .array = content });

            return .{ .result = json_rpc.Result.create(.{
                .object = result,
            }) };
        }
    };

    try mcp_server.defineTool(
        Hello.Params,
        "hello_world",
        "Check the params.\n",
        \\{
        \\    "name": {"type": "string"},
        \\    "age": {"type": "number", "optional": true}
        \\}
    ,
        Hello.handle,
    );

    while (true) {
        const raw_message = stdin.readUntilDelimiter(
            request_buffer,
            '\n',
        ) catch |err| switch (err) {
            error.EndOfStream, error.StreamTooLong => {
                continue;
            },
            else => return err,
        };
        const message = std.mem.trimRight(u8, raw_message, "\r");

        if (message.len > 0) {
            const requests = json_rpc.deserializeRequests(
                main_allocator,
                message,
            ) catch |err| {
                try logger.err(@errorName(err));
                try logger.err(message);
                continue;
            };
            try logger.info(message);
            defer requests.deinit();
            try logger.info(requests.value);
            if (requests.value.len == 0) continue;

            var responses = try main_allocator.alloc(
                ?ManagedResponse,
                requests.value.len,
            );
            defer main_allocator.free(responses);
            for (responses, 0..) |_, idx| {
                responses[idx] = null;
            }
            defer for (responses) |res| {
                if (res) |r| {
                    r.deinit();
                }
            };

            for (requests.value, 0..) |req, idx| {
                const resp = mcp_server.handleRequest(
                    req,
                ) catch |err| switch (err) {
                    else => |e| {
                        try logger.err(@errorName(e));
                        return e;
                    },
                };
                if (resp == null) continue;

                for (result_outputs.items) |stream| {
                    try json_rpc.serializeResponse(
                        resp.?.value,
                        stream,
                    );
                }

                responses[idx] = resp;
            }
        }
    }
}
