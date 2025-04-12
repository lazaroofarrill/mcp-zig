const std = @import("std");

pub fn Validator(comptime T: type) type {
    return struct {
        const Self = @This();

        pub fn withString() void {}

        pub fn parse(val: T) T {
            return val;
        }
    };
}
