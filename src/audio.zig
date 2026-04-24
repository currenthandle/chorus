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

/// Shared with miniaudio's notification callback. Set from the audio thread
/// whenever the output device changes state; polled by Player.play before
/// it opens a new sound so the engine is rebuilt on a clean device config.
///
/// We use a plain global because miniaudio's notification struct exposes a
/// `pUserData` slot only via the device we create; wiring that through the
/// engine requires building a pre-initialized ma_device ourselves. The
/// daemon only runs one player, so a single global flag is enough.
var device_dirty: std.atomic.Value(bool) = .init(false);

fn onDeviceNotification(notif: [*c]const c.ma_device_notification) callconv(.c) void {
    const n = notif.*;
    switch (n.type) {
        c.ma_device_notification_type_rerouted,
        c.ma_device_notification_type_interruption_began,
        c.ma_device_notification_type_interruption_ended,
        c.ma_device_notification_type_unlocked,
        => device_dirty.store(true, .release),
        else => {},
    }
}

/// Persistent audio engine that rebuilds itself when macOS rearranges the
/// audio stack (e.g. Superwhisper grabs the mic, Bluetooth device comes
/// online, user switches output). Without this, the engine can get stuck
/// on a torn-down device and drop audio for seconds at a time.
pub const Player = struct {
    engine: c.ma_engine,
    initialized: bool = false,

    pub fn init(self: *Player) !void {
        try self.openEngine();
    }

    pub fn deinit(self: *Player) void {
        self.closeEngine();
    }

    fn openEngine(self: *Player) !void {
        var cfg = c.ma_engine_config_init();
        cfg.notificationCallback = onDeviceNotification;
        if (c.ma_engine_init(&cfg, &self.engine) != c.MA_SUCCESS) {
            return AudioError.EngineInitFailed;
        }
        self.initialized = true;
        device_dirty.store(false, .release);
    }

    fn closeEngine(self: *Player) void {
        if (self.initialized) {
            c.ma_engine_uninit(&self.engine);
            self.initialized = false;
        }
    }

    fn maybeRebuild(self: *Player) !void {
        if (!device_dirty.load(.acquire)) return;
        std.debug.print("chorus-audio: device changed, reopening engine\n", .{});
        self.closeEngine();
        try self.openEngine();
    }

    /// Play in-memory bytes through the engine. Rebuilds the engine first
    /// if the device has been re-routed since the last call.
    pub fn play(self: *Player, bytes: []const u8, volume: f32, cancel: ?*CancelToken) !void {
        if (cancel) |tok| if (tok.isCancelled()) return;

        try self.maybeRebuild();

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

        // Tight poll: 5ms granularity so the play thread reacts to end-of-
        // sound almost immediately. Also checks for device rerouting
        // mid-playback and aborts cleanly so the next chunk gets a fresh
        // engine rather than continuing to drain into a stale device.
        while (c.ma_sound_is_playing(&sound) != 0) {
            if (cancel) |tok| {
                if (tok.isCancelled()) {
                    _ = c.ma_sound_stop(&sound);
                    return;
                }
            }
            if (device_dirty.load(.acquire)) {
                _ = c.ma_sound_stop(&sound);
                return;
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
