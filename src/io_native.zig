const std = @import("std");
const mem = std.mem;
const mpack = @import("./mpack.zig");
const RPC = @import("./RPC.zig");
const ArrayList = std.ArrayList;

const ChildProcess = std.ChildProcess;

pub fn spawn(allocator: *mem.Allocator) !*std.ChildProcess {
    //const argv = &[_][]const u8{ "nvim", "--embed" };
    const argv = &[_][]const u8{ "nvim", "--embed", "-u", "NORC" };
    const child = try std.ChildProcess.init(argv, allocator);

    child.stdout_behavior = ChildProcess.StdIo.Pipe;
    child.stdin_behavior = ChildProcess.StdIo.Pipe;
    child.stderr_behavior = ChildProcess.StdIo.Inherit;

    try child.spawn();
    return child;
}

pub fn attach_test(stdin: anytype, allocator: *mem.Allocator) !void {
    const ByteArray = ArrayList(u8);
    var x = ByteArray.init(allocator);
    defer x.deinit();
    var encoder = mpack.Encoder(ByteArray.Writer){ .writer = x.writer() };

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
        try encoder.putMapHead(1);
        try encoder.putStr("ext_linegrid");
        try encoder.putBool(true);
    }

    try stdin.writeAll(x.items);
}

pub fn dummy_loop(stdout: anytype, allocator: *mem.Allocator) !void {
    var buf: [1024]u8 = undefined;
    var lenny = try stdout.read(&buf);
    var decoder = mpack.Decoder{ .data = buf[0..lenny] };
    var rpc = RPC.init(allocator);
    var decodeFrame = async rpc.decodeLoop(&decoder);

    // @compileLog(@sizeOf(@Frame(decodeLoop)));
    // 11920 with fully async readHead()
    // 5928 without

    while (decoder.frame != null) {
        const oldlen = decoder.data.len;
        if (oldlen > 0 and decoder.data.ptr != &buf) {
            // TODO: avoid move if remaining space is plenty (like > 900)
            mem.copy(u8, &buf, decoder.data);
        }
        lenny = try stdout.read(buf[oldlen..]);
        decoder.data = buf[0 .. oldlen + lenny];

        resume decoder.frame.?;
    }

    try nosuspend await decodeFrame;
}
