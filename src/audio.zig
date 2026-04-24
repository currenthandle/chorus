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

/// Persistent audio engine. Hold one across the life of the daemon so we
/// don't pay device-open / engine-init cost between chunks. Playback is
/// driven by `playBytes` which decodes into a fresh `ma_sound` but keeps
/// the engine / audio device running continuously between chunks.
pub const Player = struct {
    engine: c.ma_engine,
    initialized: bool = false,

    pub fn init(self: *Player) !void {
        if (c.ma_engine_init(null, &self.engine) != c.MA_SUCCESS) {
            return AudioError.EngineInitFailed;
        }
        self.initialized = true;
    }

    pub fn deinit(self: *Player) void {
        if (self.initialized) {
            c.ma_engine_uninit(&self.engine);
            self.initialized = false;
        }
    }

    /// Play in-memory bytes through the persistent engine. Blocks until
    /// playback completes or `cancel` is tripped. The decoder is held on
    /// the stack of this call and torn down after the sound ends; only
    /// the engine + device persists between calls, which is where the
    /// latency savings live.
    pub fn play(self: *Player, bytes: []const u8, volume: f32, cancel: ?*CancelToken) !void {
        if (cancel) |tok| if (tok.isCancelled()) return;

        var decoder: c.ma_decoder = undefined;
        const dec_cfg = c.ma_decoder_config_init_default();
        if (c.ma_decoder_init_memory(bytes.ptr, bytes.len, &dec_cfg, &decoder) != c.MA_SUCCESS) {
            return AudioError.DecoderInitFailed;
        }
        defer _ = c.ma_decoder_uninit(&decoder);

        var sound: c.ma_sound = undefined;
        if (c.ma_sound_init_from_data_source(
            &self.engine,
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

        // Tight poll: 5ms granularity so the play thread reacts to the
        // end-of-sound almost immediately and can pick up the next ready
        // chunk with minimal gap. CPU cost is negligible at 5ms.
        while (c.ma_sound_is_playing(&sound) != 0) {
            if (cancel) |tok| {
                if (tok.isCancelled()) {
                    _ = c.ma_sound_stop(&sound);
                    return;
                }
            }
            sleepMs(5);
        }
    }
};

/// Play an audio file once with a one-shot engine. Used by the `play`
/// subcommand; the daemon's long-running Player is preferred everywhere
/// else.
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
        sleepMs(5);
    }
}

/// One-shot byte playback with its own engine. Used by the `speak`
/// subcommand for direct (non-daemon) playback.
pub fn playBytes(bytes: []const u8, volume: f32, cancel: ?*CancelToken) !void {
    var player: Player = undefined;
    try player.init();
    defer player.deinit();
    try player.play(bytes, volume, cancel);
}

fn sleepMs(ms: u64) void {
    const ts = std.c.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&ts, null);
}
