const std = @import("std");

const c = @cImport({
    @cInclude("miniaudio.h");
});

pub const AudioError = error{
    EngineInitFailed,
    DecoderInitFailed,
    PlaybackFailed,
};

/// Cancellation handle that callers can flip to stop an in-progress playback.
/// The poll loops check `cancelled.load(.monotonic)` on every tick.
pub const CancelToken = struct {
    cancelled: std.atomic.Value(bool) = .init(false),

    pub fn cancel(self: *CancelToken) void {
        self.cancelled.store(true, .monotonic);
    }

    pub fn reset(self: *CancelToken) void {
        self.cancelled.store(false, .monotonic);
    }

    pub fn isCancelled(self: *const CancelToken) bool {
        return self.cancelled.load(.monotonic);
    }
};

/// Play an audio file. Blocks until playback completes or `cancel` (optional)
/// is tripped. Pass `null` for fire-and-forget.
pub fn playFile(path: []const u8) !void {
    var engine: c.ma_engine = undefined;
    if (c.ma_engine_init(null, &engine) != c.MA_SUCCESS) {
        return AudioError.EngineInitFailed;
    }
    defer c.ma_engine_uninit(&engine);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});

    var sound: c.ma_sound = undefined;
    if (c.ma_sound_init_from_file(&engine, path_z.ptr, 0, null, null, &sound) != c.MA_SUCCESS) {
        return AudioError.PlaybackFailed;
    }
    defer c.ma_sound_uninit(&sound);

    if (c.ma_sound_start(&sound) != c.MA_SUCCESS) {
        return AudioError.PlaybackFailed;
    }

    while (c.ma_sound_is_playing(&sound) != 0) {
        sleepMs(50);
    }
}

/// Play an in-memory audio buffer. `volume` is a linear multiplier in the
/// range 0.0–1.0+ (1.0 = unchanged). `cancel`, if non-null, short-circuits
/// playback when flipped.
pub fn playBytes(bytes: []const u8, volume: f32, cancel: ?*CancelToken) !void {
    if (cancel) |tok| if (tok.isCancelled()) return;

    var engine: c.ma_engine = undefined;
    if (c.ma_engine_init(null, &engine) != c.MA_SUCCESS) {
        return AudioError.EngineInitFailed;
    }
    defer c.ma_engine_uninit(&engine);

    var decoder: c.ma_decoder = undefined;
    const dec_cfg = c.ma_decoder_config_init_default();
    if (c.ma_decoder_init_memory(bytes.ptr, bytes.len, &dec_cfg, &decoder) != c.MA_SUCCESS) {
        return AudioError.DecoderInitFailed;
    }
    defer _ = c.ma_decoder_uninit(&decoder);

    var sound: c.ma_sound = undefined;
    if (c.ma_sound_init_from_data_source(
        &engine,
        &decoder,
        0,
        null,
        &sound,
    ) != c.MA_SUCCESS) {
        return AudioError.PlaybackFailed;
    }
    defer c.ma_sound_uninit(&sound);

    c.ma_sound_set_volume(&sound, volume);

    if (c.ma_sound_start(&sound) != c.MA_SUCCESS) {
        return AudioError.PlaybackFailed;
    }

    while (c.ma_sound_is_playing(&sound) != 0) {
        if (cancel) |tok| {
            if (tok.isCancelled()) {
                _ = c.ma_sound_stop(&sound);
                return;
            }
        }
        sleepMs(50);
    }
}

fn sleepMs(ms: u64) void {
    const ts = std.c.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&ts, null);
}
