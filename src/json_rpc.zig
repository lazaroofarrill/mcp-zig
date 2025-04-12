const std = @import("std");
const json = std.json;
const testing = std.testing;
const ArrayList = std.ArrayList;
const Managed = @import("managed.zig").Managed;

pub const Request = struct {
    jsonrpc: ?[]u8,
    method: []const u8,
    params: json.Value,
    id: json.Value,

    pub fn jsonStringify(
        self: @This(),
        jws: anytype,
    ) !void {
        try jws.beginObject();
        inline for (std.meta.fields(@This())) |field| {
            const val = @field(self, field.name);
            try jws.objectField(field.name);
            if (@typeInfo(field.type) == .optional) {
                if (val) |v| {
                    try jws.write(v);
                }
            } else {
                try jws.write(val);
            }
        }

        try jws.endObject();
    }

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try std.json.stringify(self, .{}, writer);
    }
};

pub const Result = struct {
    jsonrpc: ?[]u8,
    result: json.Value,

    pub const Content = struct {};
};

pub const Error = struct {
    jsonrpc: ?[]u8,
    error_value: Value,

    pub const Value = struct {
        code: i64,
        message: []const u8,
        data: std.json.Value,
    };

    pub const Code = enum(i64) {
        parse_error = -32700,
        invalid_request = -32600,
        method_not_found = -32601,
        invalid_params = -32602,
        internal_error = -32603,
    };

    pub fn jsonStringify(
        self: @This(),
        jws: anytype,
    ) !void {
        try jws.beginObject();
        const fields = std.meta.fields(Error);
        inline for (fields) |field| {
            const val = @field(self, field.name);
            if (std.mem.eql(
                u8,
                field.name,
                "error_value",
            )) {
                try jws.objectField("error");
            } else {
                try jws.objectField(field.name);
            }
            try jws.write(val);
        }
        try jws.endObject();
    }
};

pub fn serializeResponse(
    allocator: std.mem.Allocator,
    response: union(enum) { result: Result, errorValue: Error },
) ![]u8 {
    const jsonrpc_version = switch (response) {
        .result => |v| v.jsonrpc,
        .errorValue => |v| v.jsonrpc,
    };
    std.debug.assert(std.mem.eql(
        u8,
        jsonrpc_version orelse return error.InvalidJsonRpcVersion,
        "2.0",
    ));
    var list = std.ArrayList(u8).init(allocator);
    switch (response) {
        .errorValue => |v| try json.stringify(
            v,
            .{},
            list.writer(),
        ),
        .result => |v| try json.stringify(
            v,
            .{},
            list.writer(),
        ),
    }

    try list.append('\n');
    return list.toOwnedSlice();
}

pub fn deserializeRequest(
    allocator: std.mem.Allocator,
    payload: []const u8,
) !Managed([]Request) {
    const parsed_single = json.parseFromSlice(
        Request,
        allocator,
        payload,
        .{},
    ) catch |err| switch (err) {
        error.UnexpectedToken => |e| e,
        else => return err,
    };

    const parsed_requests: Managed([]Request) = blk: {
        if (parsed_single) |val| {
            const arena_allocator = val.arena.allocator();

            var slice = try arena_allocator.alloc(Request, 1);
            slice[0] = val.value;

            break :blk .{
                .value = slice,
                .arena = val.arena,
            };
        } else |err| {
            err catch {};
            const parsed = try json.parseFromSlice(
                []Request,
                allocator,
                payload,
                .{},
            );

            break :blk .{
                .value = parsed.value,
                .arena = parsed.arena,
            };
        }
    };

    for (parsed_requests.value) |req| {
        switch (req.id) {
            .null, .integer, .string => {},
            else => return error.InvalidRequestId,
        }

        switch (req.params) {
            .object, .array => {},
            else => return error.InvalidParams,
        }

        //only supporing JSON-RPC 2.0 for the time being
        std.debug.assert(std.mem.eql(u8, req.jsonrpc.?, "2.0"));
    }

    return parsed_requests;
}

const test_payloads = [_][]const u8{
    \\{"id": 2, "jsonrpc": "2.0", "params": [ "baby" ], "method": "give_me_data"}
    ,
    \\{"id": null, "jsonrpc": "2.0", "params": {}, "method": "my_my"}
};

test "deserialize request" {
    var parsed_values = ArrayList(
        Managed([]Request),
    ).init(std.testing.allocator);
    defer parsed_values.deinit();

    inline for (test_payloads) |payload| {
        const parsed = try deserializeRequest(
            std.testing.allocator,
            payload,
        );
        try parsed_values.append(parsed);
    }

    defer for (parsed_values.items) |val| {
        val.deinit();
    };
}

test "serialize response" {
    const jsonrpc_version = "2.0";
    const to_free = try std.testing.allocator.dupe(
        u8,
        jsonrpc_version,
    );
    defer std.testing.allocator.free(to_free);
    const response = Result{
        .jsonrpc = to_free,
        .result = .null,
    };

    const serialized_payload = try serializeResponse(
        std.testing.allocator,
        .{ .result = response },
    );
    defer std.testing.allocator.free(serialized_payload);

    std.debug.print("{s}", .{serialized_payload});
}

test "serialize error" {
    var error_value = json.ObjectMap.init(std.testing.allocator);
    defer error_value.deinit();

    try error_value.put(
        "type",
        .{ .string = "text" },
    );
    try error_value.put(
        "text",
        .{ .string = "No one can draw like this." },
    );

    const error_response = Error{
        .jsonrpc = try std.testing.allocator.dupe(
            u8,
            "2.0",
        ),
        .error_value = .{
            .code = 1,
            .message = "Some error I want to return.",
            .data = .null,
        },
    };
    defer if (error_response.jsonrpc) |field| {
        std.testing.allocator.free(field);
    };

    const serialized_payload = try serializeResponse(
        std.testing.allocator,
        .{ .errorValue = error_response },
    );
    defer std.testing.allocator.free(serialized_payload);

    std.debug.print("{s}", .{serialized_payload});
}

test "batch_deserialize" {
    const message =
        \\[{"id": 2, "jsonrpc": "2.0", "params": [ "baby" ], "method": "give_me_data"}]
    ;

    const parsed = try deserializeRequest(std.testing.allocator, message);
    defer parsed.deinit();
}
