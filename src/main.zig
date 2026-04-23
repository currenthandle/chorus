const std = @import("std");
const audio = @import("audio.zig");
const provider = @import("provider.zig");
const OpenAI = @import("providers/openai.zig").OpenAI;
const Azure = @import("providers/azure.zig").Azure;
const ElevenLabs = @import("providers/elevenlabs.zig").ElevenLabs;
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
    \\  chorus auto on|off [agent]          Toggle auto-speak globally or for one agent.
    \\  chorus indicators                   Show which agents have queued audio waiting.
    \\  chorus next [agent]                 Play the next job (optionally from a specific agent).
    \\  chorus tmux-status                  One-line summary for tmux status-right.
    \\  chorus tmux-pane [pane_id]          Badge for $TMUX_PANE (or given id).
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
    if (std.mem.eql(u8, cmd, "auto")) return sendAutoOp(arena, init.io, args);
    if (std.mem.eql(u8, cmd, "indicators")) {
        try sendSimple(arena, init.io, "{\"op\":\"indicators\"}");
        return;
    }
    if (std.mem.eql(u8, cmd, "next")) return sendNextOp(arena, init.io, args);
    if (std.mem.eql(u8, cmd, "tmux-status")) return tmuxStatus(arena, init.io);
    if (std.mem.eql(u8, cmd, "tmux-pane")) return tmuxPane(arena, init.io, args);

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
        .elevenlabs => {
            var el = try ElevenLabs.initFromEnv(allocator);
            defer el.deinit();
            try runSynth(allocator, io, el.provider_handle(), text, voice);
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

fn sendAutoOp(allocator: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) !void {
    if (args.len < 3) return printUsage();
    const enabled = std.mem.eql(u8, args[2], "on");
    if (!enabled and !std.mem.eql(u8, args[2], "off")) return printUsage();

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    if (args.len >= 4) {
        try std.json.Stringify.value(
            .{ .op = "set_auto_speak", .enabled = enabled, .agent_id = args[3] },
            .{},
            &buf.writer,
        );
    } else {
        try std.json.Stringify.value(
            .{ .op = "set_auto_speak", .enabled = enabled },
            .{},
            &buf.writer,
        );
    }
    try sendSimple(allocator, io, buf.written());
}

fn tmuxStatus(allocator: std.mem.Allocator, io: std.Io) !void {
    const reply = fetchIndicators(allocator, io) catch {
        // Silent on error — status lines must not spam on daemon bounces.
        return;
    };
    defer allocator.free(reply);
    try renderIndicators(reply, allocator);
}

fn tmuxPane(allocator: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) !void {
    const pane_id = if (args.len >= 3)
        args[2]
    else blk: {
        const raw = std.c.getenv("TMUX_PANE") orelse return;
        break :blk std.mem.span(raw);
    };

    const reply = fetchIndicators(allocator, io) catch return;
    defer allocator.free(reply);

    // Parse and find this pane's entry.
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, reply, .{}) catch return;
    defer parsed.deinit();

    const indicators = parsed.value.object.get("indicators") orelse return;
    if (indicators != .array) return;

    for (indicators.array.items) |ind| {
        if (ind != .object) continue;
        const id_v = ind.object.get("agent_id") orelse continue;
        if (id_v != .string) continue;
        if (!std.mem.eql(u8, id_v.string, pane_id)) continue;

        const waiting = ind.object.get("waiting") orelse continue;
        const count: u64 = switch (waiting) {
            .integer => |i| @intCast(i),
            else => 0,
        };
        const auto_v = ind.object.get("auto_speak");
        const is_auto = auto_v != null and auto_v.? == .bool and auto_v.?.bool;
        const glyph = if (is_auto) "🔊" else "🙋";

        var buf: [256]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{s}{d}", .{ glyph, count });
        _ = std.c.write(1, s.ptr, s.len);
        return;
    }
}

fn fetchIndicators(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const sock = try client_mod.defaultSocketPath(allocator);
    defer allocator.free(sock);
    var c = try client_mod.Client.connect(allocator, io, sock);
    defer c.deinit();
    return c.roundtrip("{\"op\":\"indicators\"}");
}

fn renderIndicators(reply: []const u8, allocator: std.mem.Allocator) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, reply, .{}) catch return;
    defer parsed.deinit();

    const indicators = parsed.value.object.get("indicators") orelse return;
    if (indicators != .array) return;
    if (indicators.array.items.len == 0) return;

    var buf: [4096]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    for (indicators.array.items, 0..) |ind, i| {
        if (ind != .object) continue;
        const id_v = ind.object.get("agent_id") orelse continue;
        const waiting_v = ind.object.get("waiting") orelse continue;
        if (id_v != .string or waiting_v != .integer) continue;

        const auto_v = ind.object.get("auto_speak");
        const is_auto = auto_v != null and auto_v.? == .bool and auto_v.?.bool;
        const glyph = if (is_auto) "🔊" else "🙋";

        if (i > 0) try fbs.writeAll(" ");
        try fbs.print("[{s}{s}:{d}]", .{ glyph, id_v.string, waiting_v.integer });
    }
    const out = fbs.buffered();
    _ = std.c.write(1, out.ptr, out.len);
}

fn sendNextOp(allocator: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) !void {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    if (args.len >= 3) {
        try std.json.Stringify.value(
            .{ .op = "next", .agent_id = args[2] },
            .{},
            &buf.writer,
        );
    } else {
        try buf.writer.writeAll("{\"op\":\"next\"}");
    }
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

const ProviderKind = enum { openai, azure, elevenlabs };

fn detectProvider() ProviderKind {
    const raw = std.c.getenv("CHORUS_PROVIDER") orelse return .openai;
    const name = std.mem.span(raw);
    if (std.mem.eql(u8, name, "azure")) return .azure;
    if (std.mem.eql(u8, name, "elevenlabs") or std.mem.eql(u8, name, "11labs")) return .elevenlabs;
    return .openai;
}
