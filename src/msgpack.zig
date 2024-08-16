const std = @import("std");
const ArrayList = std.ArrayList;

pub const Value = union(enum) {
    Uint8: u8,
    Uint16: u16,
    Uint32: u32,
    Uint64: u64,

    Int8: i8,
    Int16: i16,
    Int32: i32,
    Int64: i64,

    Float32: f32,
    Float64: f64,

    Null,

    Bool: bool,
    String: []const u8,

    Array: []const Value,

    Map: *const std.StringHashMap(Value),
};

pub fn toVal(thing: anytype, comptime T_opt: ?type) Value {
    const T = T_opt orelse @TypeOf(thing);
    return switch (T) {
        u8 => Value{ .Uint8 = thing },
        u16 => Value{ .Uint16 = thing },
        u32 => Value{ .Uint32 = thing },
        u64 => Value{ .Uint64 = thing },
        i8 => Value{ .Int8 = thing },
        i16 => Value{ .Int16 = thing },
        i32 => Value{ .Int32 = thing },
        i64 => Value{ .Int64 = thing },
        f32 => Value{ .Float32 = thing },
        f64 => Value{ .Float64 = thing },
        bool => Value{ .Bool = thing },
        []const u8 => Value{ .String = thing },
        []const Value => Value{ .Array = thing },
        std.StringHashMap(Value) => Value{ .Map = &thing },
        @TypeOf(null) => Value{ .Null = {} },
        else => @compileLog("Can't serialize type ", thing, " to msgpack."),
    };
}

pub fn serializeAndAppend(array: *ArrayList(u8), val: Value) anyerror!void {
    switch (val) {
        Value.Null => try array.*.append(0xc0),
        Value.Int8 => |x| {
            if (!(x >= -32)) {
                // Not a fixint, so add start for serializing an int8
                try array.*.append(0xd0);
            }

            try array.*.append(@intCast(u8, @as(i16, x) & 0xFF));
        },
        Value.Int16 => |x| {
            try array.*.append(0xd1);

            try array.*.append(@intCast(u8, (x >> 8) & 0xFF));
            try array.*.append(@intCast(u8, x & 0xFF));
        },
        Value.Int32 => |x| {
            try array.*.append(0xd2);

            try array.*.append(@intCast(u8, (x >> 24) & 0xFF));
            try array.*.append(@intCast(u8, (x >> 16) & 0xFF));
            try array.*.append(@intCast(u8, (x >> 8) & 0xFF));
            try array.*.append(@intCast(u8, x & 0xFF));
        },
        Value.Int64 => |x| {
            try array.*.append(0xd3);

            try array.*.append(@intCast(u8, (x >> 56) & 0xFF));
            try array.*.append(@intCast(u8, (x >> 48) & 0xFF));
            try array.*.append(@intCast(u8, (x >> 40) & 0xFF));
            try array.*.append(@intCast(u8, (x >> 32) & 0xFF));
            try array.*.append(@intCast(u8, (x >> 24) & 0xFF));
            try array.*.append(@intCast(u8, (x >> 16) & 0xFF));
            try array.*.append(@intCast(u8, (x >> 8) & 0xFF));
            try array.*.append(@intCast(u8, x & 0xFF));
        },
        Value.Uint8 => |x| {
            try array.*.append(0xcc);
            try array.*.append(@intCast(u8, @as(i16, x) & 0xFF));
        },
        Value.Uint16 => |x| {
            try array.*.append(0xcd);

            try array.*.append(@intCast(u8, (x >> 8) & 0xFF));
            try array.*.append(@intCast(u8, x & 0xFF));
        },
        Value.Uint32 => |x| {
            try array.*.append(0xce);

            try array.*.append(@intCast(u8, (x >> 24) & 0xFF));
            try array.*.append(@intCast(u8, (x >> 16) & 0xFF));
            try array.*.append(@intCast(u8, (x >> 8) & 0xFF));
            try array.*.append(@intCast(u8, x & 0xFF));
        },
        Value.Uint64 => |x| {
            try array.*.append(0xcf);

            try array.*.append(@intCast(u8, (x >> 56) & 0xFF));
            try array.*.append(@intCast(u8, (x >> 48) & 0xFF));
            try array.*.append(@intCast(u8, (x >> 40) & 0xFF));
            try array.*.append(@intCast(u8, (x >> 32) & 0xFF));
            try array.*.append(@intCast(u8, (x >> 24) & 0xFF));
            try array.*.append(@intCast(u8, (x >> 16) & 0xFF));
            try array.*.append(@intCast(u8, (x >> 8) & 0xFF));
            try array.*.append(@intCast(u8, x & 0xFF));
        },
        Value.Bool => |x| {
            if (x) {
                try array.*.append(0xc3);
            } else {
                try array.*.append(0xc2);
            }
        },
        Value.Float32 => |x| {
            try array.*.append(0xca);

            const x_u32 = @bitCast(u32, x);
            try array.*.append(@intCast(u8, (x_u32 >> 24) & 0xFF));
            try array.*.append(@intCast(u8, (x_u32 >> 16) & 0xFF));
            try array.*.append(@intCast(u8, (x_u32 >> 8) & 0xFF));
            try array.*.append(@intCast(u8, x_u32 & 0xFF));
        },
        Value.Float64 => |x| {
            try array.*.append(0xcb);

            const x_u64 = @bitCast(u64, x);
            try array.*.append(@intCast(u8, (x_u64 >> 56) & 0xFF));
            try array.*.append(@intCast(u8, (x_u64 >> 48) & 0xFF));
            try array.*.append(@intCast(u8, (x_u64 >> 40) & 0xFF));
            try array.*.append(@intCast(u8, (x_u64 >> 32) & 0xFF));
            try array.*.append(@intCast(u8, (x_u64 >> 24) & 0xFF));
            try array.*.append(@intCast(u8, (x_u64 >> 16) & 0xFF));
            try array.*.append(@intCast(u8, (x_u64 >> 8) & 0xFF));
            try array.*.append(@intCast(u8, x_u64 & 0xFF));
        },
        Value.String => |x| {
            if (x.len < 31) {
                // fixstr
                try array.*.append(0xa0 | @intCast(u8, x.len));
            } else if (x.len <= std.math.maxInt(u8)) {
                // str8
                try array.*.append(0xd9);
                try array.*.append(@intCast(u8, x.len));
            } else if (x.len <= std.math.maxInt(u16)) {
                // str16
                try array.*.append(0xda);

                try array.*.append(@intCast(u8, (x.len >> 8) & 0xFF));
                try array.*.append(@intCast(u8, x.len & 0xFF));
            } else {
                // assume str32
                try array.*.append(0xdb);

                try array.*.append(@intCast(u8, (x.len >> 24) & 0xFF));
                try array.*.append(@intCast(u8, (x.len >> 16) & 0xFF));
                try array.*.append(@intCast(u8, (x.len >> 8) & 0xFF));
                try array.*.append(@intCast(u8, x.len & 0xFF));
            }

            for (x) |byte| {
                try array.*.append(byte);
            }
        },
        Value.Array => |xs| {
            try startArray(array, xs.len);
            for (xs) |x| {
                try serializeAndAppend(array, x);
            }
        },
        Value.Map => |map| {
            var iterator = map.*.iterator();

            try startMap(array, map.*.count());
            while (iterator.next()) |x| {
                try serializeAndAppend(array, toVal(x.key, null));
                try serializeAndAppend(array, x.value);
            }
        },
    }
}

fn startArray(array: *ArrayList(u8), count: u64) !void {
    if (count <= 15) {
        try array.*.append(0x90 | @intCast(u8, count));
    } else if (count <= std.math.maxInt(u16)) {
        try array.*.append(0xdc);
        try array.*.append(@intCast(u8, (@intCast(u16, count) >> 8) & 0xFF));
        try array.*.append(@intCast(u8, count & 0xFF));
    } else {
        try array.*.append(0xdd);

        try array.*.append(@intCast(u8, (count >> 24) & 0xFF));
        try array.*.append(@intCast(u8, (count >> 16) & 0xFF));
        try array.*.append(@intCast(u8, (count >> 8) & 0xFF));
        try array.*.append(@intCast(u8, count & 0xFF));
    }
}

pub fn serializeList(allocator: *std.mem.Allocator, values: []const Value) !ArrayList(u8) {
    var item_list = ArrayList(u8).init(allocator);
    errdefer item_list.deinit();

    try startArray(&item_list, values.len);
    for (values) |val| {
        try serializeAndAppend(&item_list, val);
    }

    return item_list;
}

pub fn startMap(array: *ArrayList(u8), count: u64) !void {
    if (count <= 15) {
        try array.*.append(0x80 | @intCast(u8, count));
    } else if (count <= std.math.maxInt(u16)) {
        try array.*.append(0xde);

        try array.*.append(@intCast(u8, (@intCast(u16, count) >> 8) & 0xFF));
        try array.*.append(@intCast(u8, count & 0xFF));
    } else {
        try array.*.append(0xdf);

        try array.*.append(@intCast(u8, (count >> 24) & 0xFF));
        try array.*.append(@intCast(u8, (count >> 16) & 0xFF));
        try array.*.append(@intCast(u8, (count >> 8) & 0xFF));
        try array.*.append(@intCast(u8, count & 0xFF));
    }
}

fn deserializeSomething16(comptime T: type, bytes: []const u8) Value {
    return toVal(@as(T, bytes[0]) << 8 |
        @as(T, bytes[1]), T);
}

fn deserializeSomething32(comptime T: type, bytes: []const u8) Value {
    return toVal(@as(T, bytes[0]) << 24 |
        @as(T, bytes[1]) << 16 |
        @as(T, bytes[2]) << 8 |
        @as(T, bytes[3]), T);
}

fn deserializeSomething64(comptime T: type, bytes: []const u8) Value {
    return toVal(@as(T, bytes[0]) << 56 |
        @as(T, bytes[1]) << 48 |
        @as(T, bytes[2]) << 40 |
        @as(T, bytes[3]) << 32 |
        @as(T, bytes[4]) << 24 |
        @as(T, bytes[5]) << 16 |
        @as(T, bytes[6]) << 8 |
        @as(T, bytes[7]), T);
}

const DeserializeRet = struct {
    deserialized: Value,
    new_bytes: ?[]const u8,
};

// TODO(smolck): Maybe make allocator more general (or not explicitly an
// ArenaAllocator)? Needs to be an ArenaAllocator though basically, because
// otherwise there will be memory leaks from nested values not getting freed
// (or any values for that matter).
//
// Also, yes, this could probably be better than having a `deserializePrivate`
// and `deserialize` and all of this. But hey, it seems to work, so . . .
fn deserializePrivate(allocator: *std.heap.ArenaAllocator, bytes: []const u8) anyerror!DeserializeRet {
    const starting_byte = bytes[0];

    if ((starting_byte & 0xE0) == 0xA0) {
        // Fixstr
        const len = starting_byte & 0x1F;
        return DeserializeRet{
            .deserialized = toVal(bytes[1 .. len + 1], []const u8),
            .new_bytes = bytes[len + 1 .. bytes.len],
        };
    } else if ((starting_byte & 0xF0) == 0x90) {
        // Fixarray
        const len = starting_byte & 0xF;
        var values = try ArrayList(Value).initCapacity(&allocator.*.allocator, len);
        var new_bytes = bytes[1..bytes.len];

        var i: usize = 0;
        while (i < len) : (i += 1) {
            const d = try deserializePrivate(allocator, new_bytes);
            try values.append(d.deserialized);
            new_bytes = d.new_bytes.?;
        }

        return DeserializeRet{
            .deserialized = toVal(values.toOwnedSlice(), []const Value),
            .new_bytes = bytes[len + 1 .. bytes.len],
        };
    } else if ((starting_byte & 0xE0) == 0xE0) {
        // Negative fixnum
        return DeserializeRet{
            .deserialized = toVal(@intCast(i8, @intCast(i16, starting_byte) - 256), i8),
            .new_bytes = bytes[1..bytes.len],
        };
    } else if (starting_byte <= std.math.maxInt(i8)) {
        // Positive fixnum
        return DeserializeRet{
            .deserialized = toVal(@bitCast(i8, starting_byte), i8),
            .new_bytes = bytes[1..bytes.len],
        };
    }

    switch (starting_byte) {
        0xcc, // Uint8
        0xd0, // Int8
        => return DeserializeRet{
            .deserialized = if (starting_byte == 0xcc)
                toVal(bytes[1], u8)
            else
                toVal(@bitCast(i8, bytes[1]), i8),
            .new_bytes = bytes[2..bytes.len],
        },
        0xcd, // Uint16
        0xd1, // Int16
        => return DeserializeRet{
            .deserialized = if (starting_byte == 0xcd)
                deserializeSomething16(u16, bytes[1..3])
            else
                deserializeSomething16(i16, bytes[1..3]),
            .new_bytes = bytes[3..bytes.len],
        },
        0xce, // Uint32
        0xd2, // Int32
        => return DeserializeRet{
            .deserialized = if (starting_byte == 0xce)
                deserializeSomething32(u32, bytes[1..5])
            else
                deserializeSomething32(i32, bytes[1..5]),
            .new_bytes = bytes[5..bytes.len],
        },
        0xcf, // Uint64
        0xd3, // Int64
        => return DeserializeRet{
            .deserialized = if (starting_byte == 0xcf)
                deserializeSomething64(u64, bytes[1..9])
            else
                deserializeSomething64(i64, bytes[1..9]),
            .new_bytes = bytes[9..bytes.len],
        },
        0xca =>
        // Float32
        return DeserializeRet{
            .deserialized = Value{ .Float32 = @bitCast(f32, deserializeSomething32(u32, bytes[1..5]).Uint32) },
            .new_bytes = bytes[5..bytes.len],
        },
        0xcb =>
        // Float64
        return DeserializeRet{
            .deserialized = Value{ .Float64 = @bitCast(f64, deserializeSomething64(u64, bytes[1..9]).Uint64) },
            .new_bytes = bytes[9..bytes.len],
        },
        0xdc => {
            // Array16
            var len: usize = deserializeSomething16(u16, bytes[1..3]).Uint16;
            var values = try ArrayList(Value).initCapacity(&allocator.*.allocator, len);
            var new_bytes = bytes[3 .. len + 3];

            var i: usize = 0;
            while (i < len) : (i += 1) {
                const d = try deserializePrivate(allocator, new_bytes);
                try values.append(d.deserialized);
                new_bytes = d.new_bytes.?;
            }

            return DeserializeRet{
                .deserialized = toVal(values.toOwnedSlice(), []const Value),
                .new_bytes = null,
            };
        },
        0xdd => {
            // Array32
            var len: usize = deserializeSomething32(u32, bytes[1..5]).Uint32;
            var values = try ArrayList(Value).initCapacity(&allocator.*.allocator, len);
            var new_bytes = bytes[5 .. len + 5];

            var i: usize = 0;
            while (i < len) : (i += 1) {
                const d = try deserializePrivate(allocator, new_bytes);
                try values.append(d.deserialized);
                new_bytes = d.new_bytes.?;
            }

            return DeserializeRet{
                .deserialized = toVal(values.toOwnedSlice(), []const Value),
                .new_bytes = null,
            };
        },
        else => return DeserializeRet{ .deserialized = Value{ .Null = {} }, .new_bytes = null },
    }
}

pub fn deserialize(allocator: *std.heap.ArenaAllocator, bytes: []const u8) anyerror!Value {
    return (try deserializePrivate(allocator, bytes)).deserialized;
}
