//! Remote playback sink. Listens on a Unix socket and plays every audio
//! blob pushed to it by a remote chorus daemon.
//!
//! Use case: you are SSH'd into a dev box and want Claude's voice to come
//! out of your laptop's speakers instead of the remote's. Set up an SSH
//! remote forward from the remote's CHORUS_PLAYER_SOCKET to a local socket
//! where `chorus player` is listening:
//!
//!   (local)  chorus player /tmp/chorus-player.sock
//!   (remote) ssh -R /tmp/chorus-player.sock:/tmp/chorus-player.sock me@dev
//!   (remote) CHORUS_PLAYER_SOCKET=/tmp/chorus-player.sock chorus daemon
//!
//! Wire protocol. One frame per blob:
//!
//!   magic  : 4  bytes  = "CHRS"
//!   format : 1  byte   = AudioFormat enum value (1 = mp3)
//!   reserved: 3 bytes  = 0
//!   length : 8  bytes  = little-endian u64 payload length
//!   payload: <length> bytes of encoded audio
//!
//! Everything we synthesize today is MP3, so the format byte is mostly
//! future-proofing for WAV/FLAC/OGG later. The magic catches misaligned
//! streams early so we don't try to decode garbage.

const std = @import("std");
const audio = @import("audio.zig");

pub const magic = "CHRS";

pub const FrameHeader = extern struct {
    magic: [4]u8,
    format: u8,
    reserved: [3]u8 = .{ 0, 0, 0 },
    length: u64 align(1),
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, socket_path: []const u8) !void {
    unlinkIfExists(socket_path);

    const addr = try std.Io.net.UnixAddress.init(socket_path);
    var server = try addr.listen(io, .{});
    defer server.socket.close(io);

    std.debug.print("chorus-player: listening on {s}\n", .{socket_path});

    while (true) {
        var client = server.accept(io) catch |err| {
            std.debug.print("chorus-player: accept error: {s}\n", .{@errorName(err)});
            continue;
        };
        const th = std.Thread.spawn(.{}, handleClient, .{ allocator, io, client }) catch |err| {
            std.debug.print("chorus-player: spawn error: {s}\n", .{@errorName(err)});
            client.close(io);
            continue;
        };
        th.detach();
    }
}

fn handleClient(allocator: std.mem.Allocator, io: std.Io, client: std.Io.net.Stream) void {
    var stream = client;
    defer stream.close(io);

    var read_buf: [8192]u8 = undefined;
    var reader_state = stream.reader(io, &read_buf);
    const reader = &reader_state.interface;

    while (true) {
        var header_bytes: [@sizeOf(FrameHeader)]u8 = undefined;
        reader.readSliceAll(&header_bytes) catch |err| switch (err) {
            error.EndOfStream, error.ReadFailed => return,
            else => {
                std.debug.print("chorus-player: header read error: {s}\n", .{@errorName(err)});
                return;
            },
        };
        const header: FrameHeader = @bitCast(header_bytes);

        if (!std.mem.eql(u8, &header.magic, magic)) {
            std.debug.print("chorus-player: bad magic, dropping client\n", .{});
            return;
        }

        const payload = allocator.alloc(u8, header.length) catch {
            std.debug.print("chorus-player: oom\n", .{});
            return;
        };
        defer allocator.free(payload);

        reader.readSliceAll(payload) catch |err| {
            std.debug.print("chorus-player: payload read error: {s}\n", .{@errorName(err)});
            return;
        };

        audio.playBytes(payload, 1.0, null) catch |err| {
            std.debug.print("chorus-player: playback error: {s}\n", .{@errorName(err)});
            continue;
        };
    }
}

/// Connect to a remote player and push one audio blob. Best-effort: the
/// daemon falls back to local playback on any failure.
pub fn push(
    allocator: std.mem.Allocator,
    io: std.Io,
    socket_path: []const u8,
    format: audio_format_value,
    payload: []const u8,
) !void {
    _ = allocator;
    const addr = try std.Io.net.UnixAddress.init(socket_path);
    var stream = try addr.connect(io);
    defer stream.close(io);

    var write_buf: [16 * 1024]u8 = undefined;
    var writer_state = stream.writer(io, &write_buf);
    const writer = &writer_state.interface;

    var header: FrameHeader = .{
        .magic = magic.*,
        .format = @intFromEnum(format),
        .reserved = .{ 0, 0, 0 },
        .length = payload.len,
    };
    const header_bytes: [@sizeOf(FrameHeader)]u8 = @bitCast(header);
    try writer.writeAll(&header_bytes);
    try writer.writeAll(payload);
    try writer.flush();
}

pub const audio_format_value = enum(u8) {
    mp3 = 1,
    wav = 2,
    flac = 3,
    ogg = 4,
    aac = 5,
};

fn unlinkIfExists(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return;
    _ = std.c.unlink(z.ptr);
}
