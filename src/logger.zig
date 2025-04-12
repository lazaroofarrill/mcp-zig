const std = @import("std");

pub const Logger = struct {
    streams: std.ArrayList(std.io.AnyWriter),
    allocator: std.mem.Allocator,
    level: Level,

    pub const trace = logFn(.trace);
    pub const debug = logFn(.debug);
    pub const info = logFn(.info);
    pub const warning = logFn(.warning);
    pub const err = logFn(.err);

    pub fn initWithLevel(allocator: std.mem.Allocator, level: Level) Logger {
        return Logger{
            .allocator = allocator,
            .streams = std.ArrayList(
                std.io.AnyWriter,
            ).init(allocator),
            .level = level,
        };
    }

    pub fn init(allocator: std.mem.Allocator) Logger {
        return initWithLevel(allocator, .info);
    }

    pub fn deinit(self: @This()) void {
        self.streams.deinit();
    }

    fn logFn(level: Level) fn (self: Logger, msg: anytype) error{LogError}!void {
        return struct {
            fn doLog(self: Logger, msg: anytype) error{LogError}!void {
                log(self, level, msg) catch return error.LogError;
            }
        }.doLog;
    }

    pub fn log(self: @This(), level: Level, msg: anytype) !void {
        var print_allocated_memory = false;
        const msg_type = @TypeOf(msg);
        const msg_type_info = @typeInfo(msg_type);
        const to_print = switch (msg_type) {
            []const u8,
            []u8,
            std.json.Value,
            => msg,
            else => blk: switch (msg_type_info) {
                .pointer => |pointer_info| {
                    const child = pointer_info.child;
                    const child_info = @typeInfo(child);

                    if (child_info == .array and child_info.array.child == u8) {
                        break :blk msg;
                    }

                    if (child == u8 and pointer_info.size == .slice) {
                        break :blk msg;
                    }
                    print_allocated_memory = true;
                    break :blk try std.fmt.allocPrint(
                        self.allocator,
                        "{any}",
                        .{msg},
                    );
                },
                .array => |arr_info| {
                    if (arr_info.child == u8) {
                        break :blk msg;
                    }
                    print_allocated_memory = true;
                    break :blk try std.fmt.allocPrint(
                        self.allocator,
                        "{any}",
                        .{msg},
                    );
                },
                else => {
                    print_allocated_memory = true;
                    break :blk try std.fmt.allocPrint(
                        self.allocator,
                        "{any}",
                        .{msg},
                    );
                },
            },
        };
        defer if (print_allocated_memory) {
            self.allocator.free(to_print);
        };

        for (self.streams.items) |stream| {
            try std.json.stringify(
                .{
                    .level = @intFromEnum(level),
                    .timestamp = std.time.milliTimestamp(),
                    .msg = to_print,
                },
                .{},
                stream,
            );
            try stream.writeAll("\n");
        }
    }

    pub const Level = enum(u8) {
        trace = 10,
        debug = 20,
        info = 30,
        warning = 40,
        err = 50,
    };
};
