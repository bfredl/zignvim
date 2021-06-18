const std = @import("std");
const dbg = std.debug.print;
const c = @cImport({
    @cInclude("uv.h");
});
const mpack = @import("./mpack.zig");

fn zero(val: c_int) !void {
    if (val != 0) {
        dbg("the cow jumped over the moon: {}\n", .{val});
        return error.TheCowJumpedOverTheMoon;
    }
}

fn nonneg(val: anytype) !@TypeOf(val) {
    if (val < 0) {
        dbg("the dinner conversation is lively: {}\n", .{val});
        return error.TheCowJumpedOverTheMoon;
    }
    return val;
}

fn unconst(comptime T: type, ptr: anytype) T {
    return @intToPtr(T, @ptrToInt(ptr));
}

const Datta = struct {
    allocator: *std.mem.Allocator,
};

fn uv_buf(val: []const u8) c.uv_buf_t {
    return .{ .base = unconst([*c]u8, val.ptr), .len = val.len };
}

fn alloc_cb(handle: [*c]c.uv_handle_t, len: usize, buf: [*c]c.uv_buf_t) callconv(.C) void {
    var datta = @ptrCast(*Datta, @alignCast(@alignOf(Datta), handle.*.data));
    var mem = datta.allocator.alloc(u8, 1024) catch return;
    buf.* = uv_buf(mem);
}

fn read_cb(stream: [*c]c.uv_stream_t, len: isize, buf: [*c]const c.uv_buf_t) callconv(.C) void {
    var datta = @ptrCast(*Datta, @alignCast(@alignOf(Datta), stream.*.data));
    dbg("read: {}\n", .{len});
    var slice = buf.*.base[0..buf.*.len];
    dbg("{s}\n", .{slice});
}

pub fn main() !void {
    var loop: c.uv_loop_t = undefined;
    try zero(c.uv_loop_init(&loop));

    var stdin_pipe: c.uv_pipe_t = undefined;
    try zero(c.uv_pipe_init(&loop, &stdin_pipe, 0));
    var stdin = @ptrCast(*c.uv_stream_t, &stdin_pipe);

    var stdout_pipe: c.uv_pipe_t = undefined;
    try zero(c.uv_pipe_init(&loop, &stdout_pipe, 0));
    var stdout = @ptrCast(*c.uv_stream_t, &stdout_pipe);

    const Flags = c.uv_stdio_flags;

    var uvstdio: [3]c.uv_stdio_container_t = .{
        .{ .flags = @intToEnum(Flags, c.UV_CREATE_PIPE | c.UV_READABLE_PIPE), .data = .{ .stream = stdin } },
        .{ .flags = @intToEnum(Flags, c.UV_CREATE_PIPE | c.UV_WRITABLE_PIPE), .data = .{ .stream = stdout } },
        .{ .flags = @intToEnum(Flags, c.UV_INHERIT_FD), .data = .{ .fd = 2 } },
    };

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

    var proc: c.uv_process_t = undefined;
    var status = c.uv_spawn(&loop, &proc, &proc_opt);
    dbg("{}\n", .{status});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const ByteArray = std.ArrayList(u8);
    var x = ByteArray.init(&gpa.allocator);
    defer x.deinit();
    var encoder = mpack.Encoder(ByteArray.Writer){ .writer = x.writer() };

    try encoder.startArray(4);
    try encoder.putInt(0); // request
    try encoder.putInt(0); // msgid
    try encoder.putStr("nvim_get_api_info");
    try encoder.startArray(0);

    var buf = uv_buf(x.items);

    var len = try nonneg(c.uv_try_write(stdin, &buf, 1));
    if (len != buf.len) {
        dbg("feeel {}\n", .{len});
    }

    var datta = Datta{ .allocator = &gpa.allocator };
    stdout.data = &datta;
    try zero(c.uv_read_start(stdout, alloc_cb, read_cb));

    var loopy = c.uv_run(&loop, c.uv_run_mode.UV_RUN_DEFAULT);
    dbg("loopy: {}\n", .{loopy});

    if (c.uv_loop_close(&loop) != 0) {
        dbg("very error\n", .{});
    }
    return;
}
