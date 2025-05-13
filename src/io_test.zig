const std = @import("std");
const ArrayList = std.ArrayList;
const mpack = @import("./mpack.zig");
const RPCState = @import("./RPCState.zig");

const io_native = @import("./io_native.zig");

rpc: RPCState,
const Self = @This();

pub fn cb_grid_clear(self: *Self, grid: u32) !void {
    _ = self;
    std.debug.print("kireee: {} \n", .{grid});
}

pub fn cb_grid_line(self: *Self, grid: u32, row: u32, start_col: u32, end_col: u32) !void {
    _ = self;
    std.debug.print("boll: {} {}, {}-{}\n", .{ grid, row, start_col, end_col });
}

pub fn cb_flush(self: *Self) !void {
    self.rpc.ui.dump_grid(1);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var child = try io_native.spawn(gpa.allocator(), &[_]?[*:0]const u8{}, null);

    const ByteArray = ArrayList(u8);
    var x = ByteArray.init(gpa.allocator());
    defer x.deinit();
    var encoder = mpack.encoder(x.writer());
    try io_native.attach(&encoder, 80, 25, null, false);
    try child.stdin.?.writeAll(x.items);

    try dummy_loop(&child.stdout.?, gpa.allocator());
}

fn dummy_loop(stdout: anytype, allocator: std.mem.Allocator) !void {
    var buf: [1024]u8 = undefined;
    var decoder = mpack.SkipDecoder{ .data = buf[0..0] };
    var self: @This() = .{ .rpc = try RPCState.init(allocator) };

    while (true) {
        const oldlen = decoder.data.len;
        if (oldlen > 0 and decoder.data.ptr != &buf) {
            // TODO: avoid move if remaining space is plenty (like > 900)
            std.mem.copyForwards(u8, &buf, decoder.data);
        }
        const lenny = try stdout.read(buf[oldlen..]);
        decoder.data = buf[0 .. oldlen + lenny];
        try self.rpc.process(&decoder);
    }
}
