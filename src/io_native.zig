const std = @import("std");
const dbg = std.debug.print;
//pub fn dbg(a: anytype, b: anytype) void {}
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

    var lenny = try stdout.read(&buf);
    dbg("read: {}\n", .{lenny});
    var slice = buf[0..lenny];
    dbg("{s}\n", .{slice});
    var decoder = mpack.Decoder{ .data = slice };
    var decodeFrame = async decodeLoop(&decoder);
    // TODO: Y U so t h i c c?
    // @compileLog(@sizeOf(@TypeOf(decodeFrame)));
    dbg("NÅGONSTANS", .{});
    // FAIL: not synchronized with inconsumed data!
    lenny = try stdout.read(&buf);
    dbg("read2: {}\n", .{lenny});
    decoder.data = buf[0..lenny];
    resume decoder.frame;
    dbg("GÖTEBORD", .{});
    resume decoder.frame;
    try nosuspend await decodeFrame;
}

const RPCError = mpack.Decoder.Error || error{
    MalformatedRPCMessage,
};

fn decodeLoop(decoder: *mpack.Decoder) RPCError!void {
    while (true) {
        var msgHead = try decoder.expectArray();
        if (msgHead < 3) {
            return RPCError.MalformatedRPCMessage;
        }

        var msgKind = try decoder.expectUInt();
        switch (msgKind) {
            1 => try decodeResponse(decoder, msgHead),
            2 => try decodeEvent(decoder, msgHead),
            else => return error.MalformatedRPCMessage,
        }
    }
}

fn decodeResponse(decoder: *mpack.Decoder, arraySize: u32) RPCError!void {
    if (arraySize != 4) {
        return error.MalformatedRPCMessage;
    }
    var id = try decoder.expectUInt();
    dbg("id: {}\n", .{id});
    var state = try decoder.readHead();
    dbg("{}\n", .{state});
    state = try decoder.readHead();
    dbg("{}\n", .{state});
}

fn decodeEvent(decoder: *mpack.Decoder, arraySize: u32) RPCError!void {
    if (arraySize != 3) {
        return error.MalformatedRPCMessage;
    }
    var name = try decoder.expectString();
    dbg("name: {s}\n", .{name});
    var args = try decoder.expectArray();
    dbg("narg: {}\n", .{args});
    while (args > 0) : (args -= 1) {
        var iargs = try decoder.expectArray();
        dbg("iarg: {}\n", .{iargs});
        var iname = try decoder.expectString();
        dbg("iname: {s}\n", .{iname});
        try decoder.skipAhead(iargs - 1);
    }
}
