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
                try self.put(u8, 0xa0 + @as(u8,@intCast(len)));
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

pub const Decoder = struct {
    data: []u8,
    // frame: ?anyframe = null,

    bytes: u32 = 0,
    items: usize = 0,

    const Self = @This();
    pub const Error = error{
        MalformatedDataError,
        UnexpectedEOFError,
        UnexpectedTagError,
        InvalidDecodeOperation,
    };

    fn getMoreData(self: *Self) Error!void {
        const bytes = self.data.len;
        suspend {
            self.frame = @frame();
        }
        self.frame = null;
        if (self.data.len <= bytes) {
            return Error.UnexpectedEOFError;
        }
    }

    // NB: returned slice is only valid until next getMoreData()!
    fn readBytes(self: *Self, size: usize) Error![]u8 {
        while (self.data.len < size) {
            try self.getMoreData();
        }
        const slice = self.data[0..size];
        self.data = self.data[size..];
        return slice;
    }

    // NB: returned slice is only valid until next getMoreData()!
    fn maybeReadBytes(self: *Self, size: usize) ?[]u8 {
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
        const slice = self.maybeReadBytes(@sizeOf(T)) orelse return null;
        var out: T = undefined;
        @memcpy(&out, slice);

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
    const debugMode = true;

    pub fn start(self: *Self) Error!void {
        if (self.bytes > 0 or self.items > 0) {
            return error.InvalidDecodeOperation;
        }
        self.items = 1;
    }

    pub fn push(self: *Self) Error!usize {
        if (self.items == 0) {
            return error.InvalidDecodeOperation;
        }
        const saved = self.items - 1;
        self.items = 1;
        return saved;
    }

    pub fn pop(self: *Self, saved: usize) Error!void {
        if (self.bytes != 0 or self.items != 0) {
            return error.InvalidDecodeOperation;
        }
        self.items = saved;
    }

    pub fn maybeReadHead(self: *Self) Error!?ValueHead {
        if (debugMode) {
            if (self.bytes > 0 or self.items == 0) {
                return error.InvalidDecodeOperation;
            }
        }
        const first_byte = (self.maybeReadBytes(1) orelse return null)[0];

        const val: ValueHead = switch (first_byte) {
            0x00...0x7f => .{ .Int = first_byte },
            0x80...0x8f => .{ .Map = (first_byte - 0x80) },
            0x90...0x9f => .{ .Array = (first_byte - 0x90) },
            0xa0...0xbf => .{ .Str = (first_byte - 0xa0) },
            0xc0 => .Null,
            0xc1 => return Error.MalformatedDataError,
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

        const size = itemSize(val);
        self.items -= 1;
        self.bytes += size.bytes;
        self.items += size.items;

        return val;
    }

    pub fn readHead(self: *Self) Error!ValueHead {
        while (true) {
            const oldpos = self.data;
            // oldpos not restored on error, but it should be fatal anyway
            const attempt = try self.maybeReadHead();
            if (attempt) |head| {
                return head;
            } else {
                self.data = oldpos;
                try self.getMoreData();
            }
        }
    }

    // TODO: lol what is generic function? :S
    pub fn expectArray(self: *Self) Error!u32 {
        switch (try self.readHead()) {
            .Array => |size| return size,
            else => return Error.UnexpectedTagError,
        }
    }

    pub fn expectMap(self: *Self) Error!u32 {
        switch (try self.readHead()) {
            .Map => |size| return size,
            else => return Error.UnexpectedTagError,
        }
    }

    pub fn expectUInt(self: *Self) Error!u64 {
        switch (try self.readHead()) {
            .UInt => |val| return val,
            .Int => |val| {
                if (val < 0) {
                    return Error.UnexpectedTagError;
                }
                return @intCast(val);
            },
            else => return Error.UnexpectedTagError,
        }
    }

    pub fn expectString(self: *Self) Error![]u8 {
        const size = switch (try self.readHead()) {
            .Str => |size| size,
            .Bin => |size| size,
            else => return Error.UnexpectedTagError,
        };
        while (self.data.len < size) {
            try self.getMoreData();
        }

        const str = self.data[0..size];
        self.data = self.data[size..];
        self.bytes -= size;
        return str;
    }

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

    pub fn skipAhead(self: *Self, skipped: usize) Error!void {
        var items: usize = skipped;
        if (self.bytes > 0 or skipped > self.items) {
            return error.InvalidDecodeOperation;
        }

        while (self.bytes > 0 or items > 0) {
            if (self.bytes > 0) {
                if (self.data.len == 0) {
                    try self.getMoreData();
                }
                const skip = std.math.min(self.bytes, self.data.len);
                self.data = self.data[skip..];
                self.bytes -= skip;
            } else if (items > 0) {
                const head = try self.readHead();
                items -= 1;
                const size = itemSize(head);
                items += size.items;
            }
        }
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

    var decoder = Decoder{ .data = x.items };
    try testing.expectEqual(ValueHead{ .Array = 4 }, try decoder.readHead());
    try testing.expectEqual(ValueHead{ .Int = 4 }, try decoder.readHead());
    try testing.expectEqual(ValueHead{ .Int = 200 }, try decoder.readHead());
}
