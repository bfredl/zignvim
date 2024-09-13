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
                .int => |int| int.signedness == .unsigned,
                .comptime_int => false, // or val >= 0 but handled below
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
};

pub const MpackError = error{
    MalformatedDataError,
    // often recoverable, by throwing away innermost decoder
    EOFError,
    UnexpectedTagError,
    InvalidDecodeOperation,
};
const EOFError = error{EOFError};

// this is like the unsafeInnerDecoder, abstract properly with skipDecoder as the outer layer?
// when anything returns `EOFError` the decoder is an unknown state, always needs to be a inner()/consumed() layer deep..
pub const InnerDecoder = struct {
    data: []u8,

    const Self = @This();
    fn readBytes(self: *Self, size: usize) EOFError![]u8 {
        if (self.data.len < size) {
            return error.EOFError;
        }
        const slice = self.data[0..size];
        self.data = self.data[size..];
        return slice;
    }

    fn readInt(self: *Self, comptime T: type) EOFError!T {
        if (@typeInfo(T) != .int) {
            @compileError("why u no int???");
        }
        const slice = try self.readBytes(@sizeOf(T));
        var out: T = undefined;
        @memcpy(std.mem.asBytes(&out), slice);

        return std.mem.bigToNative(T, out);
    }

    fn readFloat(self: *Self, comptime T: type) EOFError!T {
        const utype = if (T == f32) u32 else if (T == f64) u64 else undefined;
        const int = try self.readInt(utype);
        return @bitCast(int);
    }

    fn readFixExt(self: *Self, size: u32) EOFError!ExtHead {
        const kind = try self.readInt(i8);
        return ExtHead{ .kind = kind, .size = size };
    }

    fn readExt(self: *Self, comptime sizetype: type) EOFError!ExtHead {
        const size = try self.readInt(sizetype);
        return try self.readFixExt(size);
    }

    /// ]]|
    pub fn readHead(self: *Self) MpackError!ValueHead {
        const first_byte = (try self.readBytes(1))[0];

        const val: ValueHead = switch (first_byte) {
            0x00...0x7f => .{ .Int = first_byte },
            0x80...0x8f => .{ .Map = (first_byte - 0x80) },
            0x90...0x9f => .{ .Array = (first_byte - 0x90) },
            0xa0...0xbf => .{ .Str = (first_byte - 0xa0) },
            0xc0 => .Null,
            0xc1 => return error.MalformatedDataError,
            0xc2 => .{ .Bool = false },
            0xc3 => .{ .Bool = true },
            0xc4 => .{ .Bin = try self.readInt(u8) },
            0xc5 => .{ .Bin = try self.readInt(u16) },
            0xc6 => .{ .Bin = try self.readInt(u32) },
            0xc7 => .{ .Ext = try self.readExt(u8) },
            0xc8 => .{ .Ext = try self.readExt(u16) },
            0xc9 => .{ .Ext = try self.readExt(u32) },
            0xca => .{ .Float32 = try self.readFloat(f32) },
            0xcb => .{ .Float64 = try self.readFloat(f64) },
            0xcc => .{ .UInt = try self.readInt(u8) },
            0xcd => .{ .UInt = try self.readInt(u16) },
            0xce => .{ .UInt = try self.readInt(u32) },
            0xcf => .{ .UInt = try self.readInt(u64) },
            0xd0 => .{ .Int = try self.readInt(i8) },
            0xd1 => .{ .Int = try self.readInt(i16) },
            0xd2 => .{ .Int = try self.readInt(i32) },
            0xd3 => .{ .Int = try self.readInt(i64) },
            0xd4 => .{ .Ext = try self.readFixExt(1) },
            0xd5 => .{ .Ext = try self.readFixExt(2) },
            0xd6 => .{ .Ext = try self.readFixExt(4) },
            0xd7 => .{ .Ext = try self.readFixExt(8) },
            0xd8 => .{ .Ext = try self.readFixExt(16) },
            0xd9 => .{ .Str = try self.readInt(u8) },
            0xda => .{ .Str = try self.readInt(u16) },
            0xdb => .{ .Str = try self.readInt(u32) },
            0xdc => .{ .Array = try self.readInt(u16) },
            0xdd => .{ .Array = try self.readInt(u32) },
            0xde => .{ .Map = try self.readInt(u16) },
            0xdf => .{ .Map = try self.readInt(u32) },
            0xe0...0xff => .{ .Int = @as(i64, @intCast(first_byte)) - 0x100 },
        };

        return val;
    }

    // TODO: lol what is generic function? :S
    pub fn expectArray(self: *Self) MpackError!u32 {
        switch (try self.readHead()) {
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

    pub fn expectUInt(self: *Self) MpackError!u64 {
        switch (try self.readHead()) {
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

    pub fn expectBool(self: *Self) MpackError!bool {
        switch (try self.readHead()) {
            .Bool => |val| return val,
            else => return error.UnexpectedTagError,
        }
    }

    pub fn expectString(self: *Self) MpackError![]u8 {
        const size = switch (try self.readHead()) {
            .Str => |size| size,
            .Bin => |size| size,
            else => return error.UnexpectedTagError,
        };
        if (self.data.len < size) {
            return error.EOFError;
        }

        const str = self.data[0..size];
        self.data = self.data[size..];
        return str;
    }

    pub fn skipAny(self: *Self, nitems: u64) MpackError!void {
        var bytes: u64 = 0;
        var items: u64 = nitems;
        while (bytes > 0 or items > 0) {
            if (self.data.len == 0) {
                return error.EOFError;
            }
            if (bytes > 0) {
                const skip = @min(bytes, self.data.len);
                self.data = self.data[skip..];
                bytes -= skip;
            } else if (items > 0) {
                const head = try self.readHead();
                const size = head.itemSize();
                items += size.items;
                items -= 1;
                bytes += size.bytes;
            }
        }
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

    const debugMode = true;

    // safe to retry after EOFError
    pub fn skipData(self: *Self) MpackError!void {
        while (self.bytes > 0 or self.items > 0) {
            if (self.data.len == 0) {
                return error.EOFError;
            }
            if (self.bytes > 0) {
                const skip = @min(self.bytes, self.data.len);
                self.data = self.data[skip..];
                self.bytes -= skip;
            } else if (self.items > 0) {
                var d = self.rawInner();
                const head = try d.readHead();
                self.consumed(d);
                const size = head.itemSize();
                self.items += size.items;
                self.items -= 1;
                self.bytes += size.bytes;
            }
        }
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
