const std = @import("std");
const json_rpc = @import("json_rpc.zig");

pub const Logger = struct {
    streams: std.ArrayList(std.fs.File),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Logger {
        return Logger{ .allocator = allocator, .streams = std.ArrayList(std.fs.File).init(allocator) };
    }

    pub fn deinit(self: @This()) void {
        self.streams.deinit();
    }

    pub fn log(self: @This(), level: Level, msg: anytype) !void {
        const to_print = switch (@TypeOf(msg)) {
            []const u8,
            []u8,
            std.json.Value,
            => msg,
            else => try std.fmt.allocPrint(
                self.allocator,
                "{any}",
                .{msg},
            ),
        };
        // defer self.allocator.free(to_print);
        for (self.streams.items) |stream| {
            const message = try std.json.stringifyAlloc(
                self.allocator,
                .{
                    .level = level,
                    .timestamp = std.time.timestamp(),
                    .msg = to_print,
                },
                .{},
            );
            defer self.allocator.free(message);
            const msg_with_lf = try std.fmt.allocPrint(self.allocator, "{s}\n", .{message});
            defer self.allocator.free(msg_with_lf);

            try stream.writeAll(msg_with_lf);
        }
    }

    pub const Level = enum { trace, info, debug, warning, err };
};

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

    try logger.streams.append(std.io.getStdErr());
    try logger.streams.append(log_file);

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
                try logger.log(.err, message);
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

            try logger.log(.info, parsed.value);
        }
    }
}
