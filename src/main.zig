const std = @import("std");
const audio = @import("audio.zig");
const provider = @import("provider.zig");
const OpenAI = @import("providers/openai.zig").OpenAI;
const Azure = @import("providers/azure.zig").Azure;
const daemon = @import("daemon.zig");
const client_mod = @import("client.zig");
const mcp_shim = @import("mcp_shim.zig");

const usage =
    \\usage:
    \\  chorus play <audio-file>            Play a file directly.
    \\  chorus speak <text> [voice]         Synthesize and play (direct, no daemon).
    \\  chorus daemon                       Run the broker daemon.
    \\  chorus say <text> [voice]           Send a speak job to the running daemon.
    \\  chorus status                       Query daemon stats.
    \\  chorus list                         Show every registered agent.
    \\  chorus pause <agent>                Pause an agent (queued jobs wait).
    \\  chorus resume <agent>               Resume a paused agent.
    \\  chorus mute <agent>                 Drop audio for an agent (jobs still drain).
    \\  chorus unmute <agent>               Re-enable audio for an agent.
    \\  chorus skip <agent>                 Drop this agent's queued jobs + cancel current.
    \\  chorus voice <agent> <voice>        Set an agent's default voice.
    \\  chorus volume <agent> <f>           Set an agent's volume multiplier.
    \\  chorus mcp                          Run as an MCP stdio server for Claude Code.
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
        try sendSimple(arena, init.io, "{\"op\":\"status\"}");
        return;
    }
    if (std.mem.eql(u8, cmd, "list")) {
        try sendSimple(arena, init.io, "{\"op\":\"list\"}");
        return;
    }
    if (std.mem.eql(u8, cmd, "pause")) return sendAgentOp(arena, init.io, "pause", args);
    if (std.mem.eql(u8, cmd, "resume")) return sendAgentOp(arena, init.io, "resume", args);
    if (std.mem.eql(u8, cmd, "mute")) return sendAgentOp(arena, init.io, "mute", args);
    if (std.mem.eql(u8, cmd, "unmute")) return sendAgentOp(arena, init.io, "unmute", args);
    if (std.mem.eql(u8, cmd, "skip")) return sendAgentOp(arena, init.io, "skip", args);
    if (std.mem.eql(u8, cmd, "voice")) return sendVoiceOp(arena, init.io, args);
    if (std.mem.eql(u8, cmd, "volume")) return sendVolumeOp(arena, init.io, args);

    if (std.mem.eql(u8, cmd, "mcp")) {
        try mcp_shim.run(init.gpa, init.io);
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
    try audio.playBytes(result.bytes, 1.0, null);
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

fn sendSimple(allocator: std.mem.Allocator, io: std.Io, request_json: []const u8) !void {
    const sock = try client_mod.defaultSocketPath(allocator);
    var c = try client_mod.Client.connect(allocator, io, sock);
    defer c.deinit();
    const reply = try c.roundtrip(request_json);
    defer allocator.free(reply);
    std.debug.print("{s}\n", .{reply});
}

fn sendAgentOp(
    allocator: std.mem.Allocator,
    io: std.Io,
    op: []const u8,
    args: []const [:0]const u8,
) !void {
    if (args.len < 3) return printUsage();
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try std.json.Stringify.value(
        .{ .op = op, .agent_id = args[2] },
        .{},
        &buf.writer,
    );
    try sendSimple(allocator, io, buf.written());
}

fn sendVoiceOp(allocator: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) !void {
    if (args.len < 4) return printUsage();
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try std.json.Stringify.value(
        .{ .op = "set_voice", .agent_id = args[2], .voice = args[3] },
        .{},
        &buf.writer,
    );
    try sendSimple(allocator, io, buf.written());
}

fn sendVolumeOp(allocator: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) !void {
    if (args.len < 4) return printUsage();
    const volume = try std.fmt.parseFloat(f32, args[3]);
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try std.json.Stringify.value(
        .{ .op = "set_volume", .agent_id = args[2], .volume = volume },
        .{},
        &buf.writer,
    );
    try sendSimple(allocator, io, buf.written());
}

const ProviderKind = enum { openai, azure };

fn detectProvider() ProviderKind {
    const raw = std.c.getenv("CHORUS_PROVIDER") orelse return .openai;
    const name = std.mem.span(raw);
    if (std.mem.eql(u8, name, "azure")) return .azure;
    return .openai;
}
