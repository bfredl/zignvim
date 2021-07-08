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

cursor: struct { grid: u32, row: u16, col: u16 } = undefined,

grid: [1]Grid,

attr_id: u16 = 0,

const Self = @This();

const Grid = struct {
    rows: u16,
    cols: u16,
    cell: ArrayList(Cell),
};

const charsize = 8;

const Cell = struct {
    char: [charsize]u8,
    attr_id: u16,
};

pub fn init(allocator: *mem.Allocator) Self {
    return .{
        .attr_arena = ArrayList(u8).init(allocator),
        .attr_off = ArrayList(AttrOffset).init(allocator),
        .writer = std.io.getStdOut().writer(),
        .grid = .{.{ .rows = 0, .cols = 0, .cell = ArrayList(Cell).init(allocator) }},
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
    grid_resize,
    grid_clear,
    grid_line,
    grid_cursor_goto,
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
        var iiarg: u32 = 1;
        switch (event) {
            .grid_resize => {
                while (iiarg < iargs) : (iiarg += 1) {
                    try self.handleGridResize(decoder);
                }
            },
            .grid_clear => {
                while (iiarg < iargs) : (iiarg += 1) {
                    try self.handleGridClear(decoder);
                }
            },
            .grid_line => try self.handleGridLine(decoder, iargs - 1),
            .flush => {
                //if (iargs != 2 or try decoder.expectArray() > 0) {
                //    return error.InvalidRedraw;
                // }
                try decoder.skipAhead(iargs - 1);

                dbg("==FLUSHED\n", .{});
                try self.dumpGrid();
                const c = self.cursor;
                self.writer.print("\x1b[{};{}H", .{ c.row + 1, c.col + 1 }) catch return RPCError.IOError;
                //std.time.sleep(1000 * 1000000);
            },
            .hl_attr_define => {
                try self.handleHlAttrDef(decoder, iargs - 1);
            },
            .grid_cursor_goto => {
                try decoder.skipAhead(iargs - 2);
                try self.handleCursorGoto(decoder);
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

fn handleGridResize(self: *Self, decoder: *mpack.Decoder) RPCError!void {
    const saved = try decoder.push();
    const iarg = try decoder.expectArray();
    const grid_id = try decoder.expectUInt();
    if (grid_id != 1) {
        @panic("get out!");
    }

    const grid = &self.grid[grid_id - 1];
    grid.cols = @intCast(u16, try decoder.expectUInt());
    grid.rows = @intCast(u16, try decoder.expectUInt());

    try grid.cell.resize(grid.rows * grid.cols);

    try decoder.skipAhead(iarg - 3);
    try decoder.pop(saved);
}

fn handleGridClear(self: *Self, decoder: *mpack.Decoder) RPCError!void {
    const saved = try decoder.push();
    const iarg = try decoder.expectArray();
    const grid_id = try decoder.expectUInt();
    const grid = &self.grid[grid_id - 1];

    var char: [charsize]u8 = undefined;
    //char[0..2] = .{ ' ', 0 };
    char[0] = ' ';
    char[1] = 0;

    mem.set(Cell, grid.cell.items, .{ .char = char, .attr_id = 0 });

    try decoder.skipAhead(iarg - 1);
    try decoder.pop(saved);
}

fn handleGridLine(self: *Self, decoder: *mpack.Decoder, nlines: u32) RPCError!void {
    // dbg("==LINES {}\n", .{nlines});
    var i: u32 = 0;
    while (i < nlines) : (i += 1) {
        const saved = try decoder.push();
        const iytem = try decoder.expectArray();
        const grid_id = try decoder.expectUInt();
        const grid = &self.grid[grid_id - 1];
        const row = try decoder.expectUInt();
        const col = try decoder.expectUInt();
        const ncells = try decoder.expectArray();
        var pos = row * grid.cols + col;
        //dbg("LINE: {} {} {} {}: [", .{ grid_id, row, col, ncells });
        //self.writer.print("\x1b[{};{}H", .{ row + 1, col + 1 }) catch return RPCError.IOError;
        var j: u32 = 0;
        while (j < ncells) : (j += 1) {
            const nsize = try decoder.expectArray();
            const str = try decoder.expectString();
            var used: u8 = 1;
            var repeat: u64 = 1;
            var attr_id: u16 = self.attr_id;

            var char: [charsize]u8 = undefined;
            mem.copy(u8, &char, str);
            if (str.len < 8) {
                char[str.len] = 0;
            }

            if (nsize >= 2) {
                attr_id = @intCast(u16, try decoder.expectUInt());
                used = 2;
                if (nsize >= 3) {
                    repeat = try decoder.expectUInt();
                    used = 3;
                }
            }
            if (attr_id != self.attr_id) {
                self.attr_id = attr_id;
                const slice = if (attr_id > 0) theslice: {
                    const islice = self.attr_off.items[attr_id];
                    //dbg("without chemicals {} he points {} {}", .{ attr_id, islice.start, islice.end });
                    break :theslice self.attr_arena.items[islice.start..islice.end];
                } else "\x1b[0m";
                _ = slice;
                // self.writer.writeAll(slice) catch return RPCError.IOError;
            }
            while (repeat > 0) : (repeat -= 1) {
                grid.cell.items[pos] = .{ .char = char, .attr_id = attr_id };
                pos = pos + 1;
                //dbg("{s}", .{str});
                // self.writer.writeAll(str) catch return RPCError.IOError;
            }
            try decoder.skipAhead(nsize - used);
        }
        //dbg("]\n", .{});

        try decoder.skipAhead(iytem - 4);

        try decoder.pop(saved);
    }
}

fn dumpGrid(self: *Self) RPCError!void {
    self.writer.print("\x1b[H", .{}) catch return RPCError.IOError;
    const grid = &self.grid[0];
    var row: u16 = 0;
    var attr_id: u16 = 0;
    while (row < grid.rows) : (row += 1) {
        if (row > 1) {
            self.writer.writeAll("\r\n") catch return RPCError.IOError;
        }
        const o = row * grid.cols;
        var col: u16 = 0;
        while (col < grid.cols) : (col += 1) {
            const c = grid.cell.items[o + col];
            var len = mem.indexOfScalar(u8, &c.char, 0) orelse charsize;
            if (c.attr_id != attr_id) {
                attr_id = c.attr_id;
                const slice = if (attr_id > 0) theslice: {
                    const islice = self.attr_off.items[attr_id];
                    //dbg("without chemicals {} he points {} {}", .{ attr_id, islice.start, islice.end });
                    break :theslice self.attr_arena.items[islice.start..islice.end];
                } else "\x1b[0m";
                self.writer.writeAll(slice) catch return RPCError.IOError;
            }
            self.writer.writeAll(c.char[0..len]) catch return RPCError.IOError;
        }
    }
}

//const native_endian = std.Target.current.cpu.arch.endian();
const RGB = struct { b: u8, g: u8, r: u8, a: u8 };

fn doColors(w: anytype, fg: bool, rgb: RGB) RPCError!void {
    const kod = if (fg) "3" else "4";
    try w.print("\x1b[{s}8;2;{};{};{}m", .{ kod, rgb.r, rgb.g, rgb.b });
}

fn handleHlAttrDef(self: *Self, decoder: *mpack.Decoder, nattrs: u32) RPCError!void {
    // dbg("==ATTRS {}\n", .{nattrs});
    var i: u32 = 0;
    while (i < nattrs) : (i += 1) {
        const saved = try decoder.push();
        const nsize = try decoder.expectArray();
        const id = try decoder.expectUInt();
        const rgb_attrs = try decoder.expectMap();
        //dbg("ATTEN: {} {}", .{ id, rgb_attrs });
        var fg: ?u32 = null;
        var bg: ?u32 = null;
        var bold = false;
        var j: u32 = 0;
        while (j < rgb_attrs) : (j += 1) {
            const name = try decoder.expectString();
            const Keys = enum { foreground, background, bold, Unknown };
            const key = stringToEnum(Keys, name) orelse .Unknown;
            switch (key) {
                .foreground => {
                    const num = try decoder.expectUInt();
                    //dbg(" fg={}", .{num});
                    fg = @intCast(u32, num);
                },
                .background => {
                    const num = try decoder.expectUInt();
                    //dbg(" bg={}", .{num});
                    bg = @intCast(u32, num);
                },
                .bold => {
                    _ = try decoder.readHead();
                    //dbg(" BOLDEN", .{});
                    bold = true;
                },
                .Unknown => {
                    //dbg(" {s}", .{name});
                    try decoder.skipAhead(1);
                },
            }
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
        //dbg("\n", .{});

        try decoder.skipAhead(nsize - 2);
        try decoder.pop(saved);
    }
}

fn handleCursorGoto(self: *Self, decoder: *mpack.Decoder) RPCError!void {
    const nsize = try decoder.expectArray();
    const grid = @intCast(u32, try decoder.expectUInt());
    const row = @intCast(u16, try decoder.expectUInt());
    const col = @intCast(u16, try decoder.expectUInt());
    try decoder.skipAhead(nsize - 3);
    self.cursor = .{ .grid = grid, .row = row, .col = col };
}
fn putAt(array_list: anytype, index: usize, item: anytype) !void {
    if (array_list.items.len < index + 1) {
        try array_list.resize(index + 1);
    }
    array_list.items[index] = item;
}
