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

pub const Daemon = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    queue: JobQueue,
    registry: Registry,
    stats: Stats = .{},
    provider_kind: ProviderKind,
    socket_path: []u8,

    /// Daemon-wide default for auto-speak. When false, queued jobs sit in
    /// the queue until a client calls `next`. Per-agent overrides in the
    /// registry take precedence. Defaults to true so existing behavior
    /// (immediate speech) is preserved.
    auto_speak_default: std.atomic.Value(bool) = .init(true),
    wake_worker: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,
    wake_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

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

        const worker_thread = try std.Thread.spawn(.{}, workerLoop, .{&daemon});
        defer worker_thread.join();

        try daemon.acceptLoop();
        daemon.queue.close();
    }

    fn deinit(self: *Daemon) void {
        self.queue.deinit();
        self.registry.deinit();
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

    // Expose internals for the worker's locked scan in claimNextJob.
    // (Re-entry through Registry's own mutex is fine; the two locks are
    // independent and we always take queue first, registry second.)

    fn opSpeak(self: *Daemon, root: std.json.Value, writer: *std.Io.Writer) !void {
        const agent_id = try requireString(root, "agent_id");
        const text = try requireString(root, "text");
        // Voice is optional; fall back to the agent's configured default.
        const voice: []const u8 = if (root.object.get("voice")) |v| switch (v) {
            .string => |s| s,
            else => return error.BadField,
        } else self.registry.defaultVoice(agent_id) orelse "alloy";
        const speed: f32 = if (root.object.get("speed")) |s| switch (s) {
            .float => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            else => 1.0,
        } else 1.0;

        try self.registry.ensure(agent_id, voice);

        const chunks = try chunker.split(self.allocator, text, .{});
        defer chunker.freeChunks(self.allocator, chunks);

        for (chunks) |chunk| {
            const job: SpeakJob = .{
                .agent_id = try self.allocator.dupe(u8, agent_id),
                .text = try self.allocator.dupe(u8, chunk),
                .voice = try self.allocator.dupe(u8, voice),
                .speed = speed,
            };
            try self.queue.push(job);
        }

        self.wakeWorker();
        try okWith(writer, .{ .queued = self.queue.len(), .chunks = chunks.len });
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
        var counts = try self.queue.countByAgent(self.allocator);
        defer counts.deinit(self.allocator);

        // Serialize as an array of {agent_id, waiting} objects so tmux
        // scripts can iterate without JSON-path gymnastics.
        try writer.writeAll("{\"ok\":true,\"indicators\":[");
        var it = counts.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) try writer.writeAll(",");
            first = false;
            const effective = self.registry.effectiveAutoSpeak(
                entry.key_ptr.*,
                self.auto_speak_default.load(.acquire),
            );
            try std.json.Stringify.value(.{
                .agent_id = entry.key_ptr.*,
                .waiting = entry.value_ptr.*,
                .auto_speak = effective,
            }, .{}, writer);
        }
        try writer.writeAll("]}\n");
    }

    fn opNext(self: *Daemon, root: std.json.Value, writer: *std.Io.Writer) !void {
        const agent_opt = if (root.object.get("agent_id")) |v| switch (v) {
            .string => |s| s,
            else => return error.BadField,
        } else null;

        // Mark the chosen agent (or all) as auto-speak for exactly one job
        // by popping directly and handing to the worker. Simpler path: pop
        // the first matching job and push it into a priority slot.
        if (agent_opt) |agent| {
            const job = self.queue.popAgent(agent) orelse {
                try okWith(writer, .{ .promoted = false });
                return;
            };
            try self.queue.pushFront(job);
        } else {
            // No specific agent: pop the head that is currently waiting
            // behind auto-speak=false. Nothing to do if head is already
            // eligible.
            const head = self.queue.peekHeadAgent(self.allocator) orelse {
                try okWith(writer, .{ .promoted = false });
                return;
            };
            defer self.allocator.free(head);
            const job = self.queue.popAgent(head) orelse {
                try okWith(writer, .{ .promoted = false });
                return;
            };
            try self.queue.pushFront(job);
        }
        self.wakeWorker();
        try okWith(writer, .{ .promoted = true });
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

    fn workerLoop(self: *Daemon) void {
        while (true) {
            const job_opt = self.claimNextJob() orelse {
                // Nothing eligible right now. Wait for a signal (new job,
                // resume, or next promotion).
                self.waitForWake(100);
                continue;
            };
            var job = job_opt;
            defer job.deinit(self.allocator);

            self.setCurrent(job.agent_id);
            defer self.clearCurrent();
            self.current_cancel.reset();

            self.processJob(job) catch |err| {
                std.debug.print("chorus-daemon: agent={s} error: {s}\n", .{ job.agent_id, @errorName(err) });
                _ = self.stats.failed.fetchAdd(1, .monotonic);
                continue;
            };

            self.registry.recordProcessed(job.agent_id, job.text);
            _ = self.stats.processed.fetchAdd(1, .monotonic);
        }
    }

    /// Pop the next job the worker is allowed to play. Skips jobs for
    /// paused or hand-raise agents without removing them. Returns null if
    /// nothing is currently eligible.
    fn claimNextJob(self: *Daemon) ?SpeakJob {
        const default_auto = self.auto_speak_default.load(.acquire);

        // Linear scan under a single lock so we can honor FIFO among
        // eligible agents while leaving ineligible jobs in place.
        _ = std.c.pthread_mutex_lock(&self.queue.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.queue.mutex);
        var i: usize = 0;
        while (i < self.queue.jobs.items.len) : (i += 1) {
            const job = self.queue.jobs.items[i];
            if (self.registry.isPaused(job.agent_id)) continue;
            // Priority jobs (promoted via `next`) skip the auto-speak gate.
            if (!job.priority and
                !self.registry.effectiveAutoSpeak(job.agent_id, default_auto))
                continue;
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

    fn processJob(self: *Daemon, job: SpeakJob) !void {
        std.debug.print("chorus-daemon: agent={s} speaking ({d} chars)\n", .{ job.agent_id, job.text.len });

        if (self.registry.isMuted(job.agent_id)) {
            std.debug.print("chorus-daemon: agent={s} muted, skipping playback\n", .{job.agent_id});
            return;
        }

        const volume = self.registry.volume(job.agent_id);

        switch (self.provider_kind) {
            .openai => {
                var oa = try OpenAI.initFromEnv(self.allocator);
                defer oa.deinit();
                try self.synthAndPlay(oa.provider_handle(), job, volume);
            },
            .azure => {
                var az = try Azure.initFromEnv(self.allocator);
                defer az.deinit();
                try self.synthAndPlay(az.provider_handle(), job, volume);
            },
            .elevenlabs => {
                var el = try ElevenLabs.initFromEnv(self.allocator);
                defer el.deinit();
                try self.synthAndPlay(el.provider_handle(), job, volume);
            },
        }
    }

    fn synthAndPlay(self: *Daemon, p: provider.Provider, job: SpeakJob, volume: f32) !void {
        var result = try p.synthesize(self.allocator, self.io, .{
            .text = job.text,
            .voice_id = job.voice,
            .speed = job.speed,
        });
        defer result.deinit(self.allocator);
        try audio.playBytes(result.bytes, volume, &self.current_cancel);
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
    if (std.c.getenv("XDG_RUNTIME_DIR")) |raw| {
        const dir = std.mem.span(raw);
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, default_socket_suffix });
    }
    const user = if (std.c.getenv("USER")) |u| std.mem.span(u) else "user";
    return std.fmt.allocPrint(allocator, "/tmp/chorus-{s}.sock", .{user});
}
