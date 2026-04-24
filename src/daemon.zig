//! Chorus daemon: owns the audio device and serializes speech across agents.
//!
//! Protocol — newline-delimited JSON over a Unix socket. Every message is a
//! single JSON object; every reply is a single JSON object ending in "\n".
//!
//! Supported ops:
//!
//!   speak         { agent_id, text, voice?, speed? }
//!                 → { ok, queued }
//!
//!   status        {} → { ok, queued, processed, failed, current_agent? }
//!
//!   list          {} → { ok, agents: [...] }
//!
//!   pause/resume  { agent_id } → { ok }
//!   mute/unmute   { agent_id } → { ok }
//!   skip          { agent_id } → { ok, removed }   (drops queued jobs + cancels in-flight)
//!   set_voice     { agent_id, voice } → { ok }
//!   set_volume    { agent_id, volume } → { ok }
//!
//! One worker thread drains the FIFO queue; paused jobs get re-queued at the
//! tail so other agents keep flowing. Muted jobs are "played" as no-ops.

const std = @import("std");
const audio = @import("audio.zig");
const provider = @import("provider.zig");
const OpenAI = @import("providers/openai.zig").OpenAI;
const Azure = @import("providers/azure.zig").Azure;
const ElevenLabs = @import("providers/elevenlabs.zig").ElevenLabs;
const qmod = @import("queue.zig");
const registry_mod = @import("registry.zig");
const chunker = @import("chunker.zig");

const SpeakJob = qmod.SpeakJob;
const JobQueue = qmod.JobQueue;
const Registry = registry_mod.Registry;

const default_socket_suffix = "chorus.sock";

/// A chunk that has been synthesized and is ready to play. Owned bytes
/// are freed by whoever pops from the ready queue.
const ReadyChunk = struct {
    agent_id: []u8,
    text: []u8,
    bytes: []u8,
    volume: f32,

    fn deinit(self: ReadyChunk, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_id);
        allocator.free(self.text);
        allocator.free(self.bytes);
    }
};

pub const Daemon = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    queue: JobQueue,
    registry: Registry,
    stats: Stats = .{},
    provider_kind: ProviderKind,
    socket_path: []u8,

    /// Global override. When true, every queued job is treated as
    /// priority = the old "speak in FIFO order" behavior. When false
    /// (default), the hand-raise model applies: only the first arrival
    /// while idle speaks automatically; everyone else waits for `next`.
    auto_speak_default: std.atomic.Value(bool) = .init(false),
    wake_worker: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,
    wake_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    /// Prefetch pipeline. The synth thread pulls jobs from `queue`,
    /// fetches audio bytes from the provider, and pushes ReadyChunks
    /// here. The play thread pops from `ready` and plays. Bounded so
    /// we don't over-synthesize and burn provider credits ahead of
    /// the listener.
    ready_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    ready_cond_has_item: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,
    ready_cond_has_room: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,
    ready: std.ArrayList(ReadyChunk) = .empty,
    /// Maximum chunks buffered ahead of the player. Three = enough to
    /// hide ~one TTFB of synth latency without ballooning memory.
    ready_cap: usize = 3,

    current_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    current_agent: ?[]u8 = null,
    current_cancel: audio.CancelToken = .{},

    pub const Stats = struct {
        processed: std.atomic.Value(u64) = .init(0),
        failed: std.atomic.Value(u64) = .init(0),
    };

    pub const ProviderKind = enum { openai, azure, elevenlabs };

    pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
        const kind = detectProvider();
        const sock_path = try defaultSocketPath(allocator);
        unlinkIfExists(sock_path);

        var daemon = Daemon{
            .allocator = allocator,
            .io = io,
            .queue = JobQueue.init(allocator),
            .registry = Registry.init(allocator),
            .provider_kind = kind,
            .socket_path = sock_path,
        };
        defer daemon.deinit();

        std.debug.print("chorus-daemon: listening on {s} (provider={s})\n", .{
            sock_path, @tagName(kind),
        });

        const synth_thread = try std.Thread.spawn(.{}, synthLoop, .{&daemon});
        defer synth_thread.join();
        const play_thread = try std.Thread.spawn(.{}, playLoop, .{&daemon});
        defer play_thread.join();

        try daemon.acceptLoop();
        daemon.queue.close();
    }

    fn deinit(self: *Daemon) void {
        self.queue.deinit();
        self.registry.deinit();
        for (self.ready.items) |c| c.deinit(self.allocator);
        self.ready.deinit(self.allocator);
        if (self.current_agent) |a| self.allocator.free(a);
        self.allocator.free(self.socket_path);
    }

    fn acceptLoop(self: *Daemon) !void {
        const addr = try std.Io.net.UnixAddress.init(self.socket_path);
        var server = try addr.listen(self.io, .{});
        defer server.socket.close(self.io);

        while (true) {
            var client = server.accept(self.io) catch |err| {
                std.debug.print("chorus-daemon: accept error: {s}\n", .{@errorName(err)});
                continue;
            };
            const th = std.Thread.spawn(.{}, handleClient, .{ self, client }) catch |err| {
                std.debug.print("chorus-daemon: spawn error: {s}\n", .{@errorName(err)});
                client.close(self.io);
                continue;
            };
            th.detach();
        }
    }

    fn handleClient(self: *Daemon, client: std.Io.net.Stream) void {
        var stream = client;
        defer stream.close(self.io);

        var read_buf: [8192]u8 = undefined;
        var reader_state = stream.reader(self.io, &read_buf);
        const reader = &reader_state.interface;

        var write_buf: [4096]u8 = undefined;
        var writer_state = stream.writer(self.io, &write_buf);
        const writer = &writer_state.interface;

        while (true) {
            const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream, error.ReadFailed => return,
                else => {
                    self.writeError(writer, "read error") catch {};
                    return;
                },
            };
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;

            self.handleMessage(trimmed, writer) catch |err| {
                self.writeError(writer, @errorName(err)) catch return;
            };
            writer.flush() catch return;
        }
    }

    fn handleMessage(self: *Daemon, line: []const u8, writer: *std.Io.Writer) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, line, .{});
        defer parsed.deinit();

        const root = parsed.value;
        const op_v = root.object.get("op") orelse return error.MissingOp;
        if (op_v != .string) return error.BadOp;
        const op = op_v.string;

        if (std.mem.eql(u8, op, "speak")) return self.opSpeak(root, writer);
        if (std.mem.eql(u8, op, "status")) return self.opStatus(writer);
        if (std.mem.eql(u8, op, "list")) return self.opList(writer);
        if (std.mem.eql(u8, op, "pause")) return self.opSetPaused(root, writer, true);
        if (std.mem.eql(u8, op, "resume")) return self.opSetPaused(root, writer, false);
        if (std.mem.eql(u8, op, "mute")) return self.opSetMuted(root, writer, true);
        if (std.mem.eql(u8, op, "unmute")) return self.opSetMuted(root, writer, false);
        if (std.mem.eql(u8, op, "skip")) return self.opSkip(root, writer);
        if (std.mem.eql(u8, op, "set_voice")) return self.opSetVoice(root, writer);
        if (std.mem.eql(u8, op, "set_volume")) return self.opSetVolume(root, writer);
        if (std.mem.eql(u8, op, "set_auto_speak")) return self.opSetAutoSpeak(root, writer);
        if (std.mem.eql(u8, op, "indicators")) return self.opIndicators(writer);
        if (std.mem.eql(u8, op, "next")) return self.opNext(root, writer);

        return error.UnknownOp;
    }

    fn fallbackVoice(self: *Daemon) []const u8 {
        return switch (self.provider_kind) {
            .openai, .azure => "alloy",
            .elevenlabs => "Rachel",
        };
    }

    // Expose internals for the worker's locked scan in claimNextJob.
    // (Re-entry through Registry's own mutex is fine; the two locks are
    // independent and we always take queue first, registry second.)

    fn opSpeak(self: *Daemon, root: std.json.Value, writer: *std.Io.Writer) !void {
        const agent_id = try requireString(root, "agent_id");
        const text = try requireString(root, "text");
        // Voice is optional; fall back to the agent's configured default,
        // then to a provider-appropriate built-in.
        const voice: []const u8 = if (root.object.get("voice")) |v| switch (v) {
            .string => |s| s,
            else => return error.BadField,
        } else self.registry.defaultVoice(agent_id) orelse self.fallbackVoice();
        const speed: f32 = if (root.object.get("speed")) |s| switch (s) {
            .float => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            else => 1.0,
        } else 1.0;

        try self.registry.ensure(agent_id, voice);

        const chunks = try chunker.split(self.allocator, text, .{});
        defer chunker.freeChunks(self.allocator, chunks);

        // Hand-raise model. If nobody is currently speaking AND nothing is
        // already playing through (no priority jobs queued), this message
        // gets priority = it speaks immediately. Otherwise, every chunk
        // stays non-priority, i.e. "hand raised", and waits for the user
        // to call `next` on this agent.
        //
        // Once an agent's first chunk is promoted (either by being the
        // first speaker or via `next`), the remaining chunks belong to the
        // same utterance and should flow right behind it without requiring
        // another hand raise. So: the first chunk inherits the global
        // decision; subsequent chunks always follow it.
        const nobody_speaking = self.currentAgentSnapshot() == null and
            !self.queue.anyPriorityJobs();
        const first_priority = nobody_speaking;

        for (chunks, 0..) |chunk, idx| {
            const job: SpeakJob = .{
                .agent_id = try self.allocator.dupe(u8, agent_id),
                .text = try self.allocator.dupe(u8, chunk),
                .voice = try self.allocator.dupe(u8, voice),
                .speed = speed,
                // Non-first chunks piggy-back on the first: same priority.
                // This keeps a long utterance from stalling mid-sentence
                // behind itself.
                .priority = if (idx == 0) first_priority else first_priority,
            };
            try self.queue.push(job);
        }

        self.wakeWorker();
        try okWith(writer, .{
            .queued = self.queue.len(),
            .chunks = chunks.len,
            .hand_raised = !first_priority,
        });
    }

    fn currentAgentSnapshot(self: *Daemon) ?[]const u8 {
        _ = std.c.pthread_mutex_lock(&self.current_mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.current_mutex);
        return self.current_agent;
    }

    fn opStatus(self: *Daemon, writer: *std.Io.Writer) !void {
        const current: ?[]const u8 = blk: {
            _ = std.c.pthread_mutex_lock(&self.current_mutex);
            defer _ = std.c.pthread_mutex_unlock(&self.current_mutex);
            if (self.current_agent) |a| break :blk a;
            break :blk null;
        };

        try std.json.Stringify.value(.{
            .ok = true,
            .queued = self.queue.len(),
            .processed = self.stats.processed.load(.monotonic),
            .failed = self.stats.failed.load(.monotonic),
            .current_agent = current,
        }, .{}, writer);
        try writer.writeAll("\n");
    }

    fn opList(self: *Daemon, writer: *std.Io.Writer) !void {
        const snaps = try self.registry.snapshot(self.allocator);
        defer registry_mod.freeSnapshots(self.allocator, snaps);
        try std.json.Stringify.value(.{ .ok = true, .agents = snaps }, .{}, writer);
        try writer.writeAll("\n");
    }

    fn opSetPaused(self: *Daemon, root: std.json.Value, writer: *std.Io.Writer, paused: bool) !void {
        const agent_id = try requireString(root, "agent_id");
        try self.registry.setPaused(agent_id, paused);
        try okWith(writer, .{});
    }

    fn opSetMuted(self: *Daemon, root: std.json.Value, writer: *std.Io.Writer, muted: bool) !void {
        const agent_id = try requireString(root, "agent_id");
        try self.registry.setMuted(agent_id, muted);
        try okWith(writer, .{});
    }

    fn opSkip(self: *Daemon, root: std.json.Value, writer: *std.Io.Writer) !void {
        const agent_id = try requireString(root, "agent_id");
        const removed = self.queue.dropByAgent(agent_id);

        // Cancel if the current job belongs to this agent.
        _ = std.c.pthread_mutex_lock(&self.current_mutex);
        const should_cancel = if (self.current_agent) |a| std.mem.eql(u8, a, agent_id) else false;
        _ = std.c.pthread_mutex_unlock(&self.current_mutex);
        if (should_cancel) self.current_cancel.cancel();

        try okWith(writer, .{ .removed = removed, .cancelled_current = should_cancel });
    }

    fn opSetVoice(self: *Daemon, root: std.json.Value, writer: *std.Io.Writer) !void {
        const agent_id = try requireString(root, "agent_id");
        const voice = try requireString(root, "voice");
        try self.registry.setDefaultVoice(agent_id, voice);
        try okWith(writer, .{});
    }

    fn opSetAutoSpeak(self: *Daemon, root: std.json.Value, writer: *std.Io.Writer) !void {
        const enabled_v = root.object.get("enabled") orelse return error.MissingEnabled;
        if (enabled_v != .bool) return error.BadField;
        const enabled = enabled_v.bool;

        if (root.object.get("agent_id")) |a| {
            if (a != .string) return error.BadField;
            try self.registry.setAutoSpeak(a.string, enabled);
        } else {
            self.auto_speak_default.store(enabled, .release);
        }
        self.wakeWorker();
        try okWith(writer, .{ .auto_speak = enabled });
    }

    fn opIndicators(self: *Daemon, writer: *std.Io.Writer) !void {
        var counts = try self.queue.countHandRaisedByAgent(self.allocator);
        defer counts.deinit(self.allocator);

        // Only hand-raised agents count as indicators. Priority jobs are
        // about to play or already playing; they don't need a "waiting"
        // badge.
        try writer.writeAll("{\"ok\":true,\"indicators\":[");
        var it = counts.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) try writer.writeAll(",");
            first = false;
            try std.json.Stringify.value(.{
                .agent_id = entry.key_ptr.*,
                .waiting = entry.value_ptr.*,
            }, .{}, writer);
        }
        try writer.writeAll("]}\n");
    }

    fn opNext(self: *Daemon, root: std.json.Value, writer: *std.Io.Writer) !void {
        const agent_opt: ?[]const u8 = if (root.object.get("agent_id")) |v| switch (v) {
            .string => |s| s,
            else => return error.BadField,
        } else null;

        // Figure out which agent to promote. With an explicit agent, use
        // that. Without, pick the first hand-raised job in the queue.
        const target: []u8 = blk: {
            if (agent_opt) |a| break :blk try self.allocator.dupe(u8, a);
            if (self.queue.firstNonPriorityAgent(self.allocator)) |a| break :blk a;
            try okWith(writer, .{ .promoted = 0 });
            return;
        };
        defer self.allocator.free(target);

        const promoted = self.queue.promoteAgent(target);
        if (promoted == 0) {
            try okWith(writer, .{ .promoted = 0 });
            return;
        }
        self.wakeWorker();
        try okWith(writer, .{ .promoted = promoted });
    }

    fn wakeWorker(self: *Daemon) void {
        _ = std.c.pthread_mutex_lock(&self.wake_mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.wake_mutex);
        _ = std.c.pthread_cond_broadcast(&self.wake_worker);
    }

    fn opSetVolume(self: *Daemon, root: std.json.Value, writer: *std.Io.Writer) !void {
        const agent_id = try requireString(root, "agent_id");
        const volume_v = root.object.get("volume") orelse return error.MissingVolume;
        const volume: f32 = switch (volume_v) {
            .float => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            else => return error.BadVolume,
        };
        try self.registry.setVolume(agent_id, volume);
        try okWith(writer, .{});
    }

    fn writeError(_: *Daemon, writer: *std.Io.Writer, message: []const u8) !void {
        try std.json.Stringify.value(.{ .ok = false, .@"error" = message }, .{}, writer);
        try writer.writeAll("\n");
        try writer.flush();
    }

    /// Synth thread. Pulls the next eligible job, synthesizes it via the
    /// provider, and pushes the decoded bytes to the ready queue for the
    /// play thread to consume. Blocks when the ready queue is full so we
    /// don't over-prefetch.
    fn synthLoop(self: *Daemon) void {
        while (true) {
            const job_opt = self.claimNextJob() orelse {
                self.waitForWake(100);
                continue;
            };
            var job = job_opt;
            defer job.deinit(self.allocator);

            const bytes = self.synthesizeJob(job) catch |err| {
                std.debug.print("chorus-daemon: agent={s} synth error: {s}\n", .{ job.agent_id, @errorName(err) });
                _ = self.stats.failed.fetchAdd(1, .monotonic);
                continue;
            };
            const volume = self.registry.volume(job.agent_id);

            const chunk: ReadyChunk = .{
                .agent_id = self.allocator.dupe(u8, job.agent_id) catch {
                    self.allocator.free(bytes);
                    continue;
                },
                .text = self.allocator.dupe(u8, job.text) catch {
                    self.allocator.free(bytes);
                    continue;
                },
                .bytes = bytes,
                .volume = volume,
            };
            self.pushReady(chunk);
        }
    }

    /// Play thread. Pops from the ready queue in arrival order and plays
    /// each chunk to completion. Updates current_agent / stats / registry
    /// counters based on what's actually audible.
    fn playLoop(self: *Daemon) void {
        while (self.popReady()) |chunk| {
            defer chunk.deinit(self.allocator);

            self.setCurrent(chunk.agent_id);
            defer self.clearCurrent();
            self.current_cancel.reset();

            if (self.registry.isMuted(chunk.agent_id)) {
                std.debug.print("chorus-daemon: agent={s} muted, skipping playback\n", .{chunk.agent_id});
            } else {
                audio.playBytes(chunk.bytes, chunk.volume, &self.current_cancel) catch |err| {
                    std.debug.print("chorus-daemon: agent={s} play error: {s}\n", .{ chunk.agent_id, @errorName(err) });
                    _ = self.stats.failed.fetchAdd(1, .monotonic);
                    continue;
                };
            }
            self.registry.recordProcessed(chunk.agent_id, chunk.text);
            _ = self.stats.processed.fetchAdd(1, .monotonic);
        }
    }

    fn pushReady(self: *Daemon, chunk: ReadyChunk) void {
        _ = std.c.pthread_mutex_lock(&self.ready_mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.ready_mutex);
        while (self.ready.items.len >= self.ready_cap) {
            _ = std.c.pthread_cond_wait(&self.ready_cond_has_room, &self.ready_mutex);
        }
        self.ready.append(self.allocator, chunk) catch {
            chunk.deinit(self.allocator);
            return;
        };
        _ = std.c.pthread_cond_signal(&self.ready_cond_has_item);
    }

    fn popReady(self: *Daemon) ?ReadyChunk {
        _ = std.c.pthread_mutex_lock(&self.ready_mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.ready_mutex);
        while (self.ready.items.len == 0) {
            _ = std.c.pthread_cond_wait(&self.ready_cond_has_item, &self.ready_mutex);
        }
        const c = self.ready.orderedRemove(0);
        _ = std.c.pthread_cond_signal(&self.ready_cond_has_room);
        return c;
    }

    /// Pop the next job the worker is allowed to play.
    ///
    /// Hand-raise model: the worker only drains jobs with `priority = true`.
    /// Non-priority jobs sit silently in the queue until a client calls
    /// `next` on their agent, which flips them to priority.
    ///
    /// The global `auto_speak_default` escape hatch, when true, treats
    /// every queued job as priority — restoring the old "just speak in
    /// FIFO order" behavior for users who want it.
    fn claimNextJob(self: *Daemon) ?SpeakJob {
        const force_auto = self.auto_speak_default.load(.acquire);

        _ = std.c.pthread_mutex_lock(&self.queue.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.queue.mutex);
        var i: usize = 0;
        while (i < self.queue.jobs.items.len) : (i += 1) {
            const job = self.queue.jobs.items[i];
            if (self.registry.isPaused(job.agent_id)) continue;
            if (!job.priority and !force_auto) continue;
            return self.queue.jobs.orderedRemove(i);
        }
        return null;
    }

    fn waitForWake(self: *Daemon, timeout_ms: u32) void {
        _ = std.c.pthread_mutex_lock(&self.wake_mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.wake_mutex);
        const ts: std.c.timespec = .{
            .sec = 0,
            .nsec = @intCast(timeout_ms * std.time.ns_per_ms),
        };
        var abs: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &abs);
        abs.sec += ts.sec;
        abs.nsec += ts.nsec;
        if (abs.nsec >= std.time.ns_per_s) {
            abs.sec += 1;
            abs.nsec -= std.time.ns_per_s;
        }
        _ = std.c.pthread_cond_timedwait(&self.wake_worker, &self.wake_mutex, &abs);
    }

    fn setCurrent(self: *Daemon, agent_id: []const u8) void {
        const copy = self.allocator.dupe(u8, agent_id) catch return;
        _ = std.c.pthread_mutex_lock(&self.current_mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.current_mutex);
        if (self.current_agent) |prev| self.allocator.free(prev);
        self.current_agent = copy;
    }

    fn clearCurrent(self: *Daemon) void {
        _ = std.c.pthread_mutex_lock(&self.current_mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.current_mutex);
        if (self.current_agent) |prev| self.allocator.free(prev);
        self.current_agent = null;
    }

    /// Fetch audio bytes for a single job through the configured provider.
    /// Caller owns the returned slice.
    fn synthesizeJob(self: *Daemon, job: SpeakJob) ![]u8 {
        std.debug.print("chorus-daemon: agent={s} synth ({d} chars)\n", .{ job.agent_id, job.text.len });
        switch (self.provider_kind) {
            .openai => {
                var oa = try OpenAI.initFromEnv(self.allocator);
                defer oa.deinit();
                return try self.synthOnce(oa.provider_handle(), job);
            },
            .azure => {
                var az = try Azure.initFromEnv(self.allocator);
                defer az.deinit();
                return try self.synthOnce(az.provider_handle(), job);
            },
            .elevenlabs => {
                var el = try ElevenLabs.initFromEnv(self.allocator);
                defer el.deinit();
                return try self.synthOnce(el.provider_handle(), job);
            },
        }
    }

    fn synthOnce(self: *Daemon, p: provider.Provider, job: SpeakJob) ![]u8 {
        const result = try p.synthesize(self.allocator, self.io, .{
            .text = job.text,
            .voice_id = job.voice,
            .speed = job.speed,
        });
        return result.bytes;
    }
};

fn requireString(root: std.json.Value, key: []const u8) ![]const u8 {
    const v = root.object.get(key) orelse return error.MissingField;
    if (v != .string) return error.BadField;
    return v.string;
}

fn okWith(writer: *std.Io.Writer, extras: anytype) !void {
    const Extras = @TypeOf(extras);
    const extra_fields = @typeInfo(Extras).@"struct".fields;
    if (extra_fields.len == 0) {
        try writer.writeAll("{\"ok\":true}\n");
        return;
    }
    // Manually stitch `{ "ok": true, ...extras }` since Zig's JSON writer
    // doesn't spread anonymous struct fields.
    try writer.writeAll("{\"ok\":true,");
    var list: std.Io.Writer.Allocating = .init(std.heap.smp_allocator);
    defer list.deinit();
    try std.json.Stringify.value(extras, .{}, &list.writer);
    const written = list.written();
    // Strip surrounding braces and append.
    if (written.len >= 2) try writer.writeAll(written[1 .. written.len - 1]);
    try writer.writeAll("}\n");
}

fn unlinkIfExists(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return;
    _ = std.c.unlink(z.ptr);
}

fn detectProvider() Daemon.ProviderKind {
    const raw = std.c.getenv("CHORUS_PROVIDER") orelse return .openai;
    const name = std.mem.span(raw);
    if (std.mem.eql(u8, name, "azure")) return .azure;
    if (std.mem.eql(u8, name, "elevenlabs") or std.mem.eql(u8, name, "11labs")) return .elevenlabs;
    return .openai;
}

fn defaultSocketPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("CHORUS_SOCKET")) |raw| {
        return allocator.dupe(u8, std.mem.span(raw));
    }
    return allocator.dupe(u8, "/tmp/chorus.sock");
}
