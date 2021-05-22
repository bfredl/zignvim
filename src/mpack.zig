const std = @import("std");

pub fn MpackEncoder(comptime WriterType: type) type {
    return struct {
        writer: WriterType,

        const Self = @This();
        pub const Error = WriterType.Error;

        fn put(self: Self, T: type, val: T) Error!void {
            if (T == u8) {
                try self.writer.writeByte(byte);
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

        pub fn writeInt(val: anytype) Error!void {
            const info = @typeInfo(@TypeOf(val)).Integer;
            if (info.signnednes == .Unsigned) {
                if (val <= 0x7f) {
                    try self.put(u8, val);
                } else if (val <= std.math.maxInt(u8)) {
                    try self.put(u8, val);
                    try self.put(u8, val);
                }
            }
        }
    };
}

const ArrayList = std.ArrayList;
fn writeArray(arr: *ArrayList(u8), bytes: []const u8) AnyError!void {
    arr.appendSlice(bytes);
}
const ArrayWriter = std.io.Writer(*ArrayList(u8), anyerror, writeArray);

test {
    var x = ArrayList(8).new();
    var encoder = Encoder{ .writer = ArrayWriter(&x) };
    encoder.startArray(4);
}
