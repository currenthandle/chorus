//! Azure OpenAI TTS provider.
//!
//! Hits POST {endpoint}/openai/deployments/{deployment}/audio/speech
//! with a JSON body and receives raw audio bytes. Authenticates with
//! the `api-key` header (not Bearer). Environment variables:
//!
//!   AZURE_OPENAI_ENDPOINT     e.g. https://myresource.openai.azure.com
//!   AZURE_OPENAI_DEPLOYMENT   name of the TTS deployment
//!   AZURE_OPENAI_API_VERSION  e.g. 2025-03-01-preview
//!   AZURE_OPENAI_API_KEY      resource key

const std = @import("std");
const provider = @import("../provider.zig");

const voices_list = [_]provider.Voice{
    .{ .id = "alloy", .display_name = "Alloy" },
    .{ .id = "echo", .display_name = "Echo" },
    .{ .id = "fable", .display_name = "Fable" },
    .{ .id = "onyx", .display_name = "Onyx" },
    .{ .id = "nova", .display_name = "Nova" },
    .{ .id = "shimmer", .display_name = "Shimmer" },
};

pub const Azure = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    endpoint: []const u8,
    deployment: []const u8,
    api_version: []const u8,

    const vtable: provider.Provider.VTable = .{
        .synthesize = synthesizeErased,
        .voices = voicesErased,
        .name = nameErased,
    };

    /// Load all config from environment variables.
    pub fn initFromEnv(allocator: std.mem.Allocator) !Azure {
        return .{
            .allocator = allocator,
            .api_key = try dupEnv(allocator, "AZURE_OPENAI_API_KEY"),
            .endpoint = try dupEnv(allocator, "AZURE_OPENAI_ENDPOINT"),
            .deployment = try dupEnv(allocator, "AZURE_OPENAI_DEPLOYMENT"),
            .api_version = try dupEnv(allocator, "AZURE_OPENAI_API_VERSION"),
        };
    }

    pub fn deinit(self: *Azure) void {
        self.allocator.free(self.api_key);
        self.allocator.free(self.endpoint);
        self.allocator.free(self.deployment);
        self.allocator.free(self.api_version);
    }

    pub fn provider_handle(self: *Azure) provider.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn synthesize(
        self: *Azure,
        allocator: std.mem.Allocator,
        io: std.Io,
        req: provider.SynthRequest,
    ) !provider.SynthResult {
        const url = try std.fmt.allocPrint(allocator, "{s}/openai/deployments/{s}/audio/speech?api-version={s}", .{
            trimTrailingSlash(self.endpoint),
            self.deployment,
            self.api_version,
        });
        defer allocator.free(url);

        var body_buf: std.Io.Writer.Allocating = .init(allocator);
        defer body_buf.deinit();
        try std.json.Stringify.value(.{
            .model = self.deployment,
            .input = req.text,
            .voice = req.voice_id,
            .speed = req.speed,
            .response_format = "mp3",
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
                .{ .name = "api-key", .value = self.api_key },
                .{ .name = "content-type", .value = "application/json" },
            },
            .response_writer = &response_buf.writer,
        });

        if (result.status != .ok) {
            std.debug.print(
                "azure: http {d} — body: {s}\n",
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
        const self: *Azure = @ptrCast(@alignCast(ptr));
        return self.synthesize(allocator, io, req);
    }

    fn voicesErased(_: *anyopaque) []const provider.Voice {
        return &voices_list;
    }

    fn nameErased(_: *anyopaque) []const u8 {
        return "azure";
    }
};

fn dupEnv(allocator: std.mem.Allocator, key: [:0]const u8) ![]u8 {
    const raw = std.c.getenv(key.ptr) orelse return error.MissingEnv;
    return allocator.dupe(u8, std.mem.span(raw));
}

fn trimTrailingSlash(s: []const u8) []const u8 {
    if (s.len == 0) return s;
    return if (s[s.len - 1] == '/') s[0 .. s.len - 1] else s;
}
