const std = @import("std");

pub const Transport = @This();

in: std.io.AnyReader,
out: std.io.AnyWriter,

mutex: std.Thread.Mutex = std.Thread.Mutex{},

pub fn writeThreadSafe(self: @This(), data: []const u8) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    try self.out.writeAll(data);
}
