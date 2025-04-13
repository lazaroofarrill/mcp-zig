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

const Tool = struct {
    name: []const u8,
    description: []const u8,
    handle: ToolHandle,
};

const ToolHandle = *const fn (
    *std.heap.ArenaAllocator,
    std.json.Value,
) anyerror!ManagedResponse;

pub fn defineTool(
    comptime Params: type,
    name: []const u8,
    description: []const u8,
    comptime handler: fn (
        *std.heap.ArenaAllocator,
        Params,
    ) anyerror!ManagedResponse,
) Tool {
    return Tool{
        .name = name,
        .description = description,
        .handle = struct {
            fn call(
                arena: *std.heap.ArenaAllocator,
                input: std.json.Value,
            ) anyerror!ManagedResponse {
                const params = try std.json.parseFromValue(
                    Params,
                    arena.allocator(),
                    input,
                    .{},
                );
                return handler(arena, params.value);
            }
        }.call,
    };
}

pub const Server = struct {
    transport: Transport,
    logger: Logger,
    allocator: std.mem.Allocator,
    _tools: std.ArrayList(Tool),

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
            ._tools = std.ArrayList(Tool).init(allocator),
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
        self._tools.deinit();
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

    fn errorInvalidParams(
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
                    .code = -32602,
                    .message = "Invalid params.",
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
        const tool_name =
            req.params.object.get("name") orelse {
                return self.errorInvalidParams(req, arena);
            };
        switch (tool_name) {
            .string => {},
            else => return self.errorInvalidParams(
                req,
                arena,
            ),
        }

        try self.logger.info(tool_name.string);

        for (self._tools.items) |tool| {
            if (std.mem.eql(
                u8,
                tool.name,
                tool_name.string,
            )) {
                const params = req.params.object.get("params");
                const input = if (params) |val| val else .null;
                return tool.handle(arena, input) catch |err| {
                    err catch {};
                    return self.errorInvalidParams(
                        req,
                        arena,
                    );
                };
            }
        }

        return self.errorNotImplemented(req, arena);
    }

    fn handleListTools(
        self: @This(),
        req: Request,
        arena: *std.heap.ArenaAllocator,
    ) anyerror!ManagedResponse {
        const arena_allocator = arena.allocator();
        try self.logger.info("listing tools");

        var tools = std.ArrayList(
            std.json.Value,
        ).init(arena_allocator);

        var resultObject = ObjectMap.init(
            arena_allocator,
        );

        for (self._tools.items) |tool| {
            var curr_tool = ObjectMap.init(arena_allocator);

            try curr_tool.put(
                "name",
                .{ .string = tool.name },
            );
            try curr_tool.put(
                "description",
                .{ .string = tool.description },
            );

            var input_schema = ObjectMap.init(
                arena_allocator,
            );

            try input_schema.put(
                "type",
                .{ .string = "object" },
            );

            try curr_tool.put(
                "inputSchema",
                .{ .object = input_schema },
            );

            try tools.append(
                std.json.Value{
                    .object = curr_tool,
                },
            );
        }

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
