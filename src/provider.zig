//! TTS provider interface.
//!
//! A Provider converts a (text, voice, speed) request into raw audio bytes
//! in some known format. The daemon is provider-agnostic; all it needs is
//! bytes it can hand to miniaudio.

const std = @import("std");

pub const AudioFormat = enum {
    mp3,
    wav,
    flac,
    ogg,
    aac,
};

pub const SynthRequest = struct {
    text: []const u8,
    voice_id: []const u8,
    /// Playback speed multiplier. 1.0 is normal.
    speed: f32 = 1.0,
};

pub const SynthResult = struct {
    bytes: []u8,
    format: AudioFormat,

    pub fn deinit(self: SynthResult, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

pub const Voice = struct {
    id: []const u8,
    display_name: []const u8,
};

pub const Error = error{
    HttpError,
    AuthError,
    RateLimited,
    BadRequest,
    Unsupported,
    OutOfMemory,
};

/// Type-erased provider handle. The vtable dispatches to the concrete
/// implementation; `ptr` is the implementation's `*Self`.
pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        synthesize: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            io: std.Io,
            req: SynthRequest,
        ) anyerror!SynthResult,

        voices: *const fn (ptr: *anyopaque) []const Voice,

        name: *const fn (ptr: *anyopaque) []const u8,
    };

    pub fn synthesize(
        self: Provider,
        allocator: std.mem.Allocator,
        io: std.Io,
        req: SynthRequest,
    ) anyerror!SynthResult {
        return self.vtable.synthesize(self.ptr, allocator, io, req);
    }

    pub fn voices(self: Provider) []const Voice {
        return self.vtable.voices(self.ptr);
    }

    pub fn name(self: Provider) []const u8 {
        return self.vtable.name(self.ptr);
    }
};
