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
const qmod = @import("queue.zig");
const registry_mod = @import("registry.zig");

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

    current_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    current_agent: ?[]u8 = null,
    current_cancel: audio.CancelToken = .{},

    pub const Stats = struct {
        processed: std.atomic.Value(u64) = .init(0),
        failed: std.atomic.Value(u64) = .init(0),
    };

    pub const ProviderKind = enum { openai, azure };

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

        return error.UnknownOp;
    }

    fn opSpeak(self: *Daemon, root: std.json.Value, writer: *std.Io.Writer) !void {
        const agent_id = try requireString(root, "agent_id");
        const text = try requireString(root, "text");
        const voice = try requireString(root, "voice");
        const speed: f32 = if (root.object.get("speed")) |s| switch (s) {
            .float => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            else => 1.0,
        } else 1.0;

        try self.registry.ensure(agent_id, voice);

        const job: SpeakJob = .{
            .agent_id = try self.allocator.dupe(u8, agent_id),
            .text = try self.allocator.dupe(u8, text),
            .voice = try self.allocator.dupe(u8, voice),
            .speed = speed,
        };
        try self.queue.push(job);

        try okWith(writer, .{ .queued = self.queue.len() });
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
        while (self.queue.pop()) |job| {
            defer job.deinit(self.allocator);

            // If the agent is paused, re-queue at the tail so other agents
            // keep flowing and try again later.
            if (self.registry.isPaused(job.agent_id)) {
                const requeued: SpeakJob = .{
                    .agent_id = self.allocator.dupe(u8, job.agent_id) catch continue,
                    .text = self.allocator.dupe(u8, job.text) catch {
                        self.allocator.free(job.agent_id);
                        continue;
                    },
                    .voice = self.allocator.dupe(u8, job.voice) catch {
                        self.allocator.free(job.agent_id);
                        self.allocator.free(job.text);
                        continue;
                    },
                    .speed = job.speed,
                };
                self.queue.push(requeued) catch requeued.deinit(self.allocator);
                // Avoid a tight spin when the whole queue is paused.
                const ts = std.c.timespec{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
                _ = std.c.nanosleep(&ts, null);
                continue;
            }

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
