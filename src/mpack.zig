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

        pub fn putArrayHead(self: Self, count: u32) Error!void {
            if (count <= 15) {
                try self.put(u8, 0x90 | @intCast(u8, count));
            } else if (count <= std.math.maxInt(u16)) {
                try self.put(u8, 0xdc);
                try self.put(u16, @intCast(u16, count));
            } else {
                try self.put(u8, 0xdd);
                try self.put(u32, @intCast(u32, count));
            }
        }

        pub fn putMapHead(self: Self, count: u32) Error!void {
            if (count <= 15) {
                try self.put(u8, 0x80 | @intCast(u8, count));
            } else if (count <= std.math.maxInt(u16)) {
                try self.put(u8, 0xde);
                try self.put(u16, @intCast(u16, count));
            } else {
                try self.put(u8, 0xdf);
                try self.put(u32, @intCast(u32, count));
            }
        }

        pub fn putStr(self: Self, val: []const u8) Error!void {
            const len = val.len;
            if (len <= 31) {
                try self.put(u8, 0xa0 + @intCast(u8, len));
            } else if (len <= 0xFF) {
                try self.put(u8, 0xd9);
                try self.put(u8, @intCast(u8, len));
            }
            try self.writer.writeAll(val);
        }

        pub fn putInt(self: Self, val: anytype) Error!void {
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

        pub fn putBool(self: Self, b: bool) Error!void {
            try self.put(u8, @as(u8, if (b) 0xc3 else 0xc2));
        }
    };
}

pub const ExtHead = struct { kind: i8, size: u32 };
pub const ValueHead = union(enum) {
    Null,
    Bool: bool,
    Int: i64,
    UInt: u64,
    Float32: f32,
    Float64: f64,
    Array: u32,
    Map: u32,
    Str: u32,
    Bin: u32,
    Ext: ExtHead,
};

pub const Decoder = struct {
    data: []u8,

    const Self = @This();
    const Error = error{
        MalformatedDataError,
        IncompleteData,
        UnexpectedTagError,
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

    fn readFloat(comptime T: type, tail: *[]u8) Error!T {
        const utype = if (T == f32) u32 else if (T == f64) u64 else undefined;
        var int = try readInt(utype, tail);
        return @bitCast(T, int);
    }

    fn readFixExt(size: u32, tail: *[]u8) Error!ExtHead {
        var kind = try readInt(i8, tail);
        return ExtHead{ .kind = kind, .size = size };
    }

    fn readExt(comptime sizetype: type, tail: *[]u8) Error!ExtHead {
        var size = try readInt(sizetype, tail);
        return readFixExt(size, tail);
    }

    pub fn readHead(self: *Self) Error!ValueHead {
        if (self.data.len < 1) {
            return Error.IncompleteData;
        }
        const first_byte = self.data[0];
        var tail = self.data[1..];

        const val: ValueHead = switch (first_byte) {
            0x00...0x7f => .{ .Int = first_byte },
            0x80...0x8f => .{ .Map = (first_byte - 0x80) },
            0x90...0x9f => .{ .Array = (first_byte - 0x90) },
            0xa0...0xbf => .{ .Str = (first_byte - 0xa0) },
            0xc0 => .Null,
            0xc1 => return Error.MalformatedDataError,
            0xc2 => .{ .Bool = false },
            0xc3 => .{ .Bool = true },
            0xc4 => .{ .Bin = try readInt(u8, &tail) },
            0xc5 => .{ .Bin = try readInt(u16, &tail) },
            0xc6 => .{ .Bin = try readInt(u32, &tail) },
            0xc7 => .{ .Ext = try readExt(u8, &tail) },
            0xc8 => .{ .Ext = try readExt(u16, &tail) },
            0xc9 => .{ .Ext = try readExt(u32, &tail) },
            0xca => .{ .Float32 = try readFloat(f32, &tail) },
            0xcb => .{ .Float64 = try readFloat(f64, &tail) },
            0xcc => .{ .UInt = try readInt(u8, &tail) },
            0xcd => .{ .UInt = try readInt(u16, &tail) },
            0xce => .{ .UInt = try readInt(u32, &tail) },
            0xcf => .{ .UInt = try readInt(u64, &tail) },
            0xd0 => .{ .Int = try readInt(i8, &tail) },
            0xd1 => .{ .Int = try readInt(i16, &tail) },
            0xd2 => .{ .Int = try readInt(i32, &tail) },
            0xd3 => .{ .Int = try readInt(i64, &tail) },
            0xd4 => .{ .Ext = try readFixExt(1, &tail) },
            0xd5 => .{ .Ext = try readFixExt(2, &tail) },
            0xd6 => .{ .Ext = try readFixExt(4, &tail) },
            0xd7 => .{ .Ext = try readFixExt(8, &tail) },
            0xd8 => .{ .Ext = try readFixExt(16, &tail) },
            0xd9 => .{ .Str = try readInt(u8, &tail) },
            0xda => .{ .Str = try readInt(u16, &tail) },
            0xdb => .{ .Str = try readInt(u32, &tail) },
            0xdc => .{ .Array = try readInt(u16, &tail) },
            0xdd => .{ .Array = try readInt(u32, &tail) },
            0xde => .{ .Map = try readInt(u16, &tail) },
            0xdf => .{ .Map = try readInt(u32, &tail) },
            0xe0...0xff => .{ .Int = @intCast(i64, first_byte) - 0x100 },
        };

        self.data = tail;
        return val;
    }

    // TODO: lol what is generic function? :S
    pub fn expectArray(self: *Self) Error!u32 {
        switch (try self.readHead()) {
            .Array => |size| return size,
            else => return Error.UnexpectedTagError,
        }
    }

    pub fn expectMap(self: *Self) Error!u32 {
        const head = try self.readHead();
        switch (head) {
            .Map => |size| return size,
            else => return Error.UnexpectedTagError,
        }
    }

    pub fn expectUInt(self: *Self) Error!u64 {
        const head = try self.readHead();

        switch (head) {
            .UInt => |val| return val,
            .Int => |val| {
                if (val < 0) {
                    return Error.UnexpectedTagError;
                }
                return @intCast(u64, val);
            },
            else => return Error.UnexpectedTagError,
        }
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
    try encoder.putInt(4);
    try encoder.putInt(200);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x94, 0x04, 0xcc, 0xc8 }, x.items);

    var decoder = Decoder{ .data = x.items };
    try testing.expectEqual(ValueHead{ .Array = 4 }, try decoder.readHead());
    try testing.expectEqual(ValueHead{ .Int = 4 }, try decoder.readHead());
    try testing.expectEqual(ValueHead{ .Int = 200 }, try decoder.readHead());
}
