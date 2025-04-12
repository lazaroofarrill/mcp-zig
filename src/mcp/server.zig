const std = @import("std");
const jrpc = @import("../json_rpc.zig");
const Logger = @import("../logger.zig").Logger;

pub const Transport = struct {
    in: std.io.AnyReader,
    out: std.io.AnyWriter,
};

pub const Server = struct {
    transport: Transport,
    logger: Logger,

    const MethodName = enum {
        initialize,
        @"tools/list",
    };

    pub fn handleRequest(
        server: @This(),
        req: jrpc.Request,
    ) !jrpc.Response {
        const method = std.meta.stringToEnum(
            MethodName,
            req.method,
        ) orelse {
            const error_message = "Method not found";
            return .{ .err = .{
                .id = req.id,
                .jsonrpc = req.jsonrpc,
                .err = .{
                    .code = @intFromEnum(
                        jrpc.Error.Code.method_not_found,
                    ),
                    .message = error_message[0..],
                    .data = .null,
                },
            } };
        };

        switch (method) {
            .initialize => {
                try server.logger.info(
                    "initialize called",
                );

                return .{ .result = .{
                    .id = req.id,
                    .jsonrpc = req.jsonrpc,
                    .result = .null,
                } };
            },
            .@"tools/list" => {
                try server.logger.info("listing tools");
                return .{
                    .result = .{
                        .id = req.id,
                        .jsonrpc = req.jsonrpc,
                        .result = .null,
                    },
                };
            },
        }
    }
};
