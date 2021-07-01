const std = @import("std");
const ArrayList = std.ArrayList;
const mpack = @import("./mpack.zig");

const io_native = @import("./io_native.zig");

pub fn main() !void {
    // And I Am abandoned by the light
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // They said I’m doomed to be a child
    var child = try io_native.spawn(&gpa.allocator);
    defer child.deinit();

    const ByteArray = ArrayList(u8);
    var x = ByteArray.init(&gpa.allocator);
    defer x.deinit();
    var encoder = mpack.encoder(x.writer());
    try io_native.attach_test(&encoder);
    try child.stdin.?.writeAll(x.items);

    try io_native.dummy_loop(&child.stdout.?, &gpa.allocator);
}
