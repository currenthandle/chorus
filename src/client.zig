//! Client helpers for talking to the chorus daemon over its Unix socket.

const std = @import("std");

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,

    pub fn connect(allocator: std.mem.Allocator, io: std.Io, socket_path: []const u8) !Client {
        const addr = try std.Io.net.UnixAddress.init(socket_path);
        const stream = try addr.connect(io);
        return .{ .allocator = allocator, .io = io, .stream = stream };
    }

    pub fn deinit(self: *Client) void {
        self.stream.close(self.io);
    }

    /// Send a single JSON object followed by a newline and read one JSON line back.
    /// The returned slice is owned by the caller.
    pub fn roundtrip(self: *Client, request_json: []const u8) ![]u8 {
        var write_buf: [4096]u8 = undefined;
        var writer_state = self.stream.writer(self.io, &write_buf);
        const writer = &writer_state.interface;
        try writer.writeAll(request_json);
        if (request_json.len == 0 or request_json[request_json.len - 1] != '\n') {
            try writer.writeAll("\n");
        }
        try writer.flush();

        var read_buf: [8192]u8 = undefined;
        var reader_state = self.stream.reader(self.io, &read_buf);
        const reader = &reader_state.interface;
        const line = try reader.takeDelimiterInclusive('\n');
        return self.allocator.dupe(u8, std.mem.trim(u8, line, " \t\r\n"));
    }
};

/// Compute the default socket path, mirroring the daemon's logic.
pub fn defaultSocketPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("CHORUS_SOCKET")) |raw| {
        return allocator.dupe(u8, std.mem.span(raw));
    }
    if (std.c.getenv("XDG_RUNTIME_DIR")) |raw| {
        const dir = std.mem.span(raw);
        return std.fmt.allocPrint(allocator, "{s}/chorus.sock", .{dir});
    }
    const user = if (std.c.getenv("USER")) |u| std.mem.span(u) else "user";
    return std.fmt.allocPrint(allocator, "/tmp/chorus-{s}.sock", .{user});
}

/// Resolve the agent identity for the current process. Prefers $TMUX_PANE
/// (a stable tmux pane ID); falls back to pid.
pub fn resolveAgentId(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("TMUX_PANE")) |raw| {
        return allocator.dupe(u8, std.mem.span(raw));
    }
    const pid = std.c.getpid();
    return std.fmt.allocPrint(allocator, "pid{d}", .{pid});
}
