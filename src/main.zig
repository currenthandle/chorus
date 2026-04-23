const std = @import("std");
const audio = @import("audio.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        std.debug.print("usage: chorus <audio-file>\n", .{});
        return error.MissingArgument;
    }

    const path = args[1];
    std.debug.print("chorus: playing {s}\n", .{path});
    try audio.playFile(path);
    std.debug.print("chorus: done\n", .{});
}
