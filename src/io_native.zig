const std = @import("std");
const dbg = std.debug.print;
const mpack = @import("./mpack.zig");

const ChildProcess = std.ChildProcess;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const argv = &[_][]const u8{ "nvim", "--embed" };
    const child = try std.ChildProcess.init(argv, &gpa.allocator);
    defer child.deinit();

    child.stdout_behavior = ChildProcess.StdIo.Pipe;
    child.stdin_behavior = ChildProcess.StdIo.Pipe;
    child.stderr_behavior = ChildProcess.StdIo.Inherit;

    try child.spawn();

    var stdin = &child.stdin.?;
    var stdout = &child.stdout.?;

    const ByteArray = std.ArrayList(u8);
    var x = ByteArray.init(&gpa.allocator);
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
    var buf: [1024]u8 = undefined;

    try decodeLoop(&buf, stdout);
}

fn decodeLoop(buf: []u8, file: *std.fs.File) !void {
    var lenny = try file.read(buf);

    dbg("read: {}\n", .{lenny});
    var slice = buf[0..lenny];
    dbg("{s}\n", .{slice});

    var decoder = mpack.Decoder{ .data = slice };
    var msgHead = try decoder.expectArray();
    dbg("heada {}\n", .{msgHead});
    if (msgHead < 3) {
        return error.SIGFAIL;
    }
    var msgKind = try decoder.expectUInt();
    switch (msgKind) {
        1 => response(&decoder),
        else => return error.MalformatedRPCMessage,
    }
    dbg("kinda {}\n", .{msgKind});
    var state = try decoder.readHead();
    dbg("{}\n", .{state});
    state = try decoder.readHead();
    dbg("{}\n", .{state});
    state = try decoder.readHead();
    dbg("{}\n", .{state});
}
