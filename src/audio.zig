const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("miniaudio.h");
});

pub const AudioError = error{
    EngineInitFailed,
    PlaybackFailed,
};

/// Play an audio file (MP3, WAV, FLAC, etc.) to the default output device.
/// Blocks until playback completes.
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

fn sleepMs(ms: u64) void {
    const ts = std.c.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&ts, null);
}
