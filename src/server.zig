const std = @import("std");
const ObjectMap = std.json.ObjectMap;
const ArrayList = std.ArrayList;
const Transport = @import("transport.zig");

const jrpc = @import("json_rpc.zig");
const Request = jrpc.Request;
const Response = jrpc.Response;
const Managed = @import("managed.zig").Managed;

const ManagedResponse = Managed(jrpc.Response);

const Tool = struct {
    name: []const u8,
    description: []const u8,
    handle: ToolHandle,
    input_schema: ?[]const u8,
    ctx: *anyopaque,
};

const ToolHandle = *const fn (
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    std.json.Value,
) anyerror!Response;

pub const Server = struct {
    transport: Transport,
    allocator: std.mem.Allocator,
    _tools: std.ArrayList(Tool),
    _handlers: HandlerMap,

    const HandlerFn = fn (
        server: *Server,
        req: Request,
        arena: *std.heap.ArenaAllocator,
    ) anyerror!?ManagedResponse;
    const HandlerMap = std.StringHashMap(
        *const HandlerFn,
    );
    const Self = @This();

    pub fn defineTool(
        server: *Self,
        comptime C: type,
        ctx: *C,
        comptime Params: type,
        name: []const u8,
        description: []const u8,
        input_schema: ?[]const u8,
        comptime handler: fn (
            ctx: *C,
            std.mem.Allocator,
            Params,
        ) anyerror!Response,
    ) !void {
        const tool = Tool{
            .name = name,
            .description = description,
            .input_schema = input_schema,
            .ctx = ctx,
            .handle = struct {
                fn call(
                    callback_ctx: *anyopaque,
                    allocator: std.mem.Allocator,
                    input: std.json.Value,
                ) anyerror!Response {
                    const params = try std.json.parseFromValue(
                        Params,
                        allocator,
                        input,
                        .{ .ignore_unknown_fields = true },
                    );
                    return handler(
                        @ptrCast(@alignCast(callback_ctx)),
                        allocator,
                        params.value,
                    );
                }
            }.call,
        };

        try server._tools.append(tool);
    }

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

        try self._handlers.put(
            "notifications",
            &handleNotification,
        );

        return self;
    }

    pub fn deinit(self: *Self) void {
        self._tools.deinit();
        self._handlers.deinit();
    }

    // Start server blocking the current thread.
    pub fn start(self: *Self) anyerror!void {
        const request_buffer = try self.allocator.alloc(
            u8,
            4 * 1024 * 1024,
        );
        defer self.allocator.free(request_buffer);

        // TODO fix this memory leak
        var requests = std.ArrayList(
            Managed([]Request),
        ).init(self.allocator);
        defer requests.deinit();
        defer for (requests.items) |r| {
            r.deinit();
        };

        var threads = std.ArrayList(std.Thread).init(
            self.allocator,
        );
        defer threads.deinit();
        defer for (threads.items) |t| {
            t.join();
        };

        var run = true;
        while (run) {
            var fbs = std.io.fixedBufferStream(request_buffer);
            self.transport.in.streamUntilDelimiter(
                fbs.writer(),
                '\n',
                fbs.buffer.len,
            ) catch |err| switch (err) {
                error.EndOfStream => {
                    run = false;
                },
                error.StreamTooLong => {
                    continue;
                },
                else => return err,
            };

            const raw_message = fbs.getWritten();

            const message = std.mem.trimRight(u8, raw_message, "\r");

            if (message.len > 0) {
                const new_batch = jrpc.deserializeRequests(
                    self.allocator,
                    message,
                ) catch |err| {
                    err catch {};
                    continue;
                };
                try requests.append(new_batch);
                // defer new_batch.deinit();
                if (new_batch.value.len == 0) continue;

                for (new_batch.value, 0..) |req, idx| {
                    const thread = try std.Thread.spawn(
                        .{},
                        processRequestInThread,
                        .{ self, req },
                    );
                    // thread.detach();
                    // thread.join();
                    try threads.append(thread);
                    // _ = thread;
                    _ = idx;
                }
            }
        }
    }

    pub fn handleRequest(
        self: *Self,
        req: Request,
    ) !?ManagedResponse {
        const arena = try self.allocator.create(
            std.heap.ArenaAllocator,
        );
        errdefer {
            arena.deinit();
            self.allocator.destroy(arena);
        }

        arena.* = std.heap.ArenaAllocator.init(
            self.allocator,
        );

        const key = if (std.mem.startsWith(u8, req.method, "notifications/")) "notifications"[0..] else req.method;

        if (self._handlers.get(key)) |handle| {
            var res = try handle(self, req, arena);
            if (res) |r| switch (r.value) {
                .result => {
                    res.?.value.result.id = req.id;
                },
                .err => {
                    res.?.value.err.id = req.id;
                },
            };

            return res;
        } else {
            return .{ .arena = arena, .value = .{ .err = .{
                .id = req.id,
                .jsonrpc = req.jsonrpc,
                .err = .{
                    .code = @intFromEnum(
                        jrpc.ErrorResult.Code.method_not_found,
                    ),
                    .message = "Method not found"[0..],
                    .data = .null,
                },
            } } };
        }
    }

    fn handleNotification(
        self: *Server,
        req: Request,
        arena: *std.heap.ArenaAllocator,
    ) anyerror!?ManagedResponse {
        var it = std.mem.splitSequence(u8, req.method, "/");
        _ = it.next();

        const notification_name = if (it.index) |idx| req.method[idx..] else return null;

        _ = self;
        _ = arena;
        _ = notification_name;
        return null;
    }

    fn handleInitialize(
        self: *Server,
        req: Request,
        arena: *std.heap.ArenaAllocator,
    ) anyerror!?ManagedResponse {
        var initialize_result = std.json.ObjectMap.init(arena.allocator());
        try initialize_result.put(
            "protocolVersion",
            .{ .string = "2024-11-05" },
        );

        var server_info = std.json.ObjectMap.init(arena.allocator());
        try server_info.put("name", .{ .string = "mcp-server-written-in-zig" });
        try server_info.put("version", .{ .string = "0.0.1" });

        try initialize_result.put("serverInfo", .{ .object = server_info });

        var capabilities = std.json.ObjectMap.init(arena.allocator());

        if (self._tools.items.len > 0) {
            const tools = std.json.ObjectMap.init(arena.allocator());
            try capabilities.put("tools", .{ .object = tools });
        }

        //TODO resources

        //TODO prompts

        //TODO completions

        //TODO logging

        //TODO experimental

        try initialize_result.put(
            "capabilities",
            .{ .object = capabilities },
        );

        return .{
            .arena = arena,
            .value = .{ .result = .{
                .id = req.id,
                .jsonrpc = req.jsonrpc,
                .result = .{
                    .object = initialize_result,
                },
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
        self: *Server,
        req: Request,
        arena: *std.heap.ArenaAllocator,
    ) anyerror!?ManagedResponse {
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
                if (tool.handle(tool.ctx, arena.allocator(), input)) |val| {
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
                    std.debug.print("{s}\n", .{@errorName(err)});
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
        self: *Server,
        req: Request,
        arena: *std.heap.ArenaAllocator,
    ) anyerror!?ManagedResponse {
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

pub fn processRequestInThread(
    self: *Server,
    req: Request,
) anyerror!void {
    const resp = self.handleRequest(
        req,
    ) catch |err| {
        return err;
    };
    if (resp == null) return;
    defer if (resp) |r| {
        r.deinit();
    };

    try jrpc.serializeResponse(
        resp.?.value,
        self.transport.writer().any(),
    );
}
