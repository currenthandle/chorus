const std = @import("std");
const audio = @import("audio.zig");
const provider = @import("provider.zig");
const OpenAI = @import("providers/openai.zig").OpenAI;
const Azure = @import("providers/azure.zig").Azure;
const daemon = @import("daemon.zig");
const client_mod = @import("client.zig");

const usage =
    \\usage:
    \\  chorus play <audio-file>            Play a file directly.
    \\  chorus speak <text> [voice]         Synthesize and play (direct, no daemon).
    \\  chorus daemon                       Run the broker daemon.
    \\  chorus say <text> [voice]           Send a speak job to the running daemon.
    \\  chorus status                       Query daemon stats.
    \\
    \\Provider selected by CHORUS_PROVIDER (openai|azure), default openai.
    \\Daemon socket path overridable via CHORUS_SOCKET.
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        std.debug.print("{s}", .{usage});
        return error.MissingArgument;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "play")) {
        if (args.len < 3) return printUsage();
        try audio.playFile(args[2]);
        return;
    }
    if (std.mem.eql(u8, cmd, "speak")) {
        if (args.len < 3) return printUsage();
        const voice = if (args.len >= 4) args[3] else "alloy";
        try directSpeak(arena, init.io, args[2], voice);
        return;
    }
    if (std.mem.eql(u8, cmd, "daemon")) {
        try daemon.Daemon.run(init.gpa, init.io);
        return;
    }
    if (std.mem.eql(u8, cmd, "say")) {
        if (args.len < 3) return printUsage();
        const voice = if (args.len >= 4) args[3] else "alloy";
        try clientSay(arena, init.io, args[2], voice);
        return;
    }
    if (std.mem.eql(u8, cmd, "status")) {
        try clientStatus(arena, init.io);
        return;
    }

    return printUsage();
}

fn printUsage() !void {
    std.debug.print("{s}", .{usage});
    return error.UnknownCommand;
}

fn directSpeak(
    allocator: std.mem.Allocator,
    io: std.Io,
    text: []const u8,
    voice: []const u8,
) !void {
    switch (detectProvider()) {
        .openai => {
            var oa = try OpenAI.initFromEnv(allocator);
            defer oa.deinit();
            try runSynth(allocator, io, oa.provider_handle(), text, voice);
        },
        .azure => {
            var az = try Azure.initFromEnv(allocator);
            defer az.deinit();
            try runSynth(allocator, io, az.provider_handle(), text, voice);
        },
    }
}

fn runSynth(
    allocator: std.mem.Allocator,
    io: std.Io,
    p: provider.Provider,
    text: []const u8,
    voice: []const u8,
) !void {
    std.debug.print("chorus: synthesizing via {s} (voice={s})…\n", .{ p.name(), voice });
    var result = try p.synthesize(allocator, io, .{
        .text = text,
        .voice_id = voice,
        .speed = 1.0,
    });
    defer result.deinit(allocator);
    std.debug.print("chorus: playing {d} bytes ({s})\n", .{ result.bytes.len, @tagName(result.format) });
    try audio.playBytes(result.bytes);
    std.debug.print("chorus: done\n", .{});
}

fn clientSay(
    allocator: std.mem.Allocator,
    io: std.Io,
    text: []const u8,
    voice: []const u8,
) !void {
    const sock = try client_mod.defaultSocketPath(allocator);
    const agent_id = try client_mod.resolveAgentId(allocator);

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try std.json.Stringify.value(.{
        .op = "speak",
        .agent_id = agent_id,
        .text = text,
        .voice = voice,
    }, .{}, &buf.writer);

    var c = try client_mod.Client.connect(allocator, io, sock);
    defer c.deinit();
    const reply = try c.roundtrip(buf.written());
    defer allocator.free(reply);
    std.debug.print("{s}\n", .{reply});
}

fn clientStatus(allocator: std.mem.Allocator, io: std.Io) !void {
    const sock = try client_mod.defaultSocketPath(allocator);
    var c = try client_mod.Client.connect(allocator, io, sock);
    defer c.deinit();
    const reply = try c.roundtrip("{\"op\":\"status\"}");
    defer allocator.free(reply);
    std.debug.print("{s}\n", .{reply});
}

const ProviderKind = enum { openai, azure };

fn detectProvider() ProviderKind {
    const raw = std.c.getenv("CHORUS_PROVIDER") orelse return .openai;
    const name = std.mem.span(raw);
    if (std.mem.eql(u8, name, "azure")) return .azure;
    return .openai;
}
