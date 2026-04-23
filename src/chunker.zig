//! Split a long utterance into speak-sized chunks so playback starts sooner.
//!
//! The strategy is deliberately simple: walk the text, break on sentence
//! terminators (`.`, `!`, `?`, `…`) and hard paragraph breaks (`\n\n`), and
//! emit any trailing fragment. If a sentence exceeds `max_chunk_len` we
//! fall back to a soft split on comma or space to keep each chunk under
//! the provider's latency sweet spot.
//!
//! The caller owns the returned slices and is responsible for freeing each
//! one along with the outer list. Chunks are allocated fresh so the input
//! can be freed independently.

const std = @import("std");

pub const default_max_chunk_len: usize = 240;
pub const default_min_chunk_len: usize = 24;

pub const Options = struct {
    max_chunk_len: usize = default_max_chunk_len,
    min_chunk_len: usize = default_min_chunk_len,
};

pub fn split(
    allocator: std.mem.Allocator,
    text: []const u8,
    options: Options,
) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |c| allocator.free(c);
        out.deinit(allocator);
    }

    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        const is_break = c == '.' or c == '!' or c == '?' or c == '\n';
        const force_break = (i - start) >= options.max_chunk_len;

        if (is_break or force_break) {
            // For punctuation breaks, include the terminator in the chunk.
            const end_inclusive = if (is_break) i + 1 else i;
            const candidate = std.mem.trim(u8, text[start..end_inclusive], " \t\r\n");

            if (candidate.len >= options.min_chunk_len) {
                try out.append(allocator, try allocator.dupe(u8, candidate));
                start = end_inclusive;
            } else if (force_break) {
                // Soft split on last space to avoid mid-word cuts.
                const soft_end = findSoftBreak(text, start, i);
                const piece = std.mem.trim(u8, text[start..soft_end], " \t\r\n");
                if (piece.len > 0) try out.append(allocator, try allocator.dupe(u8, piece));
                start = soft_end;
            }
        }
        i += 1;
    }

    const tail = std.mem.trim(u8, text[start..], " \t\r\n");
    if (tail.len > 0) try out.append(allocator, try allocator.dupe(u8, tail));

    return out.toOwnedSlice(allocator);
}

fn findSoftBreak(text: []const u8, start: usize, hard_end: usize) usize {
    var j = hard_end;
    while (j > start) {
        const ch = text[j - 1];
        if (ch == ' ' or ch == ',' or ch == ';' or ch == ':') return j;
        j -= 1;
    }
    return hard_end;
}

pub fn freeChunks(allocator: std.mem.Allocator, chunks: [][]u8) void {
    for (chunks) |c| allocator.free(c);
    allocator.free(chunks);
}

test "single sentence stays together" {
    const chunks = try split(std.testing.allocator, "Hello world.", .{});
    defer freeChunks(std.testing.allocator, chunks);
    try std.testing.expectEqual(@as(usize, 1), chunks.len);
    try std.testing.expectEqualStrings("Hello world.", chunks[0]);
}

test "multiple sentences split" {
    const chunks = try split(std.testing.allocator, "One. Two! Three?", .{});
    defer freeChunks(std.testing.allocator, chunks);
    try std.testing.expectEqual(@as(usize, 3), chunks.len);
}

test "tiny input is untouched" {
    const chunks = try split(std.testing.allocator, "Hi.", .{});
    defer freeChunks(std.testing.allocator, chunks);
    try std.testing.expectEqual(@as(usize, 1), chunks.len);
    try std.testing.expectEqualStrings("Hi.", chunks[0]);
}
