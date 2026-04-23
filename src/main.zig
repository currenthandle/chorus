const std = @import("std");
const audio = @import("audio.zig");
const provider = @import("provider.zig");
const OpenAI = @import("providers/openai.zig").OpenAI;
const Azure = @import("providers/azure.zig").Azure;

const usage =
    \\usage:
    \\  chorus play <audio-file>            Play a file through miniaudio.
    \\  chorus speak <text> [voice]         Synthesize and play.
    \\
    \\The provider is selected by CHORUS_PROVIDER (default: openai). Supported:
    \\  openai  — OPENAI_API_KEY
    \\  azure   — AZURE_OPENAI_{ENDPOINT,DEPLOYMENT,API_VERSION,API_KEY}
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
        if (args.len < 3) {
            std.debug.print("{s}", .{usage});
            return error.MissingArgument;
        }
        try audio.playFile(args[2]);
        return;
    }

    if (std.mem.eql(u8, cmd, "speak")) {
        if (args.len < 3) {
            std.debug.print("{s}", .{usage});
            return error.MissingArgument;
        }
        const text = args[2];
        const voice = if (args.len >= 4) args[3] else "alloy";
        try speak(arena, init.io, text, voice);
        return;
    }

    std.debug.print("{s}", .{usage});
    return error.UnknownCommand;
}

const ProviderKind = enum { openai, azure };

fn selectProvider() ProviderKind {
    const raw = std.c.getenv("CHORUS_PROVIDER") orelse return .openai;
    const name = std.mem.span(raw);
    if (std.mem.eql(u8, name, "azure")) return .azure;
    if (std.mem.eql(u8, name, "openai")) return .openai;
    return .openai;
}

fn speak(
    allocator: std.mem.Allocator,
    io: std.Io,
    text: []const u8,
    voice: []const u8,
) !void {
    switch (selectProvider()) {
        .openai => {
            var openai = try OpenAI.initFromEnv(allocator);
            defer openai.deinit();
            try runSynth(allocator, io, openai.provider_handle(), text, voice);
        },
        .azure => {
            var azure = try Azure.initFromEnv(allocator);
            defer azure.deinit();
            try runSynth(allocator, io, azure.provider_handle(), text, voice);
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
