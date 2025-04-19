const std = @import("std");

pub const Transport = @This();

in: std.io.AnyReader,
out: std.io.AnyWriter,
mutex: std.Thread.Mutex = std.Thread.Mutex{},

pub fn writeThreadSafe(self: *Transport, data: []const u8) anyerror!usize {
    self.mutex.lock();
    defer self.mutex.unlock();

    return try self.out.write(data);
}

pub const Writer = std.io.GenericWriter(*Transport, anyerror, writeThreadSafe);

pub fn writer(self: *Transport) Writer {
    return .{ .context = self };
}
