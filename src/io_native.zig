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

    try encoder.startArray(4);
    try encoder.putInt(0); // request
    try encoder.putInt(0); // msgid
    try encoder.putStr("nvim_get_api_info");
    try encoder.startArray(0);

    try stdin.writeAll(x.items);
    var buf: [1024]u8 = undefined;
    var lenny = try stdout.read(&buf);

    dbg("read: {}\n", .{lenny});
    var slice = buf[0..lenny];
    dbg("{s}\n", .{slice});

    var decoder = mpack.Decoder{ .data = slice };
    var state = decoder.readHead();
}
