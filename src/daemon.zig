//! Chorus daemon: owns the audio device and serializes speech across agents.
//!
//! Listens on a Unix socket and speaks a tiny line-delimited JSON protocol:
//!
//!   → { "op": "speak", "agent_id": "%1", "text": "hello", "voice": "onyx" }
//!   ← { "ok": true, "queued": 3 }
//!
//!   → { "op": "status" }
//!   ← { "ok": true, "queued": 0, "processed": 17, "failed": 0 }
//!
//! A single worker thread drains the queue with the serialize policy: one
//! agent speaks at a time, in FIFO order across all agents.

const std = @import("std");
const audio = @import("audio.zig");
const provider = @import("provider.zig");
const OpenAI = @import("providers/openai.zig").OpenAI;
const Azure = @import("providers/azure.zig").Azure;
const qmod = @import("queue.zig");

const SpeakJob = qmod.SpeakJob;
const JobQueue = qmod.JobQueue;

const default_socket_suffix = "chorus.sock";

pub const Daemon = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    queue: JobQueue,
    stats: Stats = .{},
    provider_kind: ProviderKind,
    socket_path: []u8,

    pub const Stats = struct {
        processed: std.atomic.Value(u64) = .init(0),
        failed: std.atomic.Value(u64) = .init(0),
    };

    pub const ProviderKind = enum { openai, azure };

    pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
        const kind = detectProvider();
        const sock_path = try defaultSocketPath(allocator);

        // Remove any stale socket from a previous run.
        unlinkIfExists(sock_path);

        var daemon = Daemon{
            .allocator = allocator,
            .io = io,
            .queue = JobQueue.init(allocator),
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
            // Handle each client on a short-lived thread so synth + enqueue
            // doesn't block the accept loop. Detach because we don't need to
            // join.
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
                const msg = @errorName(err);
                self.writeError(writer, msg) catch return;
            };
            writer.flush() catch return;
        }
    }

    fn handleMessage(self: *Daemon, line: []const u8, writer: *std.Io.Writer) !void {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            line,
            .{},
        );
        defer parsed.deinit();

        const root = parsed.value;
        const op = root.object.get("op") orelse return error.MissingOp;
        if (op != .string) return error.BadOp;

        if (std.mem.eql(u8, op.string, "speak")) {
            try self.handleSpeak(root, writer);
        } else if (std.mem.eql(u8, op.string, "status")) {
            try self.handleStatus(writer);
        } else {
            return error.UnknownOp;
        }
    }

    fn handleSpeak(self: *Daemon, root: std.json.Value, writer: *std.Io.Writer) !void {
        const agent_id_v = root.object.get("agent_id") orelse return error.MissingAgentId;
        const text_v = root.object.get("text") orelse return error.MissingText;
        const voice_v = root.object.get("voice") orelse return error.MissingVoice;
        if (agent_id_v != .string or text_v != .string or voice_v != .string) {
            return error.BadField;
        }

        const job: SpeakJob = .{
            .agent_id = try self.allocator.dupe(u8, agent_id_v.string),
            .text = try self.allocator.dupe(u8, text_v.string),
            .voice = try self.allocator.dupe(u8, voice_v.string),
            .speed = if (root.object.get("speed")) |s| switch (s) {
                .float => |f| @floatCast(f),
                .integer => |i| @floatFromInt(i),
                else => 1.0,
            } else 1.0,
        };
        try self.queue.push(job);

        try std.json.Stringify.value(.{
            .ok = true,
            .queued = self.queue.len(),
        }, .{}, writer);
        try writer.writeAll("\n");
    }

    fn handleStatus(self: *Daemon, writer: *std.Io.Writer) !void {
        try std.json.Stringify.value(.{
            .ok = true,
            .queued = self.queue.len(),
            .processed = self.stats.processed.load(.monotonic),
            .failed = self.stats.failed.load(.monotonic),
        }, .{}, writer);
        try writer.writeAll("\n");
    }

    fn writeError(_: *Daemon, writer: *std.Io.Writer, message: []const u8) !void {
        try std.json.Stringify.value(.{ .ok = false, .@"error" = message }, .{}, writer);
        try writer.writeAll("\n");
        try writer.flush();
    }

    fn workerLoop(self: *Daemon) void {
        while (self.queue.pop()) |job| {
            defer job.deinit(self.allocator);
            self.processJob(job) catch |err| {
                std.debug.print("chorus-daemon: job failed for agent={s}: {s}\n", .{
                    job.agent_id, @errorName(err),
                });
                _ = self.stats.failed.fetchAdd(1, .monotonic);
                continue;
            };
            _ = self.stats.processed.fetchAdd(1, .monotonic);
        }
    }

    fn processJob(self: *Daemon, job: SpeakJob) !void {
        std.debug.print("chorus-daemon: agent={s} speaking ({d} chars)\n", .{
            job.agent_id, job.text.len,
        });

        switch (self.provider_kind) {
            .openai => {
                var oa = try OpenAI.initFromEnv(self.allocator);
                defer oa.deinit();
                try self.synthAndPlay(oa.provider_handle(), job);
            },
            .azure => {
                var az = try Azure.initFromEnv(self.allocator);
                defer az.deinit();
                try self.synthAndPlay(az.provider_handle(), job);
            },
        }
    }

    fn synthAndPlay(self: *Daemon, p: provider.Provider, job: SpeakJob) !void {
        var result = try p.synthesize(self.allocator, self.io, .{
            .text = job.text,
            .voice_id = job.voice,
            .speed = job.speed,
        });
        defer result.deinit(self.allocator);
        try audio.playBytes(result.bytes);
    }
};

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
