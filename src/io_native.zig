const std = @import("std");
const mem = std.mem;
const mpack = @import("./mpack.zig");
const RPCState = @import("./RPCState.zig");

const Child = std.process.Child;

const os = std.os;

pub fn spawn(allocator: mem.Allocator, args: []const ?[*:0]const u8, stdin_fd: ?i32) !std.process.Child {
    //const argv = &[_][]const u8{ "nvim", "--embed" };
    const base_argv = &[_][]const u8{ "nvim", "--embed" };
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.appendSlice(base_argv);
    for (args) |arg| {
        try argv.append(mem.span(arg.?));
    }

    var child = std.process.Child.init(argv.items, allocator);

    child.stdout_behavior = Child.StdIo.Pipe;
    child.stdin_behavior = Child.StdIo.Pipe;
    child.stderr_behavior = Child.StdIo.Inherit;
    if (stdin_fd) |_| unreachable;
    // child.bonus_fd = stdin_fd;
    try child.spawn();
    return child;
}

pub fn attach(encoder: anytype, width: u32, height: u32, stdin_fd: ?i32, multigrid: bool) !void {
    if (false) {
        try encoder.putArrayHead(4);
        try encoder.putInt(0); // request
        try encoder.putInt(0); // msgid
        try encoder.putStr("nvim_get_api_info");
        try encoder.putArrayHead(0);
    } else {
        if (false) {
            // we prefer this once we have implemented replies..
            try encoder.putArrayHead(4);
            try encoder.putInt(0); // request
            try encoder.putInt(0); // msgid
        } else {
            try encoder.putArrayHead(3);
            try encoder.putInt(2); // notify
        }

        try encoder.putStr("nvim_ui_attach");
        try encoder.putArrayHead(3);
        try encoder.putInt(width);
        try encoder.putInt(height);
        const EINS: u32 = 1;
        const items: u32 = 1 + (if (stdin_fd != null) EINS else 0) + (if (multigrid) EINS else 0);
        try encoder.putMapHead(items);
        try encoder.putStr("ext_linegrid");
        try encoder.putBool(true);
        if (stdin_fd) |fd| {
            try encoder.putStr("stdin_fd");
            try encoder.putInt(fd);
        }
        if (multigrid) {
            try encoder.putStr("ext_multigrid");
            try encoder.putBool(true);
        }
    }
}

pub fn unsafe_input(encoder: anytype, input: []const u8) !void {
    try encoder.putArrayHead(3);
    try encoder.putInt(2); // notify
    try encoder.putStr("nvim_input");
    try encoder.putArrayHead(1);
    try encoder.putStr(input);
}

pub fn try_resize(encoder: anytype, grid: u32, width: u32, height: u32) !void {
    try encoder.putArrayHead(3);
    try encoder.putInt(2); // notify
    try encoder.putStr("nvim_ui_try_resize_grid");
    try encoder.putArrayHead(3);
    try encoder.putInt(grid);
    try encoder.putInt(width);
    try encoder.putInt(height);
}

pub fn dummy_loop(stdout: anytype, allocator: mem.Allocator) !void {
    var buf: [1024]u8 = undefined;
    var decoder = mpack.SkipDecoder{ .data = buf[0..0] };
    var rpc = try RPCState.init(allocator);

    // @compileLog(@sizeOf(@Frame(decodeLoop)));
    // 11920 with fully async readHead()
    // 5928 without

    while (true) {
        const oldlen = decoder.data.len;
        if (oldlen > 0 and decoder.data.ptr != &buf) {
            // TODO: avoid move if remaining space is plenty (like > 900)
            mem.copyForwards(u8, &buf, decoder.data);
        }
        const lenny = try stdout.read(buf[oldlen..]);
        decoder.data = buf[0 .. oldlen + lenny];

        while (decoder.data.len > 0) {
            rpc.process(&decoder) catch |err| {
                switch (err) {
                    error.EOFError => {
                        std.debug.print("!!interrupted. {} bytes left in state {}\n", .{ decoder.data.len, rpc.state });
                        break; // continue outer loop, try read more data
                    },
                    error.FlushCondition => {
                        std.debug.print("!!flushed. but {} bytes left in state {}\n", .{ decoder.data.len, rpc.state });
                        rpc.ui.dump_grid(1);
                        continue; // there might be more data after the flush
                    },
                    else => |e| return e,
                }
            };
        }
    }
}
