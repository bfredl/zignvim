const std = @import("std");
const mem = std.mem;
const mpack = @import("./mpack.zig");
const RPC = @import("./RPC.zig");

const Child = std.process.Child;

const os = std.os;

pub fn spawn(allocator: mem.Allocator, stdin_fd: ?i32) !std.process.Child {
    //const argv = &[_][]const u8{ "nvim", "--embed" };
    const argv = &[_][]const u8{ "nvim", "--embed", "-u", "NORC" };
    var child = std.process.Child.init(argv, allocator);

    child.stdout_behavior = Child.StdIo.Pipe;
    child.stdin_behavior = Child.StdIo.Pipe;
    child.stderr_behavior = Child.StdIo.Inherit;
    if (stdin_fd) |_| unreachable;
    // child.bonus_fd = stdin_fd;
    try child.spawn();
    return child;
}

pub fn attach_test(encoder: anytype, stdin_fd: ?i32) !void {
    if (false) {
        try encoder.putArrayHead(4);
        try encoder.putInt(0); // request
        try encoder.putInt(0); // msgid
        try encoder.putStr("nvim_get_api_info");
        try encoder.putArrayHead(0);
    } else {
        try encoder.putArrayHead(4);
        try encoder.putInt(0); // request
        try encoder.putInt(0); // msgid
        try encoder.putStr("nvim_ui_attach");
        try encoder.putArrayHead(3);
        try encoder.putInt(80); // width
        try encoder.putInt(24); // height
        try encoder.putMapHead(if (stdin_fd != null) 2 else 1);
        try encoder.putStr("ext_linegrid");
        try encoder.putBool(true);
        if (stdin_fd) |fd| {
            try encoder.putStr("stdin_fd");
            try encoder.putInt(fd);
        }
    }
}

pub fn unsafe_input(encoder: anytype, input: []const u8) !void {
    try encoder.putArrayHead(3);
    try encoder.putInt(2); // request
    try encoder.putStr("nvim_input");
    try encoder.putArrayHead(1);
    try encoder.putStr(input);
}

pub fn dummy_loop(stdout: anytype, allocator: mem.Allocator) !void {
    var buf: [1024]u8 = undefined;
    var lenny = try stdout.read(&buf);
    var decoder = mpack.Decoder{ .data = buf[0..lenny] };
    //var rpc = RPC.init(allocator);
    _ = allocator;

    // @compileLog(@sizeOf(@Frame(decodeLoop)));
    // 11920 with fully async readHead()
    // 5928 without

    while (true) {
        const oldlen = decoder.data.len;
        if (oldlen > 0 and decoder.data.ptr != &buf) {
            // TODO: avoid move if remaining space is plenty (like > 900)
            mem.copyForwards(u8, &buf, decoder.data);
        }
        lenny = try stdout.read(buf[oldlen..]);
        decoder.data = buf[0 .. oldlen + lenny];

        process(&decoder);
    }
}

pub fn process(decoder: *mpack.Decoder) void {
    std.debug.print("haii {}\n", .{decoder.data.len});
    decoder.data.len = 0;
}
