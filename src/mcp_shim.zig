//! Thin MCP shim that forwards `speak` and `tts_status` tool calls to the
//! chorus daemon over its Unix socket.
//!
//! Speaks JSON-RPC 2.0 on stdio as required by the MCP stdio transport.
//! Supports the minimum set of methods Claude Code actually calls:
//!
//!   initialize                  — advertise server info and capabilities.
//!   notifications/initialized   — acknowledged silently.
//!   tools/list                  — return the `speak` and `tts_status` tools.
//!   tools/call                  — forward to the daemon and relay the reply.
//!
//! Any other method returns -32601 "Method not found".

const std = @import("std");
const client_mod = @import("client.zig");

const server_name = "chorus";
const server_version = "0.1.0";
const protocol_version = "2024-11-05";

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    var stdin_buf: [16 * 1024]u8 = undefined;
    var stdin_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buf);
    const reader = &stdin_reader.interface;

    var stdout_buf: [16 * 1024]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const writer = &stdout_writer.interface;

    while (true) {
        const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream, error.ReadFailed => return,
            else => return err,
        };
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        handleLine(allocator, io, trimmed, writer) catch |err| {
            std.debug.print("chorus-mcp: handler error: {s}\n", .{@errorName(err)});
        };
        writer.flush() catch return;
    }
}

fn handleLine(
    allocator: std.mem.Allocator,
    io: std.Io,
    line: []const u8,
    writer: *std.Io.Writer,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| {
        try writeError(writer, null, -32700, @errorName(err));
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        try writeError(writer, null, -32600, "expected object");
        return;
    }

    const id_opt = root.object.get("id");
    const method_v = root.object.get("method") orelse {
        try writeError(writer, id_opt, -32600, "missing method");
        return;
    };
    if (method_v != .string) {
        try writeError(writer, id_opt, -32600, "method must be string");
        return;
    }
    const method = method_v.string;
    const params = root.object.get("params");

    if (std.mem.eql(u8, method, "initialize")) {
        try writeInitialize(writer, id_opt);
    } else if (std.mem.startsWith(u8, method, "notifications/")) {
        // Notifications have no id and expect no response.
    } else if (std.mem.eql(u8, method, "tools/list")) {
        try writeToolsList(writer, id_opt);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        try handleToolsCall(allocator, io, id_opt, params, writer);
    } else if (id_opt != null) {
        try writeError(writer, id_opt, -32601, "method not found");
    }
}

fn writeInitialize(writer: *std.Io.Writer, id: ?std.json.Value) !void {
    const EmptyObject = struct {};
    try writeResult(writer, id, .{
        .protocolVersion = protocol_version,
        .capabilities = .{ .tools = EmptyObject{} },
        .serverInfo = .{ .name = server_name, .version = server_version },
    });
}

fn writeToolsList(writer: *std.Io.Writer, id: ?std.json.Value) !void {
    const speak_schema = .{
        .type = "object",
        .properties = .{
            .text = .{ .type = "string", .description = "Text to convert to speech." },
            .voice = .{ .type = "string", .description = "Voice id (provider-specific; defaults to alloy)." },
            .speed = .{ .type = "number", .description = "Speed multiplier 0.25–4.0 (default 1.0)." },
        },
        .required = [_][]const u8{"text"},
    };
    const EmptyObject = struct {};
    const status_schema = .{ .type = "object", .properties = EmptyObject{} };

    try writeResult(writer, id, .{
        .tools = .{
            .{
                .name = "speak",
                .description = "Queue text for the chorus broker to speak aloud.",
                .inputSchema = speak_schema,
            },
            .{
                .name = "tts_status",
                .description = "Return current chorus broker queue stats.",
                .inputSchema = status_schema,
            },
        },
    });
}

fn handleToolsCall(
    allocator: std.mem.Allocator,
    io: std.Io,
    id: ?std.json.Value,
    params: ?std.json.Value,
    writer: *std.Io.Writer,
) !void {
    const p = params orelse return writeError(writer, id, -32602, "missing params");
    if (p != .object) return writeError(writer, id, -32602, "params must be object");

    const name_v = p.object.get("name") orelse return writeError(writer, id, -32602, "missing tool name");
    if (name_v != .string) return writeError(writer, id, -32602, "tool name must be string");
    const name = name_v.string;
    const args = p.object.get("arguments");

    if (std.mem.eql(u8, name, "speak")) {
        try forwardSpeak(allocator, io, id, args, writer);
    } else if (std.mem.eql(u8, name, "tts_status")) {
        try forwardStatus(allocator, io, id, writer);
    } else {
        try writeError(writer, id, -32602, "unknown tool");
    }
}

fn forwardSpeak(
    allocator: std.mem.Allocator,
    io: std.Io,
    id: ?std.json.Value,
    args: ?std.json.Value,
    writer: *std.Io.Writer,
) !void {
    const a = args orelse return writeError(writer, id, -32602, "missing arguments");
    if (a != .object) return writeError(writer, id, -32602, "arguments must be object");

    const text_v = a.object.get("text") orelse return writeError(writer, id, -32602, "missing text");
    if (text_v != .string) return writeError(writer, id, -32602, "text must be string");

    const voice = if (a.object.get("voice")) |v| switch (v) {
        .string => |s| s,
        else => "alloy",
    } else "alloy";

    const speed = if (a.object.get("speed")) |v| switch (v) {
        .float => |f| @as(f32, @floatCast(f)),
        .integer => |i| @as(f32, @floatFromInt(i)),
        else => @as(f32, 1.0),
    } else @as(f32, 1.0);

    const agent_id = try client_mod.resolveAgentId(allocator);
    defer allocator.free(agent_id);

    const sock = try client_mod.defaultSocketPath(allocator);
    defer allocator.free(sock);

    var req_buf: std.Io.Writer.Allocating = .init(allocator);
    defer req_buf.deinit();
    try std.json.Stringify.value(.{
        .op = "speak",
        .agent_id = agent_id,
        .text = text_v.string,
        .voice = voice,
        .speed = speed,
    }, .{}, &req_buf.writer);

    var c = client_mod.Client.connect(allocator, io, sock) catch |err| {
        return writeError(writer, id, -32000, @errorName(err));
    };
    defer c.deinit();

    const reply = c.roundtrip(req_buf.written()) catch |err| {
        return writeError(writer, id, -32000, @errorName(err));
    };
    defer allocator.free(reply);

    try writeToolResult(writer, id, reply);
}

fn forwardStatus(
    allocator: std.mem.Allocator,
    io: std.Io,
    id: ?std.json.Value,
    writer: *std.Io.Writer,
) !void {
    const sock = try client_mod.defaultSocketPath(allocator);
    defer allocator.free(sock);

    var c = client_mod.Client.connect(allocator, io, sock) catch |err| {
        return writeError(writer, id, -32000, @errorName(err));
    };
    defer c.deinit();

    const reply = c.roundtrip("{\"op\":\"status\"}") catch |err| {
        return writeError(writer, id, -32000, @errorName(err));
    };
    defer allocator.free(reply);

    try writeToolResult(writer, id, reply);
}

fn writeToolResult(writer: *std.Io.Writer, id: ?std.json.Value, text: []const u8) !void {
    try writeResult(writer, id, .{
        .content = .{
            .{ .type = "text", .text = text },
        },
        .isError = false,
    });
}

fn writeResult(writer: *std.Io.Writer, id: ?std.json.Value, result: anytype) !void {
    try std.json.Stringify.value(.{
        .jsonrpc = "2.0",
        .id = IdRef{ .v = id },
        .result = result,
    }, .{}, writer);
    try writer.writeAll("\n");
}

fn writeError(
    writer: *std.Io.Writer,
    id: ?std.json.Value,
    code: i32,
    message: []const u8,
) !void {
    try std.json.Stringify.value(.{
        .jsonrpc = "2.0",
        .id = IdRef{ .v = id },
        .@"error" = .{ .code = code, .message = message },
    }, .{}, writer);
    try writer.writeAll("\n");
}

/// Serialize a possibly-null JSON value reference inline. Lets us pass the
/// client's original id (number or string) through unchanged, or emit `null`
/// when the request lacked one.
const IdRef = struct {
    v: ?std.json.Value,

    pub fn jsonStringify(self: IdRef, jw: anytype) !void {
        if (self.v) |value| {
            try value.jsonStringify(jw);
        } else {
            try jw.write(null);
        }
    }
};
