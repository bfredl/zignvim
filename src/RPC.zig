const std = @import("std");
const mpack = @import("./mpack.zig");
const ArrayList = std.ArrayList;
const mem = std.mem;
const stringToEnum = std.meta.stringToEnum;

const dbg = std.debug.print;
//pub fn dbg(a: anytype, b: anytype) void {}

const AttrOffset = struct { start: u32, end: u32 };
attr_arena: ArrayList(u8),
attr_off: ArrayList(AttrOffset),
writer: @TypeOf(std.io.getStdOut().writer()),

hl_id: u32,

const Self = @This();

pub fn init(allocator: *mem.Allocator) Self {
    return .{
        .attr_arena = ArrayList(u8).init(allocator),
        .attr_off = ArrayList(AttrOffset).init(allocator),
        .hl_id = 0,
        .writer = std.io.getStdOut().writer(),
    };
}

pub const RPCError = mpack.Decoder.Error || error{
    MalformatedRPCMessage,
    InvalidRedraw,
    OutOfMemory,
    IOError,
};

pub fn decodeLoop(self: *Self, decoder: *mpack.Decoder) RPCError!void {
    while (true) {
        try decoder.start();
        var msgHead = try decoder.expectArray();
        if (msgHead < 3) {
            return RPCError.MalformatedRPCMessage;
        }

        var msgKind = try decoder.expectUInt();
        switch (msgKind) {
            1 => try self.decodeResponse(decoder, msgHead),
            2 => try self.decodeEvent(decoder, msgHead),
            else => return error.MalformatedRPCMessage,
        }
    }
}

fn decodeResponse(self: *Self, decoder: *mpack.Decoder, arraySize: u32) RPCError!void {
    _ = self;
    if (arraySize != 4) {
        return error.MalformatedRPCMessage;
    }
    var id = try decoder.expectUInt();
    dbg("id: {}\n", .{id});
    var state = try decoder.readHead();
    dbg("{}\n", .{state});
    state = try decoder.readHead();
    dbg("{}\n", .{state});
}

fn decodeEvent(self: *Self, decoder: *mpack.Decoder, arraySize: u32) RPCError!void {
    if (arraySize != 3) {
        return error.MalformatedRPCMessage;
    }
    var name = try decoder.expectString();
    if (mem.eql(u8, name, "redraw")) {
        try self.handleRedraw(decoder);
    } else {
        // TODO: untested
        dbg("FEEEEL: {s}\n", .{name});
        try decoder.skipAhead(1); // args array
    }
}

const RedrawEvents = enum {
    hl_attr_define,
    hl_group_set,
    grid_line,
    flush,
    Unknown,
};

fn handleRedraw(self: *Self, decoder: *mpack.Decoder) RPCError!void {
    dbg("==BEGIN REDRAW\n", .{});
    var args = try decoder.expectArray();
    dbg("n-event: {}\n", .{args});
    while (args > 0) : (args -= 1) {
        const saved = try decoder.push();
        const iargs = try decoder.expectArray();
        const iname = try decoder.expectString();
        const event = stringToEnum(RedrawEvents, iname) orelse .Unknown;
        switch (event) {
            .grid_line => try self.handleGridLine(decoder, iargs - 1),
            .flush => {
                //if (iargs != 2 or try decoder.expectArray() > 0) {
                //    return error.InvalidRedraw;
                // }
                try decoder.skipAhead(iargs - 1);

                dbg("==FLUSHED\n", .{});
                //std.time.sleep(1000 * 1000000);
            },
            .hl_attr_define => {
                try self.handleHlAttrDef(decoder, iargs - 1);
            },
            .hl_group_set => {
                try decoder.skipAhead(iargs - 1);
            },
            .Unknown => {
                dbg("! {s} {}\n", .{ iname, iargs - 1 });
                try decoder.skipAhead(iargs - 1);
            },
        }
        try decoder.pop(saved);
    }
    dbg("==DUN REDRAW\n\n", .{});
}

fn handleGridLine(self: *Self, decoder: *mpack.Decoder, nlines: u32) RPCError!void {
    dbg("==LINES {}\n", .{nlines});
    var i: u32 = 0;
    while (i < nlines) : (i += 1) {
        const saved = try decoder.push();
        const iytem = try decoder.expectArray();
        const grid = try decoder.expectUInt();
        const row = try decoder.expectUInt();
        const col = try decoder.expectUInt();
        const ncells = try decoder.expectArray();
        dbg("LINE: {} {} {} {}: [", .{ grid, row, col, ncells });
        self.writer.print("\x1b[{};{}H", .{ row, col }) catch return RPCError.IOError;
        var j: u32 = 0;
        while (j < ncells) : (j += 1) {
            const nsize = try decoder.expectArray();
            const str = try decoder.expectString();
            var used: u8 = 1;
            var repeat: u64 = 1;
            var hl_id: u32 = self.hl_id;

            if (nsize >= 2) {
                hl_id = @intCast(u32, try decoder.expectUInt());
                used = 2;
                if (nsize >= 3) {
                    repeat = try decoder.expectUInt();
                    used = 3;
                }
            }
            if (hl_id != self.hl_id) {
                self.hl_id = hl_id;
                const slice = if (hl_id > 0) theslice: {
                    const islice = self.attr_off.items[hl_id];
                    break :theslice self.attr_arena.items[islice.start..islice.end];
                } else "\x1b[0m";
                self.writer.writeAll(slice) catch return RPCError.IOError;
            }
            while (repeat > 0) : (repeat -= 1) {
                dbg("{s}", .{str});
                self.writer.writeAll(str) catch return RPCError.IOError;
            }
            try decoder.skipAhead(nsize - used);
        }
        dbg("]\n", .{});

        try decoder.skipAhead(iytem - 4);

        try decoder.pop(saved);
    }
}

//const native_endian = std.Target.current.cpu.arch.endian();
const RGB = struct { b: u8, g: u8, r: u8, a: u8 };

fn doColors(w: anytype, fg: bool, rgb: RGB) RPCError!void {
    const kod = if (fg) "3" else "4";
    try w.print("\x1b[{s}8;2;{};{};{}m", .{ kod, rgb.r, rgb.g, rgb.b });
}

fn handleHlAttrDef(self: *Self, decoder: *mpack.Decoder, nattrs: u32) RPCError!void {
    dbg("==ATTRS {}\n", .{nattrs});
    var i: u32 = 0;
    while (i < nattrs) : (i += 1) {
        const saved = try decoder.push();
        const nsize = try decoder.expectArray();
        const id = try decoder.expectUInt();
        const rgb_attrs = try decoder.expectMap();
        //dbg("ATTEN: {} {}", .{ id, rgb_attrs });
        var j: u32 = 0;
        while (j < rgb_attrs) : (j += 1) {
            const name = try decoder.expectString();
            const Keys = enum { foreground, background, bold, Unknown };
            const key = stringToEnum(Keys, name) orelse .Unknown;
            var fg: ?u32 = null;
            var bg: ?u32 = null;
            var bold = false;
            switch (key) {
                .foreground => {
                    const num = try decoder.expectUInt();
                    dbg(" fg={}", .{num});
                    fg = @intCast(u32, num);
                },
                .background => {
                    const num = try decoder.expectUInt();
                    dbg(" bg={}", .{num});
                    bg = @intCast(u32, num);
                },
                .bold => {
                    _ = try decoder.readHead();
                    dbg(" BOLDEN", .{});
                    bold = true;
                },
                .Unknown => {
                    dbg(" {s}", .{name});
                    try decoder.skipAhead(1);
                },
            }
            const pos = @intCast(u32, self.attr_arena.items.len);
            const w = self.attr_arena.writer();
            try w.writeAll("\x1b[0m");
            if (fg) |the_fg| {
                const rgb = @bitCast(RGB, the_fg);
                try doColors(w, true, rgb);
            }
            if (bg) |the_bg| {
                const rgb = @bitCast(RGB, the_bg);
                try doColors(w, false, rgb);
            }
            if (bold) {
                try w.writeAll("\x1b[1m");
            }
            const endpos = @intCast(u32, self.attr_arena.items.len);
            try putAt(&self.attr_off, id, .{ .start = pos, .end = endpos });
        }
        dbg("\n", .{});

        try decoder.skipAhead(nsize - 2);
        try decoder.pop(saved);
    }
}

fn putAt(array_list: anytype, index: usize, item: anytype) !void {
    if (array_list.items.len < index + 1) {
        try array_list.resize(index + 1);
    }
    array_list.items[index] = item;
}
