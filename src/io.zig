const std = @import("std");
const dbg = std.debug.print;
const c = @cImport({
    @cInclude("uv.h");
});

pub fn main() !void {
    var loop: c.uv_loop_t = undefined;

    _ = c.uv_loop_init(&loop);

    if (c.uv_loop_close(&loop) != 0) {
        dbg("very error", .{});
    }
    return;
}
