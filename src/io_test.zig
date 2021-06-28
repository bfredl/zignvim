const std = @import("std");
const io_native = @import("./io_native.zig");

pub fn main() !void {
    // And I Am abandoned by the light
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // They said I’m doomed to be a child
    var child = try io_native.spawn(&gpa.allocator);
    try io_native.attach_test(&child.stdin.?, &gpa.allocator);
    try io_native.dummy_loop(&child.stdout.?, &gpa.allocator);
}
