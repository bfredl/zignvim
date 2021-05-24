const std = @import("std");

pub fn Encoder(comptime WriterType: type) type {
    return struct {
        writer: WriterType,

        const Self = @This();
        pub const Error = WriterType.Error;

        fn put(self: Self, comptime T: type, val: T) Error!void {
            if (T == u8) {
                try self.writer.writeByte(val);
            } else if (T == u16) {
                try self.put(u8, @intCast(u8, (val >> 8) & 0xFF));
                try self.put(u8, @intCast(u8, val & 0xFF));
            } else if (T == u32) {
                try self.put(u8, @intCast(u8, (val >> 24) & 0xFF));
                try self.put(u8, @intCast(u8, (val >> 16) & 0xFF));
                try self.put(u8, @intCast(u8, (val >> 8) & 0xFF));
                try self.put(u8, @intCast(u8, val & 0xFF));
            }
        }

        pub fn startArray(self: Self, count: usize) Error!void {
            if (count <= 15) {
                try self.put(u8, 0x90 | @intCast(u8, count));
            } else if (count <= std.math.maxInt(u16)) {
                try self.put(u8, 0xdc);
                try self.put(u16, @intCast(u16, count));
            } else if (count <= std.math.maxInt(u32)) {
                try self.put(u8, 0xdd);
                try self.put(u32, @intCast(u32, count));
            } else {
                unreachable;
            }
        }

        pub fn writeInt(self: Self, val: anytype) Error!void {
            comptime const unsigned = switch (@typeInfo(@TypeOf(val))) {
                .Int => |int| int.signedness == .Unsigned,
                .ComptimeInt => false, // or val >= 0 but handled below
                else => unreachable,
            };
            if (unsigned or val >= 0) {
                if (val <= 0x7f) {
                    try self.put(u8, val);
                } else if (val <= std.math.maxInt(u8)) {
                    try self.put(u8, 0xcc);
                    try self.put(u8, val);
                }
            }
        }
    };
}

const ArrayList = std.ArrayList;

test {
    const testing = std.testing;
    const allocator = testing.allocator;
    var x = ArrayList(u8).init(allocator);
    defer x.deinit();
    var encoder = Encoder(ArrayList(u8).Writer){ .writer = x.writer() };
    try encoder.startArray(4);
    try encoder.writeInt(4);
    try encoder.writeInt(200);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x94, 0x04, 0xcc, 0xc8 }, x.items);
}
