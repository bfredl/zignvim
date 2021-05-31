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
                @panic("aaa");
            }
        }

        pub fn putStr(self: Self, val: []u8) Error!void {
            const len = val.len;
            if (len <= 31) {
                try self.put(u8, 0xa0 + len);
            } else if (len <= 0xFF) {
                try self.put(u8, 0xd9);
                try self.put(u8, @intCast(u8, len));
            }
            try self.writer.writeAll(val);
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
            } else {
                @panic("aaa");
            }
        }
    };
}

pub const ValueHead = union(enum) {
    Null,
    Bool: bool,
    Int: i64,
    UInt: u64,
    Float32: f32,
    Float64: f64,
    Array: u64,
    Map: u32,
    Str: u32,
    Bin: u32,
};

pub const Decoder = struct {
    data: []u8,

    const Self = @This();
    const Error = error{
        MalformatedDataError,
        IncompleteData,
    };

    fn readTail(size: usize, tail: *[]u8) Error![]u8 {
        if (tail.len < size) {
            return Error.IncompleteData;
        }
        var slice = tail.*[0..size];
        tail.* = tail.*[size..];
        return slice;
    }

    fn readInt(comptime T: type, tail: *[]u8) Error!T {
        if (@typeInfo(T) != .Int) {
            @compileError("why u no int???");
        }
        var out: T = undefined;
        @memcpy(@ptrCast([*]u8, &out), (try readTail(@sizeOf(T), tail)).ptr, @sizeOf(T));

        return std.mem.bigToNative(T, out);
    }

    inline fn int(i: i64) ValueHead {
        return ValueHead{ .Int = i };
    }

    pub fn readHead(self: *Self) Error!ValueHead {
        if (self.data.len < 1) {
            return Error.IncompleteData;
        }
        const first_byte = self.data[0];
        var tail = self.data[1..];

        const val = switch (first_byte) {
            0x00...0x7f => int(first_byte),
            0x80...0x8f => ValueHead{ .Map = (first_byte - 0x80) },
            0x90...0x9f => ValueHead{ .Array = (first_byte - 0x90) },
            0xa0...0xbf => ValueHead{ .Str = (first_byte - 0xa0) },
            0xc0 => .Null,
            0xc1 => return Error.MalformatedDataError,
            0xc2 => ValueHead{ .Bool = false },
            0xc3 => ValueHead{ .Bool = true },
            0xc4 => ValueHead{ .Bin = try readInt(u8, &tail) },
            0xc5 => ValueHead{ .Bin = try readInt(u16, &tail) },
            0xc6 => ValueHead{ .Bin = try readInt(u32, &tail) },
            0xc7 => ValueHead{ .Ext = try readExt(u8, &tail) },
            0xc8 => ValueHead{ .Ext = try readExt(u16, &tail) },
            0xc9 => ValueHead{ .Ext = try readExt(u32, &tail) },
            0xca => ValueHead{ .Float32 = try readFloat(f32, &tail) },
            0xcb => ValueHead{ .Float64 = try readFloat(f64, &tail) },
            0xcc => ValueHead{ .UInt = try readInt(u8, &tail) },
            0xcd => ValueHead{ .UInt = try readInt(u16, &tail) },
            0xce => ValueHead{ .UInt = try readInt(u32, &tail) },
            0xcf => ValueHead{ .UInt = try readInt(u64, &tail) },
            0xd0 => ValueHead{ .Int = try readInt(i8, &tail) },
            0xd1 => ValueHead{ .Int = try readInt(i16, &tail) },
            0xd2 => ValueHead{ .Int = try readInt(i32, &tail) },
            0xd3 => ValueHead{ .Int = try readInt(i64, &tail) },
            0xd4 => ValueHead{ .Ext = try readFixExt(1, &tail) },
            0xd5 => ValueHead{ .Ext = try readFixExt(2, &tail) },
            0xd6 => ValueHead{ .Ext = try readFixExt(4, &tail) },
            0xd7 => ValueHead{ .Ext = try readFixExt(8, &tail) },
            0xd8 => ValueHead{ .Ext = try readFixExt(16, &tail) },
            0xd0 => int(try readInt(i8, &tail)),
            0xe0...0xff => int(@intCast(i64, first_byte) - 0x100),

            else => return Error.MalformatedDataError,
        };

        self.data = tail;
        return val;
    }
};

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

    var decoder = Decoder{ .data = x.items };
    try testing.expectEqual(ValueHead{ .Array = 4 }, try decoder.readHead());
    try testing.expectEqual(ValueHead{ .Int = 4 }, try decoder.readHead());
    try testing.expectEqual(ValueHead{ .Int = 200 }, try decoder.readHead());
}
