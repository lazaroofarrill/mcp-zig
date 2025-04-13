const std = @import("std");
const jrpc = @import("../json_rpc.zig");
const Managed = @import("../managed.zig").Managed;

const ObjectMap = std.json.ObjectMap;
const ArrayList = std.ArrayList;
const Request = jrpc.Request;
const Response = jrpc.Response;
const ManagedResponse = Managed(jrpc.Response);

pub const Transport = struct {
    in: std.io.AnyReader,
    out: std.io.AnyWriter,
};

const Tool = struct {
    name: []const u8,
    description: []const u8,
    handle: ToolHandle,
    input_schema: ?[]const u8,
};

const ToolHandle = *const fn (
    allocator: std.mem.Allocator,
    std.json.Value,
) anyerror!Response;

pub fn defineTool(
    comptime Params: type,
    name: []const u8,
    description: []const u8,
    input_schema: ?[]const u8,
    comptime handler: fn (
        std.mem.Allocator,
        Params,
    ) anyerror!Response,
) Tool {
    return Tool{
        .name = name,
        .description = description,
        .input_schema = input_schema,
        .handle = struct {
            fn call(
                allocator: std.mem.Allocator,
                input: std.json.Value,
            ) anyerror!Response {
                const params = try std.json.parseFromValue(
                    Params,
                    allocator,
                    input,
                    .{ .ignore_unknown_fields = true },
                );
                return handler(allocator, params.value);
            }
        }.call,
    };
}

pub const Server = struct {
    transport: Transport,
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
        transport: Transport,
    ) !Self {
        var self = Self{
            .allocator = allocator,
            .transport = transport,
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

        if (self._handlers.get(req.method)) |handle| {
            var res = try handle(self, req, arena);
            switch (res.value) {
                .result => {
                    res.value.result.id = req.id;
                },
                .err => {
                    res.value.err.id = req.id;
                },
            }
            return res;
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
        _ = self;

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

        for (self._tools.items) |tool| {
            if (std.mem.eql(
                u8,
                tool.name,
                tool_name.string,
            )) {
                const tool_args = req.params.object.get("arguments");
                const input = if (tool_args) |val| val else .null;
                if (tool.handle(arena.allocator(), input)) |val| {
                    return .{
                        .arena = arena,
                        .value = switch (val) {
                            .result => |r| .{ .result = .{
                                .id = req.id,
                                .jsonrpc = r.jsonrpc,
                                .result = r.result,
                            } },
                            .err => |e| .{ .err = .{
                                .id = req.id,
                                .jsonrpc = e.jsonrpc,
                                .err = e.err,
                            } },
                        },
                    };
                } else |err| {
                    std.debug.print("{s}\n", .{
                        @errorName(err),
                    });
                    err catch {};
                    return self.errorInvalidParams(
                        req,
                        arena,
                    );
                }
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

            if (tool.input_schema) |schema_string| {
                const parsed = std.json.parseFromSlice(
                    std.json.Value,
                    arena_allocator,
                    schema_string,
                    .{},
                ) catch |err| blk: {
                    err catch {};
                    break :blk null;
                };
                if (parsed) |p| {
                    try input_schema.put("properties", p.value);
                }
            }

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
