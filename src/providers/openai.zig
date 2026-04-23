//! OpenAI TTS provider.
//!
//! Hits POST https://api.openai.com/v1/audio/speech with a JSON body and
//! receives raw audio bytes (MP3 by default). Requires OPENAI_API_KEY in
//! the environment (or an explicit api_key at construction time).

const std = @import("std");
const provider = @import("../provider.zig");

const endpoint = "https://api.openai.com/v1/audio/speech";
const default_model = "tts-1";

const voices_list = [_]provider.Voice{
    .{ .id = "alloy", .display_name = "Alloy" },
    .{ .id = "echo", .display_name = "Echo" },
    .{ .id = "fable", .display_name = "Fable" },
    .{ .id = "onyx", .display_name = "Onyx" },
    .{ .id = "nova", .display_name = "Nova" },
    .{ .id = "shimmer", .display_name = "Shimmer" },
};

pub const OpenAI = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    owns_api_key: bool,

    const vtable: provider.Provider.VTable = .{
        .synthesize = synthesizeErased,
        .voices = voicesErased,
        .name = nameErased,
    };

    /// Construct with an explicit API key. The key is duplicated; caller
    /// retains ownership of the original.
    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !OpenAI {
        const owned = try allocator.dupe(u8, api_key);
        return .{
            .allocator = allocator,
            .api_key = owned,
            .model = default_model,
            .owns_api_key = true,
        };
    }

    /// Read OPENAI_API_KEY from the environment via libc `getenv`.
    pub fn initFromEnv(allocator: std.mem.Allocator) !OpenAI {
        const raw = std.c.getenv("OPENAI_API_KEY") orelse return error.MissingApiKey;
        const key_slice = std.mem.span(raw);
        const owned = try allocator.dupe(u8, key_slice);
        return .{
            .allocator = allocator,
            .api_key = owned,
            .model = default_model,
            .owns_api_key = true,
        };
    }

    pub fn deinit(self: *OpenAI) void {
        if (self.owns_api_key) self.allocator.free(self.api_key);
    }

    pub fn provider_handle(self: *OpenAI) provider.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn synthesize(
        self: *OpenAI,
        allocator: std.mem.Allocator,
        io: std.Io,
        req: provider.SynthRequest,
    ) !provider.SynthResult {
        var body_buf: std.Io.Writer.Allocating = .init(allocator);
        defer body_buf.deinit();
        try std.json.Stringify.value(.{
            .model = self.model,
            .input = req.text,
            .voice = req.voice_id,
            .speed = req.speed,
            .response_format = "mp3",
        }, .{}, &body_buf.writer);
        const body_json = body_buf.written();

        const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.api_key});
        defer allocator.free(auth_header);

        var client: std.http.Client = .{ .allocator = allocator, .io = io };
        defer client.deinit();

        var response_buf: std.Io.Writer.Allocating = .init(allocator);
        errdefer response_buf.deinit();

        const result = try client.fetch(.{
            .method = .POST,
            .location = .{ .url = endpoint },
            .payload = body_json,
            .extra_headers = &.{
                .{ .name = "authorization", .value = auth_header },
                .{ .name = "content-type", .value = "application/json" },
            },
            .response_writer = &response_buf.writer,
        });

        if (result.status != .ok) {
            std.debug.print(
                "openai: http {d} — body: {s}\n",
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
        const self: *OpenAI = @ptrCast(@alignCast(ptr));
        return self.synthesize(allocator, io, req);
    }

    fn voicesErased(_: *anyopaque) []const provider.Voice {
        return &voices_list;
    }

    fn nameErased(_: *anyopaque) []const u8 {
        return "openai";
    }
};

test "openai voices listed" {
    var oa = OpenAI{
        .allocator = std.testing.allocator,
        .api_key = "",
        .model = default_model,
        .owns_api_key = false,
    };
    const handle = oa.provider_handle();
    try std.testing.expectEqualStrings("openai", handle.name());
    try std.testing.expect(handle.voices().len == 6);
}
