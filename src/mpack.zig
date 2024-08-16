const std = @import("std");
const dbg = std.debug.print;

pub fn Encoder(comptime WriterType: type) type {
    return struct {
        writer: WriterType,

        const Self = @This();
        pub const Error = WriterType.Error;

        fn put(self: Self, comptime T: type, val: T) Error!void {
            if (T == u8) {
                try self.writer.writeByte(val);
            } else if (T == u16) {
                try self.put(u8, @intCast((val >> 8) & 0xFF));
                try self.put(u8, @intCast(val & 0xFF));
            } else if (T == u32) {
                try self.put(u8, @intCast((val >> 24) & 0xFF));
                try self.put(u8, @intCast((val >> 16) & 0xFF));
                try self.put(u8, @intCast((val >> 8) & 0xFF));
                try self.put(u8, @intCast(val & 0xFF));
            }
        }

        pub fn putArrayHead(self: Self, count: u32) Error!void {
            if (count <= 15) {
                try self.put(u8, 0x90 | @as(u8, @intCast(count)));
            } else if (count <= std.math.maxInt(u16)) {
                try self.put(u8, 0xdc);
                try self.put(u16, @intCast(count));
            } else {
                try self.put(u8, 0xdd);
                try self.put(u32, @intCast(count));
            }
        }

        pub fn putMapHead(self: Self, count: u32) Error!void {
            if (count <= 15) {
                try self.put(u8, 0x80 | @as(u8, @intCast(count)));
            } else if (count <= std.math.maxInt(u16)) {
                try self.put(u8, 0xde);
                try self.put(u16, @intCast(count));
            } else {
                try self.put(u8, 0xdf);
                try self.put(u32, @intCast(count));
            }
        }

        pub fn putStr(self: Self, val: []const u8) Error!void {
            const len = val.len;
            if (len <= 31) {
                try self.put(u8, 0xa0 + @as(u8, @intCast(len)));
            } else if (len <= 0xFF) {
                try self.put(u8, 0xd9);
                try self.put(u8, @intCast(len));
            }
            try self.writer.writeAll(val);
        }

        pub fn putInt(self: Self, val: anytype) Error!void {
            const unsigned = comptime switch (@typeInfo(@TypeOf(val))) {
                .Int => |int| int.signedness == .unsigned,
                .ComptimeInt => false, // or val >= 0 but handled below
                else => unreachable,
            };
            if (unsigned or val >= 0) {
                if (val <= 0x7f) {
                    try self.put(u8, @intCast(val));
                } else if (val <= std.math.maxInt(u8)) {
                    try self.put(u8, 0xcc);
                    try self.put(u8, @intCast(val));
                } else {
                    @panic("bbb");
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

pub fn encoder(writer: anytype) Encoder(@TypeOf(writer)) {
    return .{ .writer = writer };
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

pub const MpackError = error{
    MalformatedDataError,
    UnexpectedEOFError,
    UnexpectedTagError,
    InvalidDecodeOperation,
};

// this is like the unsafeInnerDecoder, abstract properly with skipDecoder as the outer layer?
// when anything returns `null` the decoder is an unknown state, always needs to be a copy()/accept() layer deep..
// errors are really like ?(Error!value), when we return an error we have read enough to know we dun goofed..
pub const InnerDecoder = struct {
    data: []u8,

    const Self = @This();
    fn readBytes(self: *Self, size: usize) ?[]u8 {
        if (self.data.len < size) {
            return null;
        }
        const slice = self.data[0..size];
        self.data = self.data[size..];
        return slice;
    }

    // maybe [[[
    fn readInt(self: *Self, comptime T: type) ?T {
        if (@typeInfo(T) != .Int) {
            @compileError("why u no int???");
        }
        const slice = self.readBytes(@sizeOf(T)) orelse return null;
        var out: T = undefined;
        @memcpy(std.mem.asBytes(&out), slice);

        return std.mem.bigToNative(T, out);
    }

    fn readFloat(self: *Self, comptime T: type) ?T {
        const utype = if (T == f32) u32 else if (T == f64) u64 else undefined;
        const int = self.readInt(utype) orelse return null;
        return @bitCast(int);
    }

    fn readFixExt(self: *Self, size: u32) ?ExtHead {
        const kind = self.readInt(i8) orelse return null;
        return ExtHead{ .kind = kind, .size = size };
    }

    fn readExt(self: *Self, comptime sizetype: type) ?ExtHead {
        const size = self.readInt(sizetype) orelse return null;
        return self.readFixExt(size);
    }

    /// ]]|
    pub fn readHead(self: *Self) MpackError!?ValueHead {
        const first_byte = (self.readBytes(1) orelse return null)[0];

        const val: ValueHead = switch (first_byte) {
            0x00...0x7f => .{ .Int = first_byte },
            0x80...0x8f => .{ .Map = (first_byte - 0x80) },
            0x90...0x9f => .{ .Array = (first_byte - 0x90) },
            0xa0...0xbf => .{ .Str = (first_byte - 0xa0) },
            0xc0 => .Null,
            0xc1 => return error.MalformatedDataError,
            0xc2 => .{ .Bool = false },
            0xc3 => .{ .Bool = true },
            0xc4 => .{ .Bin = self.readInt(u8) orelse return null },
            0xc5 => .{ .Bin = self.readInt(u16) orelse return null },
            0xc6 => .{ .Bin = self.readInt(u32) orelse return null },
            0xc7 => .{ .Ext = self.readExt(u8) orelse return null },
            0xc8 => .{ .Ext = self.readExt(u16) orelse return null },
            0xc9 => .{ .Ext = self.readExt(u32) orelse return null },
            0xca => .{ .Float32 = self.readFloat(f32) orelse return null },
            0xcb => .{ .Float64 = self.readFloat(f64) orelse return null },
            0xcc => .{ .UInt = self.readInt(u8) orelse return null },
            0xcd => .{ .UInt = self.readInt(u16) orelse return null },
            0xce => .{ .UInt = self.readInt(u32) orelse return null },
            0xcf => .{ .UInt = self.readInt(u64) orelse return null },
            0xd0 => .{ .Int = self.readInt(i8) orelse return null },
            0xd1 => .{ .Int = self.readInt(i16) orelse return null },
            0xd2 => .{ .Int = self.readInt(i32) orelse return null },
            0xd3 => .{ .Int = self.readInt(i64) orelse return null },
            0xd4 => .{ .Ext = self.readFixExt(1) orelse return null },
            0xd5 => .{ .Ext = self.readFixExt(2) orelse return null },
            0xd6 => .{ .Ext = self.readFixExt(4) orelse return null },
            0xd7 => .{ .Ext = self.readFixExt(8) orelse return null },
            0xd8 => .{ .Ext = self.readFixExt(16) orelse return null },
            0xd9 => .{ .Str = self.readInt(u8) orelse return null },
            0xda => .{ .Str = self.readInt(u16) orelse return null },
            0xdb => .{ .Str = self.readInt(u32) orelse return null },
            0xdc => .{ .Array = self.readInt(u16) orelse return null },
            0xdd => .{ .Array = self.readInt(u32) orelse return null },
            0xde => .{ .Map = self.readInt(u16) orelse return null },
            0xdf => .{ .Map = self.readInt(u32) orelse return null },
            0xe0...0xff => .{ .Int = @as(i64, @intCast(first_byte)) - 0x100 },
        };

        return val;
    }

    // TODO: lol what is generic function? :S
    pub fn expectArray(self: *Self) MpackError!?u32 {
        switch (try self.readHead() orelse return null) {
            .Array => |size| return size,
            else => return error.UnexpectedTagError,
        }
    }

    pub fn expectMap(self: *Self) MpackError!u32 {
        switch (try self.readHead()) {
            .Map => |size| return size,
            else => return error.UnexpectedTagError,
        }
    }

    pub fn expectUInt(self: *Self) MpackError!?u64 {
        switch (try self.readHead() orelse return null) {
            .UInt => |val| return val,
            .Int => |val| {
                if (val < 0) {
                    return error.UnexpectedTagError;
                }
                return @intCast(val);
            },
            else => return error.UnexpectedTagError,
        }
    }

    pub fn expectString(self: *Self) MpackError!?[]u8 {
        const size = switch (try self.readHead() orelse return null) {
            .Str => |size| size,
            .Bin => |size| size,
            else => return error.UnexpectedTagError,
        };
        if (self.data.len < size) {
            return null;
        }

        const str = self.data[0..size];
        self.data = self.data[size..];
        return str;
    }
};

pub const SkipDecoder = struct {
    data: []u8,
    bytes: u64 = 0,
    items: u64 = 0,

    fn init(data: []u8) Self {
        return .{ .data = data };
    }

    fn rawInner(self: *Self) InnerDecoder {
        return InnerDecoder{ .data = self.data };
    }

    pub fn inner(self: *Self) !InnerDecoder {
        if (self.bytes > 0 or self.items > 0) return error.InvalidDecodeOperation;
        return self.rawInner();
    }

    pub fn consumed(self: *Self, c: InnerDecoder) void {
        self.data = c.data;
    }

    const Self = @This();

    // TODO: these for a skipDecoder wrapper
    const debugMode = true;
    fn itemSize(head: ValueHead) struct { bytes: u32, items: usize } {
        return switch (head) {
            .Str => |size| .{ .bytes = size, .items = 0 },
            .Bin => |size| .{ .bytes = size, .items = 0 },
            .Ext => |ext| .{ .bytes = ext.size, .items = 0 },
            .Array => |size| .{ .bytes = 0, .items = size },
            .Map => |size| .{ .bytes = 0, .items = 2 * size },
            else => .{ .bytes = 0, .items = 0 },
        };
    }

    pub fn skipData(self: *Self) MpackError!bool {
        while (self.bytes > 0 or self.items > 0) {
            if (self.data.len == 0) {
                return false;
            }
            if (self.bytes > 0) {
                const skip = @min(self.bytes, self.data.len);
                self.data = self.data[skip..];
                self.bytes -= skip;
            } else if (self.items > 0) {
                var d = self.rawInner();
                const head = try d.readHead() orelse return false;
                self.consumed(d);
                const size = itemSize(head);
                self.items += size.items;
                self.items -= 1;
                self.bytes += size.bytes;
            }
        }
        return true;
    }

    pub fn toSkip(self: *Self, items: usize) void {
        self.items += items;
    }
};

const ArrayList = std.ArrayList;

test {
    const testing = std.testing;
    const allocator = testing.allocator;
    var x = ArrayList(u8).init(allocator);
    defer x.deinit();
    var enc = encoder(x.writer());
    try enc.startArray(4);
    try enc.putInt(4);
    try enc.putInt(200);

    try testing.expectEqualSlices(u8, &[_]u8{ 0x94, 0x04, 0xcc, 0xc8 }, x.items);

    var decoder = InnerDecoder{ .data = x.items };
    try testing.expectEqual(ValueHead{ .Array = 4 }, try decoder.readHead());
    try testing.expectEqual(ValueHead{ .Int = 4 }, try decoder.readHead());
    try testing.expectEqual(ValueHead{ .Int = 200 }, try decoder.readHead());
}
