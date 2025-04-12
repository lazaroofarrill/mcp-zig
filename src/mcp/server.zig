const std = @import("std");
const jrpc = @import("../json_rpc.zig");
const Logger = @import("../logger.zig").Logger;
const Managed = @import("../managed.zig").Managed;

const ObjectMap = std.json.ObjectMap;
const ArrayList = std.ArrayList;
const Request = jrpc.Request;
const ManagedResponse = Managed(jrpc.Response);

pub const Transport = struct {
    in: std.io.AnyReader,
    out: std.io.AnyWriter,
};

pub const Server = struct {
    transport: Transport,
    logger: Logger,
    allocator: std.mem.Allocator,

    _handlers: HandlerMap,

    const HandlerFn = fn (
        server: Server,
        req: Request,
        arena: *std.heap.ArenaAllocator,
    ) anyerror!ManagedResponse;
    const HandlerMap = std.StringHashMap(
        *const HandlerFn,
    );
    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        options: struct {
            logger: Logger,
            transport: Transport,
        },
    ) !Self {
        var self = Self{
            .allocator = allocator,
            .logger = options.logger,
            .transport = options.transport,
            ._handlers = HandlerMap.init(allocator),
        };
        try self._handlers.put(
            "initialize",
            &handleInitialize,
        );

        try self._handlers.put(
            "tools/list",
            &handleListTools,
        );

        try self._handlers.put(
            "tools/call",
            &handleCallTools,
        );

        return self;
    }

    pub fn deinit(self: @This()) void {
        self._handlers.deinit();
    }

    pub fn handleRequest(
        self: Self,
        req: Request,
    ) !ManagedResponse {
        const arena = try self.allocator.create(
            std.heap.ArenaAllocator,
        );
        errdefer self.allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(
            self.allocator,
        );

        if (self._handlers.get(req.method)) |val| {
            return val(self, req, arena);
        } else {
            return .{ .arena = arena, .value = .{ .err = .{
                .id = req.id,
                .jsonrpc = req.jsonrpc,
                .err = .{
                    .code = @intFromEnum(
                        jrpc.Error.Code.method_not_found,
                    ),
                    .message = "Method not found"[0..],
                    .data = .null,
                },
            } } };
        }
    }

    fn handleInitialize(
        self: @This(),
        req: Request,
        arena: *std.heap.ArenaAllocator,
    ) anyerror!ManagedResponse {
        try self.logger.info(
            "initialize called",
        );

        return .{
            .arena = arena,
            .value = .{ .result = .{
                .id = req.id,
                .jsonrpc = req.jsonrpc,
                .result = .null,
            } },
        };
    }

    fn errorNotImplemented(
        self: @This(),
        req: Request,
        arena: *std.heap.ArenaAllocator,
    ) ManagedResponse {
        _ = self;

        return .{ .arena = arena, .value = .{
            .err = .{
                .id = req.id,
                .jsonrpc = req.jsonrpc,
                .err = .{
                    .code = 1,
                    .message = "TODO implement method",
                    .data = .null,
                },
            },
        } };
    }

    fn handleCallTools(
        self: @This(),
        req: Request,
        arena: *std.heap.ArenaAllocator,
    ) anyerror!ManagedResponse {
        return self.errorNotImplemented(req, arena);
    }

    fn handleListTools(
        self: @This(),
        req: Request,
        arena: *std.heap.ArenaAllocator,
    ) anyerror!ManagedResponse {
        const arena_allocator = arena.allocator();
        try self.logger.info("listing tools");
        var resultObject = ObjectMap.init(
            arena_allocator,
        );

        var hello_world_tool = ObjectMap.init(arena_allocator);

        try hello_world_tool.put(
            "name",
            .{ .string = "hello_world" },
        );

        var tools = std.ArrayList(
            std.json.Value,
        ).init(arena_allocator);

        try tools.append(
            std.json.Value{
                .object = hello_world_tool,
            },
        );
        try resultObject.put("tools", .{
            .array = tools,
        });

        return .{
            .arena = arena,
            .value = .{
                .result = .{
                    .id = req.id,
                    .jsonrpc = req.jsonrpc,
                    .result = .{
                        .object = resultObject,
                    },
                },
            },
        };
    }
};
