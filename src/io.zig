const std = @import("std");
const dbg = std.debug.print;
const c = @cImport({
    @cInclude("uv.h");
});

fn zero(val: c_int) !void {
    if (val != 0) {
        dbg("the cow jumped over the moon: {}\n", .{val});
        return error.CowJumpedTheMoon;
    }
}

pub fn main() !void {
    var loop: c.uv_loop_t = undefined;

    _ = c.uv_loop_init(&loop);

    var proc: c.uv_process_t = undefined;

    var stdin: c.uv_pipe_t = undefined;
    try zero(c.uv_pipe_init(&loop, &stdin, 0));
    var stdout: c.uv_pipe_t = undefined;
    try zero(c.uv_pipe_init(&loop, &stdout, 0));
    const Flags = c.uv_stdio_flags;

    var uvstdio: [3]c.uv_stdio_container_t = .{ .{ .flags = @intToEnum(Flags, c.UV_CREATE_PIPE | c.UV_READABLE_PIPE), .data = .{ .stream = @ptrCast([*c]c.uv_stream_t, &stdin) } }, .{ .flags = @intToEnum(Flags, c.UV_CREATE_PIPE | c.UV_WRITABLE_PIPE), .data = .{ .stream = @ptrCast([*c]c.uv_stream_t, &stdout) } }, .{ .flags = @intToEnum(Flags, c.UV_INHERIT_FD), .data = .{ .fd = 2 } } };

    const args = &[_:null]?[*:0]u8{ "nvim", "--embed" };
    const yarg = @intToPtr([*c][*c]u8, @ptrToInt(args)); // yarrrg

    var proc_opt: c.uv_process_options_t = .{
        .file = "/usr/local/bin/nvim",
        .args = yarg,
        .env = null,
        .flags = 0,
        .cwd = null,
        .stdio_count = 3,
        .stdio = &uvstdio,
        .uid = 0,
        .gid = 0,
        .exit_cb = null,
    };

    var status = c.uv_spawn(&loop, &proc, &proc_opt);
    dbg("{}\n", .{status});

    if (c.uv_loop_close(&loop) != 0) {
        dbg("very error\n", .{});
    }
    return;
}
