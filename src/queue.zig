//! A small thread-safe FIFO job queue for the serialize mixer.
//!
//! The mixer pops the next job, synthesizes it, and plays it to completion
//! before taking another. Multiple agents enqueue concurrently; one worker
//! drains.
//!
//! Synchronization is built on libc pthread primitives directly, which keeps
//! the queue independent of `std.Io` plumbing (the Io-based Mutex in 0.16
//! requires an Io handle at every lock call).

const std = @import("std");

pub const SpeakJob = struct {
    /// Stable opaque identifier for the originating agent (e.g. tmux pane ID).
    agent_id: []const u8,
    /// UTF-8 text to synthesize.
    text: []const u8,
    /// Provider-specific voice identifier.
    voice: []const u8,
    /// Playback speed multiplier.
    speed: f32 = 1.0,

    pub fn deinit(self: SpeakJob, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_id);
        allocator.free(self.text);
        allocator.free(self.voice);
    }
};

pub const JobQueue = struct {
    allocator: std.mem.Allocator,
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    cond: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,
    jobs: std.ArrayList(SpeakJob) = .empty,
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator) JobQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *JobQueue) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        for (self.jobs.items) |job| job.deinit(self.allocator);
        self.jobs.deinit(self.allocator);
        _ = std.c.pthread_mutex_unlock(&self.mutex);
        _ = std.c.pthread_mutex_destroy(&self.mutex);
        _ = std.c.pthread_cond_destroy(&self.cond);
    }

    pub fn push(self: *JobQueue, job: SpeakJob) !void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        try self.jobs.append(self.allocator, job);
        _ = std.c.pthread_cond_signal(&self.cond);
    }

    /// Blocks until a job is available or the queue is closed. Returns null
    /// when the queue has been closed and drained.
    pub fn pop(self: *JobQueue) ?SpeakJob {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        while (self.jobs.items.len == 0 and !self.closed) {
            _ = std.c.pthread_cond_wait(&self.cond, &self.mutex);
        }
        if (self.jobs.items.len == 0) return null;
        return self.jobs.orderedRemove(0);
    }

    pub fn close(self: *JobQueue) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        self.closed = true;
        _ = std.c.pthread_cond_broadcast(&self.cond);
    }

    pub fn len(self: *JobQueue) usize {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        return self.jobs.items.len;
    }
};

test "queue push then pop returns job" {
    var q = JobQueue.init(std.testing.allocator);
    defer q.deinit();

    try q.push(.{
        .agent_id = try std.testing.allocator.dupe(u8, "a1"),
        .text = try std.testing.allocator.dupe(u8, "hi"),
        .voice = try std.testing.allocator.dupe(u8, "onyx"),
    });

    const job = q.pop() orelse return error.ExpectedJob;
    defer job.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a1", job.agent_id);
}
