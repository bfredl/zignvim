const std = @import("std");
const mpack = @import("./mpack.zig");
const ArrayList = std.ArrayList;
const mem = std.mem;
const stringToEnum = std.meta.stringToEnum;
const Self = @This();
const dbg = std.debug.print;

const State = enum {
    next_msg,
    redraw_event,
    redraw_call,
    next_cell,
};

state: State = .next_msg,
event: RedrawEvents = undefined,

redraw_events: u64 = 0,
event_calls: u64 = 0,

ui: struct {
    attr_arena: ArrayList(u8),
    attr_off: ArrayList(AttrOffset),
    writer: @TypeOf(std.io.getStdOut().writer()),

    cursor: struct { grid: u32, row: u16, col: u16 } = undefined,
    default_colors: struct { fg: u32, bg: u32, sp: u32 } = undefined,

    grid: [1]Grid,

    attr_id: u16 = 0,
},

const AttrOffset = struct { start: u32, end: u32 };
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

const RGB = packed struct { b: u8, g: u8, r: u8, a: u8 };

fn doColors(w: anytype, fg: bool, rgb: RGB) !void {
    const kod = if (fg) "3" else "4";
    try w.print("\x1b[{s}8;2;{};{};{}m", .{ kod, rgb.r, rgb.g, rgb.b });
}

fn putAt(array_list: anytype, index: usize, item: anytype) !void {
    if (array_list.items.len < index + 1) {
        try array_list.resize(index + 1);
    }
    array_list.items[index] = item;
}

pub fn init(allocator: mem.Allocator) Self {
    return .{
        .ui = .{
            .attr_arena = ArrayList(u8).init(allocator),
            .attr_off = ArrayList(AttrOffset).init(allocator),
            .writer = std.io.getStdOut().writer(),
            .grid = .{.{ .rows = 0, .cols = 0, .cell = ArrayList(Cell).init(allocator) }},
        },
    };
}

pub fn process(self: *Self, decoder: *mpack.SkipDecoder) !void {
    std.debug.print("haii {}\n", .{decoder.data.len});

    while (true) {
        // too little data
        if (!try decoder.skipData()) return;

        const res = try switch (self.state) {
            .next_msg => self.next_msg(decoder),
            .redraw_event => self.redraw_event(decoder),
            .redraw_call => self.redraw_call(decoder),
        };

        self.state = res orelse return;
    }
    // TODO: EAGAIN!
}

fn next_msg(self: *Self, base_decoder: *mpack.SkipDecoder) !?State {
    var decoder = try base_decoder.inner();
    const tok = try decoder.expectArray() orelse return null;
    if (tok < 3) return error.MalformatedRPCMessage;
    const num = try decoder.expectUInt() orelse return null;
    if (num != 2) @panic("handle replies and requests");
    if (tok != 3) return error.MalformatedRPCMessage;

    const name = try decoder.expectString() orelse return null;

    if (!std.mem.eql(u8, name, "redraw")) @panic("handle notifications other than 'redraw'");

    self.redraw_events = try decoder.expectArray() orelse return null;
    base_decoder.consumed(decoder);
    return .redraw_event;
}

const RedrawEvents = enum {
    hl_attr_define,
    grid_resize,
    grid_line,
};

fn redraw_event(self: *Self, base_decoder: *mpack.SkipDecoder) !?State {
    if (self.redraw_events == 0) {
        return .next_msg;
    }

    var decoder = try base_decoder.inner();
    const nitems = try decoder.expectArray() orelse return null;
    if (nitems < 1) return error.MalformatedRPCMessage;
    const name = try decoder.expectString() orelse return null;

    dbg("EVENT: '{s}' with {}\n", .{ name, nitems - 1 });

    base_decoder.consumed(decoder);
    self.redraw_events -= 1;

    const event = stringToEnum(RedrawEvents, name) orelse {
        base_decoder.toSkip(nitems - 1);
        return .redraw_event;
    };

    self.event_calls = nitems - 1;
    self.event = event;
    return .redraw_call;
}

fn redraw_call(self: *Self, base_decoder: *mpack.SkipDecoder) !?State {
    if (self.event_calls == 0) {
        return .redraw_event;
    }
    const status = switch (self.event) {
        .hl_attr_define => try self.hl_attr_define(base_decoder),
        .grid_resize => try self.grid_resize(base_decoder),
        .grid_line => try self.grid_line(base_decoder),
    };

    if (status) |next| {
        self.event_calls -= 1;
        return next;
    } else {
        return null;
    }
}

fn hl_attr_define(self: *Self, base_decoder: *mpack.SkipDecoder) !?State {
    var decoder = try base_decoder.inner();

    const nsize = try decoder.expectArray() orelse return null;
    const id = try decoder.expectUInt() orelse return null;
    const rgb_attrs = try decoder.expectMap() orelse return null;
    dbg("ATTEN: {} {}", .{ id, rgb_attrs });
    var fg: ?u32 = null;
    var bg: ?u32 = null;
    var bold = false;
    var j: u32 = 0;
    while (j < rgb_attrs) : (j += 1) {
        const name = try decoder.expectString() orelse return null;
        const Keys = enum { foreground, background, bold, Unknown };
        const key = stringToEnum(Keys, name) orelse .Unknown;
        switch (key) {
            .foreground => {
                const num = try decoder.expectUInt() orelse return null;
                dbg(" fg={}", .{num});
                fg = @intCast(num);
            },
            .background => {
                const num = try decoder.expectUInt() orelse return null;
                dbg(" bg={}", .{num});
                bg = @intCast(num);
            },
            .bold => {
                // TODO: expectBööööl
                _ = try decoder.readHead() orelse return null;
                dbg(" BOLDEN", .{});
                bold = true;
            },
            .Unknown => {
                dbg(" {s}", .{name});
                // if this is the only skipAny, maybe this loop should be a state lol
                try decoder.skipAny(1) orelse return null;
            },
        }
    }
    const pos: u32 = @intCast(self.ui.attr_arena.items.len);
    const w = self.ui.attr_arena.writer();
    try w.writeAll("\x1b[0m");
    if (fg) |the_fg| {
        const rgb: RGB = @bitCast(the_fg);
        try doColors(w, true, rgb);
    }
    if (bg) |the_bg| {
        const rgb: RGB = @bitCast(the_bg);
        try doColors(w, false, rgb);
    }
    if (bold) {
        try w.writeAll("\x1b[1m");
    }
    const endpos: u32 = @intCast(self.ui.attr_arena.items.len);
    try putAt(&self.ui.attr_off, id, .{ .start = pos, .end = endpos });
    dbg("\n", .{});

    base_decoder.consumed(decoder);
    base_decoder.toSkip(nsize - 2);
    return .redraw_call;
}

fn grid_resize(self: *Self, base_decoder: *mpack.SkipDecoder) !?State {
    var decoder = try base_decoder.inner();
    const iarg = try decoder.expectArray() orelse return null;
    const grid_id = try decoder.expectUInt() orelse return null;
    if (grid_id != 1) {
        @panic("get out!");
    }

    const grid = &self.ui.grid[grid_id - 1];
    grid.cols = @intCast(try decoder.expectUInt() orelse return null);
    grid.rows = @intCast(try decoder.expectUInt() orelse return null);

    try grid.cell.resize(grid.rows * grid.cols);

    base_decoder.consumed(decoder);
    base_decoder.toSkip(iarg - 3);

    dbg("REZISED {} x {}\n", .{ grid.cols, grid.rows });

    return .redraw_call;
}

const CellState = struct {
    event_extra_args: usize,
    grid: *Grid,
    row: u32,
    col: u32,
    ncells: u32,
    attr_id: u32,
};

fn grid_line(self: *Self, base_decoder: *mpack.SkipDecoder) !?State {
    var decoder = try base_decoder.inner();
    const iarg = try decoder.expectArray() orelse return null;
    if (iarg < 4) return error.MalformatedRPCMessage;
    const grid_id = try decoder.expectUInt() orelse return null;

    const row = try decoder.expectUInt() orelse return null;
    const col = try decoder.expectUInt() orelse return null;
    const ncells = try decoder.expectArray() orelse return null;

    self.cell_state = .{
        .event_extra_args = iarg - 4,
        .grid = &self.grid[grid_id - 1],
        .row = row,
        .col = col,
        .ncells = ncells,
        .attr_id = 0,
    };
    base_decoder.consumed(decoder);

    return .next_cell;
}

fn next_cell(self: *Self, base_decoder: *mpack.SkipDecoder) !?State {
    const s = &self.cell_state;

    while (s.ncells > 0) {
        var decoder = try base_decoder.inner();

        const nsize = try decoder.expectArray();
        const str = try decoder.expectString();
        var used: u8 = 1;
        var repeat: u64 = 1;
        if (nsize >= 2) {
            s.attr_id = @intCast(try decoder.expectUInt());
            used = 2;
            if (nsize >= 3) {
                repeat = try decoder.expectUInt();
                used = 3;
            }
        }
        dbg("used {} to get str {} attr={} x {}\n", .{ used, str, s.attr_id, repeat });

        base_decoder.consumed(decoder);
    }

    return .redraw_call;
}
