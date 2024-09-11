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
cell_state: CellState = undefined,

ui: struct {
    allocator: mem.Allocator,
    attr_arena: ArrayList(u8),
    glyph_arena: std.ArrayListUnmanaged(u8) = .{},
    glyph_cache: std.HashMapUnmanaged(u32, void, std.hash_map.StringIndexContext, std.hash_map.default_max_load_percentage) = .{},
    attr: ArrayList(Attr),

    cursor: struct { grid: u32, row: u16, col: u16 } = undefined,
    default_colors: struct { fg: u24, bg: u24, sp: u24 } = undefined,

    grid: [1]Grid,

    pub fn text(self: *@This(), cell: *const Cell) []const u8 {
        return switch (cell.text) {
            // oo I eat plain toast
            .plain => |str| str[0 .. std.mem.indexOfScalar(u8, &str, 0) orelse charsize],
            .indexed => |idx| mem.span(@as([*:0]u8, @ptrCast(self.glyph_arena.items[idx..]))),
        };
    }

    fn intern_glyph(self: *@This(), str: []const u8) !CellText {
        if (str.len <= charsize) {
            var char: [charsize]u8 = undefined;
            for (0..str.len) |i| {
                char[i] = str[i];
            }
            if (str.len < charsize) {
                char[str.len] = 0;
            }
            return .{ .plain = char };
        }
        const gop = try self.glyph_cache.getOrPutContextAdapted(self.allocator, str, std.hash_map.StringIndexAdapter{
            .bytes = &self.glyph_arena,
        }, std.hash_map.StringIndexContext{
            .bytes = &self.glyph_arena,
        });
        if (gop.found_existing) {
            return .{ .indexed = gop.key_ptr.* };
        } else {
            const str_index: u32 = @intCast(self.glyph_arena.items.len);
            gop.key_ptr.* = str_index;
            try self.glyph_arena.appendSlice(self.allocator, str);
            try self.glyph_arena.append(self.allocator, 0);
            return .{ .indexed = str_index };
        }
    }
},

pub const Attr = struct {
    start: u32,
    end: u32,
    fg: ?u24,
    bg: ?u24,
};

const Grid = struct {
    rows: u16,
    cols: u16,
    cell: ArrayList(Cell),
};

// base charsize
const charsize = 4;

const CellText = union(enum) { plain: [charsize]u8, indexed: u32 };

pub const Cell = struct {
    // TODO: use compression trick like in nvim to avoid the tag byte
    text: CellText,
    attr_id: u32,

    pub fn is_ascii_space(self: Cell) bool {
        return switch (self.text) {
            .indexed => false,
            .plain => |txt| mem.eql(u8, txt[0..2], &.{ 32, 0 }),
        };
    }
};

pub const RGB = packed struct { b: u8, g: u8, r: u8 };

fn doColors(w: anytype, fg: bool, rgb: RGB) !void {
    const kod = if (fg) "3" else "4";
    try w.print("\x1b[{s}8;2;{};{};{}m", .{ kod, rgb.r, rgb.g, rgb.b });
}

fn putAt(array_list: anytype, index: usize, item: anytype) !void {
    if (array_list.items.len < index + 1) {
        // TODO: safe fill with attr[0] values!
        try array_list.resize(index + 1);
    }
    array_list.items[index] = item;
}

pub fn init(allocator: mem.Allocator) !Self {
    var attr: ArrayList(Attr) = .init(allocator);
    try attr.append(Attr{ .start = 0, .end = 0, .fg = null, .bg = null });
    return .{
        .ui = .{
            .allocator = allocator,
            .attr_arena = .init(allocator),
            .attr = attr,
            .grid = .{.{ .rows = 0, .cols = 0, .cell = .init(allocator) }},
        },
    };
}

pub fn process(self: *Self, decoder: *mpack.SkipDecoder) !void {
    std.debug.print("haii {}\n", .{decoder.data.len});

    while (true) {
        try decoder.skipData();

        // not strictly needed but lets return void on a clean break..
        if (decoder.data.len == 0) break;

        try switch (self.state) {
            .next_msg => self.next_msg(decoder),
            .redraw_event => self.redraw_event(decoder),
            .redraw_call => self.redraw_call(decoder),
            .next_cell => self.next_cell(decoder),
        };
    }
}

fn next_msg(self: *Self, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.inner();
    const tok = try decoder.expectArray();
    if (tok < 3) return error.MalformatedRPCMessage;
    const num = try decoder.expectUInt();
    if (num != 2) @panic("handle replies and requests");
    if (tok != 3) return error.MalformatedRPCMessage;

    const name = try decoder.expectString();

    if (!std.mem.eql(u8, name, "redraw")) @panic("handle notifications other than 'redraw'");

    self.redraw_events = try decoder.expectArray();
    base_decoder.consumed(decoder);

    return self.redraw_event(base_decoder);
}

fn redraw_event(self: *Self, base_decoder: *mpack.SkipDecoder) !void {
    if (self.redraw_events == 0) {
        // todo: with guaranteed tail calls, we could "return next_msg()" without problems
        self.state = .next_msg;
        return;
    }
    self.state = .redraw_event;

    var decoder = try base_decoder.inner();
    const nitems = try decoder.expectArray();
    if (nitems < 1) return error.MalformatedRPCMessage;
    const name = try decoder.expectString();

    dbg("EVENT: '{s}' with {}\n", .{ name, nitems - 1 });

    base_decoder.consumed(decoder);
    self.redraw_events -= 1;

    const event = stringToEnum(RedrawEvents, name) orelse {
        base_decoder.toSkip(nitems - 1);
        return;
    };

    self.event_calls = nitems - 1;
    self.event = event;
    return redraw_call(self, base_decoder);
}

const RedrawEvents = enum {
    hl_attr_define,
    grid_resize,
    grid_clear,
    grid_line,
    grid_cursor_goto,
    default_colors_set,
    flush,
};

fn redraw_call(self: *Self, base_decoder: *mpack.SkipDecoder) !void {
    if (self.event_calls == 0) {
        // todo: with guaranteed tail calls, we could "return redraw_event()" without problems
        self.state = .redraw_event;
        return;
    }
    self.state = .redraw_call;
    switch (self.event) {
        .hl_attr_define => try self.hl_attr_define(base_decoder),
        .grid_resize => try self.grid_resize(base_decoder),
        .grid_clear => try self.grid_clear(base_decoder),
        .grid_line => try self.grid_line(base_decoder),
        .grid_cursor_goto => try self.grid_cursor_goto(base_decoder),
        .default_colors_set => try self.default_colors_set(base_decoder),
        .flush => try self.flush(base_decoder),
    }
}

fn hl_attr_define(self: *Self, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.inner();

    const nsize = try decoder.expectArray();
    const id = try decoder.expectUInt();
    const rgb_attrs = try decoder.expectMap();
    dbg("ATTEN: {} {}", .{ id, rgb_attrs });
    var fg: ?u24 = null;
    var bg: ?u24 = null;
    var bold = false;
    var j: u32 = 0;
    while (j < rgb_attrs) : (j += 1) {
        const name = try decoder.expectString();
        const Keys = enum { foreground, background, bold, Unknown };
        const key = stringToEnum(Keys, name) orelse .Unknown;
        switch (key) {
            .foreground => {
                const num = try decoder.expectUInt();
                dbg(" fg={}", .{num});
                fg = @intCast(num);
            },
            .background => {
                const num = try decoder.expectUInt();
                dbg(" bg={}", .{num});
                bg = @intCast(num);
            },
            .bold => {
                // TODO: expectBööööl
                _ = try decoder.readHead();
                dbg(" BOLDEN", .{});
                bold = true;
            },
            .Unknown => {
                dbg(" {s}", .{name});
                // if this is the only skipAny, maybe this loop should be a state lol
                try decoder.skipAny(1);
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
    try putAt(&self.ui.attr, id, .{ .start = pos, .end = endpos, .fg = fg, .bg = bg });
    dbg("\n", .{});

    base_decoder.consumed(decoder);
    base_decoder.toSkip(nsize - 2);
    self.event_calls -= 1;
}

fn grid_resize(self: *Self, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.inner();
    const iarg = try decoder.expectArray();
    const grid_id = try decoder.expectUInt();
    if (grid_id != 1) {
        @panic("get out!");
    }

    const grid = &self.ui.grid[grid_id - 1];
    grid.cols = @intCast(try decoder.expectUInt());
    grid.rows = @intCast(try decoder.expectUInt());

    try grid.cell.resize(grid.rows * grid.cols);

    base_decoder.consumed(decoder);
    base_decoder.toSkip(iarg - 3);
    self.event_calls -= 1;

    dbg("REZISED {} x {}\n", .{ grid.cols, grid.rows });
}

fn grid_clear(self: *Self, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.inner();
    const iarg = try decoder.expectArray();
    const grid_id = try decoder.expectUInt();
    if (grid_id != 1) {
        @panic("get out!");
    }

    const grid = &self.ui.grid[grid_id - 1];
    var char: [charsize]u8 = undefined;
    //char[0..2] = .{ ' ', 0 };
    char[0] = ' ';
    char[1] = 0;

    @memset(grid.cell.items, .{ .text = .{ .plain = char }, .attr_id = 0 });

    base_decoder.consumed(decoder);
    base_decoder.toSkip(iarg - 1); // TODO: we want decoder.pop() back!
    self.event_calls -= 1;
}

fn grid_cursor_goto(self: *Self, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.inner();
    const iarg = try decoder.expectArray();
    if (iarg < 3) return error.MalformatedRPCMessage;
    const grid_id: u32 = @intCast(try decoder.expectUInt());
    const row: u16 = @intCast(try decoder.expectUInt());
    const col: u16 = @intCast(try decoder.expectUInt());

    self.ui.cursor = .{ .grid = grid_id, .row = row, .col = col };

    base_decoder.consumed(decoder);
    base_decoder.toSkip(iarg - 3);
    self.event_calls -= 1;
}

fn default_colors_set(self: *Self, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.inner();
    const iarg = try decoder.expectArray();
    if (iarg < 3) return error.MalformatedRPCMessage;
    const fg: u24 = @intCast(try decoder.expectUInt());
    const bg: u24 = @intCast(try decoder.expectUInt());
    const sp: u24 = @intCast(try decoder.expectUInt());

    self.ui.default_colors = .{ .fg = fg, .bg = bg, .sp = sp };

    base_decoder.consumed(decoder);
    base_decoder.toSkip(iarg - 3);
    self.event_calls -= 1;
}

fn flush(self: *Self, base_decoder: *mpack.SkipDecoder) !void {
    base_decoder.toSkip(1);
    self.event_calls -= 1;

    return error.FlushCondition;
}

pub fn dump_grid(self: *Self) void {
    var attr_id: u32 = 0;
    dbg("SCREEN begin ======\n", .{});
    const grid = self.ui.grid[0];
    for (0..grid.rows) |row| {
        const basepos = row * grid.cols;
        for (0..grid.cols) |col| {
            const cell = grid.cell.items[basepos + col];

            if (cell.attr_id != attr_id) {
                attr_id = cell.attr_id;
                const slice = if (attr_id > 0) theslice: {
                    const islice = self.ui.attr.items[attr_id];
                    break :theslice self.ui.attr_arena.items[islice.start..islice.end];
                } else "\x1b[0m";
                dbg("{s}", .{slice});
            }
            dbg("{s}", .{self.ui.text(&cell)});
        }
        dbg("\n", .{});
    }
    dbg("SCREEN end ======\n", .{});
}

const CellState = struct {
    event_extra_args: usize,
    grid: *Grid,
    row: u32,
    col: u32,
    ncells: u32,
    attr_id: u32,
};

fn grid_line(self: *Self, base_decoder: *mpack.SkipDecoder) !void {
    while (self.event_calls > 0) {
        var decoder = try base_decoder.inner();
        const iarg = try decoder.expectArray();
        if (iarg < 4) return error.MalformatedRPCMessage;
        const grid_id = try decoder.expectUInt();

        const row = try decoder.expectUInt();
        const col = try decoder.expectUInt();
        const ncells = try decoder.expectArray();

        // dbg("with line: {} {} has cells {} and extra {}\n", .{ row, col, ncells, iarg - 4 });

        self.cell_state = .{
            .event_extra_args = iarg - 4,
            .grid = &self.ui.grid[grid_id - 1],
            .row = @intCast(row),
            .col = @intCast(col),
            .ncells = ncells,
            .attr_id = 0,
        };
        base_decoder.consumed(decoder);
        self.event_calls -= 1;

        try self.next_cell(base_decoder);
    }
}

fn next_cell(self: *Self, base_decoder: *mpack.SkipDecoder) !void {
    const s = &self.cell_state;
    self.state = .next_cell;

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

        const cell_text: CellText = try self.ui.intern_glyph(str);
        const basepos = s.row * s.grid.cols;
        while (repeat > 0) : (repeat -= 1) {
            s.grid.cell.items[basepos + s.col] = .{ .text = cell_text, .attr_id = s.attr_id };
            s.col += 1;
            //dbg("{s}", .{str});
            // self.writer.writeAll(str) catch return RPCError.IOError;
        }
        // dbg("used {} out of {} to get str {s} attr={} x {}\n", .{ used, nsize, str, s.attr_id, repeat });

        s.ncells -= 1;
        base_decoder.consumed(decoder);
    }

    base_decoder.toSkip(s.event_extra_args);
    try base_decoder.skipData();
    self.state = .redraw_call;
}
