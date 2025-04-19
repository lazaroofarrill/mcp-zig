const std = @import("std");
const builtin = @import("builtin");
const mcp = @import("mcp");
const Logger = mcp.Logger.Logger;

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

    const transport = mcp.transport.Transport{
        .in = stdin.any(),
        .out = stdout.any(),
    };

    var mcp_server = try mcp.server.Server.init(main_allocator, transport);
    defer mcp_server.deinit();

    const Hello = struct {
        const Params = struct {
            name: []const u8,
        };

        fn handle(
            allocator: std.mem.Allocator,
            params: Params,
        ) !mcp.json_rpc.Response {
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

            std.time.sleep(5 * std.time.ns_per_s);

            return .{ .result = mcp.json_rpc.Result.create(.{
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

    const AppContext = struct {
        logger: Logger,
    };

    const app_context: AppContext = .{
        .logger = logger,
    };
    try mcp_server.start(AppContext, &app_context);
}
