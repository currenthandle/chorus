//! ElevenLabs TTS provider.
//!
//! Hits POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id} with a
//! JSON body and receives raw audio bytes (MP3 at 44.1 kHz by default).
//! Authenticates with the `xi-api-key` header.
//!
//! Environment variables:
//!   ELEVENLABS_API_KEY   required
//!   ELEVENLABS_MODEL     optional; default "eleven_turbo_v2_5"
//!
//! Unlike OpenAI/Azure, ElevenLabs voice ids are opaque hex strings. We
//! ship a small curated list for discoverability; users can also pass any
//! voice id string directly and we forward it unchanged.

const std = @import("std");
const provider = @import("../provider.zig");

const api_base = "https://api.elevenlabs.io";
const default_model = "eleven_turbo_v2_5";

// A small set of popular preset voices so `chorus list` / tools/list have
// something useful without hitting the network. Users can pass arbitrary
// ElevenLabs voice ids too; the provider just forwards whatever it gets.
const voices_list = [_]provider.Voice{
    .{ .id = "21m00Tcm4TlvDq8ikWAM", .display_name = "Rachel" },
    .{ .id = "AZnzlk1XvdvUeBnXmlld", .display_name = "Domi" },
    .{ .id = "EXAVITQu4vr4xnSDxMaL", .display_name = "Bella" },
    .{ .id = "ErXwobaYiN019PkySvjV", .display_name = "Antoni" },
    .{ .id = "MF3mGyEYCl7XYWbV9V6O", .display_name = "Elli" },
    .{ .id = "TxGEqnHWrfWFTfGW9XjX", .display_name = "Josh" },
    .{ .id = "VR6AewLTigWG4xSOukaG", .display_name = "Arnold" },
    .{ .id = "pNInz6obpgDQGcFmaJgB", .display_name = "Adam" },
    .{ .id = "yoZ06aMxZJJ28mfd3POQ", .display_name = "Sam" },
};

pub const ElevenLabs = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,

    const vtable: provider.Provider.VTable = .{
        .synthesize = synthesizeErased,
        .voices = voicesErased,
        .name = nameErased,
    };

    pub fn initFromEnv(allocator: std.mem.Allocator) !ElevenLabs {
        const raw_key = std.c.getenv("ELEVENLABS_API_KEY") orelse return error.MissingApiKey;
        const api_key = try allocator.dupe(u8, std.mem.span(raw_key));

        const model = if (std.c.getenv("ELEVENLABS_MODEL")) |raw|
            try allocator.dupe(u8, std.mem.span(raw))
        else
            try allocator.dupe(u8, default_model);

        return .{ .allocator = allocator, .api_key = api_key, .model = model };
    }

    pub fn deinit(self: *ElevenLabs) void {
        self.allocator.free(self.api_key);
        self.allocator.free(self.model);
    }

    pub fn provider_handle(self: *ElevenLabs) provider.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn synthesize(
        self: *ElevenLabs,
        allocator: std.mem.Allocator,
        io: std.Io,
        req: provider.SynthRequest,
    ) !provider.SynthResult {
        const voice_id = if (resolveAlias(req.voice_id)) |id| id else req.voice_id;

        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/v1/text-to-speech/{s}",
            .{ api_base, voice_id },
        );
        defer allocator.free(url);

        // ElevenLabs doesn't support a `speed` field directly on the basic
        // request; speed is typically controlled via the voice_settings.speed
        // on newer models. Include it there so newer models pick it up; older
        // models ignore unknown fields.
        var body_buf: std.Io.Writer.Allocating = .init(allocator);
        defer body_buf.deinit();
        try std.json.Stringify.value(.{
            .text = req.text,
            .model_id = self.model,
            .voice_settings = .{
                .stability = 0.5,
                .similarity_boost = 0.75,
                .speed = req.speed,
            },
        }, .{}, &body_buf.writer);

        var client: std.http.Client = .{ .allocator = allocator, .io = io };
        defer client.deinit();

        var response_buf: std.Io.Writer.Allocating = .init(allocator);
        errdefer response_buf.deinit();

        const result = try client.fetch(.{
            .method = .POST,
            .location = .{ .url = url },
            .payload = body_buf.written(),
            .extra_headers = &.{
                .{ .name = "xi-api-key", .value = self.api_key },
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "accept", .value = "audio/mpeg" },
            },
            .response_writer = &response_buf.writer,
        });

        if (result.status != .ok) {
            std.debug.print(
                "elevenlabs: http {d} — body: {s}\n",
                .{ @intFromEnum(result.status), response_buf.written() },
            );
            return switch (result.status) {
                .unauthorized, .forbidden => error.AuthError,
                .too_many_requests => error.RateLimited,
                else => error.HttpError,
            };
        }

        return .{
            .bytes = try response_buf.toOwnedSlice(),
            .format = .mp3,
        };
    }

    fn synthesizeErased(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        req: provider.SynthRequest,
    ) anyerror!provider.SynthResult {
        const self: *ElevenLabs = @ptrCast(@alignCast(ptr));
        return self.synthesize(allocator, io, req);
    }

    fn voicesErased(_: *anyopaque) []const provider.Voice {
        return &voices_list;
    }

    fn nameErased(_: *anyopaque) []const u8 {
        return "elevenlabs";
    }
};

/// Map a friendly display name (case-insensitive) to a preset voice id so
/// users can type `chorus voice %12 rachel` instead of a 20-char hex.
fn resolveAlias(input: []const u8) ?[]const u8 {
    for (voices_list) |v| {
        if (std.ascii.eqlIgnoreCase(input, v.display_name)) return v.id;
    }
    return null;
}

test "alias resolves case-insensitively" {
    try std.testing.expectEqualStrings(
        "21m00Tcm4TlvDq8ikWAM",
        resolveAlias("Rachel").?,
    );
    try std.testing.expectEqualStrings(
        "pNInz6obpgDQGcFmaJgB",
        resolveAlias("adam").?,
    );
    try std.testing.expect(resolveAlias("nonexistent") == null);
}

test "raw voice id passes through" {
    try std.testing.expect(resolveAlias("custom-voice-id-xyz") == null);
}
