//! Per-agent state keyed by opaque agent id. Thread-safe, built on pthread
//! primitives to match queue.zig.
//!
//! Each agent carries a default voice (used when a speak request omits
//! `voice`), a volume multiplier, a paused flag, and counters. The mixer
//! consults `paused` before claiming a job; the control CLI mutates state
//! through `pause`, `resume`, `setVoice`, etc.

const std = @import("std");

pub const AgentState = struct {
    id: []const u8,
    default_voice: []const u8,
    volume: f32 = 1.0,
    paused: bool = false,
    muted: bool = false,
    /// Per-agent auto-speak override. `null` = inherit from daemon default.
    /// `false` = this agent's jobs stay queued until the user explicitly
    /// calls `next`. `true` = always speak immediately when queue reaches
    /// it.
    auto_speak: ?bool = null,
    processed: u64 = 0,
    last_text: ?[]const u8 = null,

    fn deinit(self: *AgentState, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.default_voice);
        if (self.last_text) |t| allocator.free(t);
    }
};

pub const Snapshot = struct {
    id: []const u8,
    default_voice: []const u8,
    volume: f32,
    paused: bool,
    muted: bool,
    auto_speak: ?bool,
    processed: u64,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    agents: std.StringHashMapUnmanaged(AgentState) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        var it = self.agents.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.agents.deinit(self.allocator);
        _ = std.c.pthread_mutex_unlock(&self.mutex);
        _ = std.c.pthread_mutex_destroy(&self.mutex);
    }

    /// Ensure an agent entry exists, creating it with defaults on first touch.
    pub fn ensure(self: *Registry, id: []const u8, default_voice: []const u8) !void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        if (self.agents.contains(id)) return;

        const id_copy = try self.allocator.dupe(u8, id);
        const voice_copy = try self.allocator.dupe(u8, default_voice);
        const state: AgentState = .{ .id = id_copy, .default_voice = voice_copy };
        try self.agents.put(self.allocator, id_copy, state);
    }

    pub fn isPaused(self: *Registry, id: []const u8) bool {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        return if (self.agents.get(id)) |s| s.paused else false;
    }

    pub fn isMuted(self: *Registry, id: []const u8) bool {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        return if (self.agents.get(id)) |s| s.muted else false;
    }

    /// Return a borrowed pointer to the agent's default voice, or null if
    /// the agent hasn't been registered yet. The returned slice remains
    /// valid while the registry holds the entry; callers should copy if
    /// they need a stable lifetime.
    pub fn defaultVoice(self: *Registry, id: []const u8) ?[]const u8 {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        return if (self.agents.get(id)) |s| s.default_voice else null;
    }

    pub fn volume(self: *Registry, id: []const u8) f32 {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        return if (self.agents.get(id)) |s| s.volume else 1.0;
    }

    pub fn setPaused(self: *Registry, id: []const u8, paused: bool) !void {
        try self.ensure(id, "alloy");
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        if (self.agents.getPtr(id)) |s| s.paused = paused;
    }

    pub fn setMuted(self: *Registry, id: []const u8, muted: bool) !void {
        try self.ensure(id, "alloy");
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        if (self.agents.getPtr(id)) |s| s.muted = muted;
    }

    pub fn setVolume(self: *Registry, id: []const u8, v: f32) !void {
        try self.ensure(id, "alloy");
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        if (self.agents.getPtr(id)) |s| s.volume = v;
    }

    pub fn setAutoSpeak(self: *Registry, id: []const u8, value: ?bool) !void {
        try self.ensure(id, "alloy");
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        if (self.agents.getPtr(id)) |s| s.auto_speak = value;
    }

    /// Resolve the effective auto-speak flag for an agent, falling back to
    /// the daemon-wide default when the agent hasn't set an override.
    pub fn effectiveAutoSpeak(self: *Registry, id: []const u8, default: bool) bool {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        const s = self.agents.get(id) orelse return default;
        return s.auto_speak orelse default;
    }

    pub fn setDefaultVoice(self: *Registry, id: []const u8, voice: []const u8) !void {
        try self.ensure(id, voice);
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        if (self.agents.getPtr(id)) |s| {
            const new_voice = try self.allocator.dupe(u8, voice);
            self.allocator.free(s.default_voice);
            s.default_voice = new_voice;
        }
    }

    pub fn recordProcessed(self: *Registry, id: []const u8, last_text: []const u8) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        const s = self.agents.getPtr(id) orelse return;
        s.processed += 1;
        if (s.last_text) |t| self.allocator.free(t);
        s.last_text = self.allocator.dupe(u8, last_text) catch null;
    }

    /// Copy out a snapshot of every agent. Caller owns the slice and must
    /// free each entry's strings using the same allocator.
    pub fn snapshot(self: *Registry, allocator: std.mem.Allocator) ![]Snapshot {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);

        var out: std.ArrayList(Snapshot) = .empty;
        errdefer {
            for (out.items) |snap| {
                allocator.free(snap.id);
                allocator.free(snap.default_voice);
            }
            out.deinit(allocator);
        }

        var it = self.agents.iterator();
        while (it.next()) |entry| {
            const s = entry.value_ptr.*;
            try out.append(allocator, .{
                .id = try allocator.dupe(u8, s.id),
                .default_voice = try allocator.dupe(u8, s.default_voice),
                .volume = s.volume,
                .paused = s.paused,
                .muted = s.muted,
                .auto_speak = s.auto_speak,
                .processed = s.processed,
            });
        }
        return out.toOwnedSlice(allocator);
    }
};

pub fn freeSnapshots(allocator: std.mem.Allocator, snaps: []Snapshot) void {
    for (snaps) |s| {
        allocator.free(s.id);
        allocator.free(s.default_voice);
    }
    allocator.free(snaps);
}
