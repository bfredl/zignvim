const std = @import("std");
const mpack = @import("./mpack.zig");
const UIState = @import("./UIState.zig");
const mem = std.mem;
const stringToEnum = std.meta.stringToEnum;
const Self = @This();
const dbg = std.debug.print;

const State = enum {
    next_msg,
    redraw_event,
    redraw_call,
    next_cell,
    next_mode,
};

state: State = .next_msg,
event: RedrawEvents = undefined,

redraw_events: u64 = 0,
event_calls: u64 = 0,
event_state: union { cell: CellState, mode: ModeState } = undefined,

ui: UIState,

fn doColors(w: anytype, fg: bool, rgb: UIState.RGB) !void {
    const kod = if (fg) "3" else "4";
    try w.print("\x1b[{s}8;2;{};{};{}m", .{ kod, rgb.r, rgb.g, rgb.b });
}

fn putAt(allocator: mem.Allocator, array_list: anytype, index: usize, item: anytype) !void {
    if (array_list.items.len < index + 1) {
        // TODO: safe fill with attr[0] values!
        try array_list.resize(allocator, index + 1);
    }
    array_list.items[index] = item;
}

pub fn init(allocator: mem.Allocator) !Self {
    return .{ .ui = try .init(allocator) };
}

pub fn process(self: *Self, decoder: *mpack.SkipDecoder) !void {
    // dbg("haii {}\n", .{decoder.data.len});

    while (true) {
        try decoder.skipData();

        // not strictly needed but lets return void on a clean break..
        if (decoder.data.len == 0) break;

        try switch (self.state) {
            inline else => |tag| @field(Self, @tagName(tag))(self, decoder),
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

    // dbg("EVENT: '{s}' with {}\n", .{ name, nitems - 1 });

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
    mode_info_set,
    mode_change,
    grid_resize,
    grid_clear,
    grid_line,
    grid_scroll,
    grid_cursor_goto,
    default_colors_set,
    win_pos,
    win_hide,
    win_close,
    msg_set_pos,
    flush,
};

fn redraw_call(self: *Self, base_decoder: *mpack.SkipDecoder) !void {
    if (self.event_calls == 0) {
        // todo: with guaranteed tail calls, we could "return redraw_event()" without problems
        self.state = .redraw_event;
        return;
    }
    self.state = .redraw_call;
    try switch (self.event) {
        inline else => |tag| @field(Self, @tagName(tag))(self, base_decoder),
    };
}

fn hl_attr_define(self: *Self, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.inner();
    const debug = false;

    const nsize = try decoder.expectArray();
    const id = try decoder.expectUInt();
    const rgb_attrs = try decoder.expectMap();
    if (debug) dbg("ATTEN: {} {}", .{ id, rgb_attrs });
    var attr: UIState.Attr = .{};
    var j: u32 = 0;
    while (j < rgb_attrs) : (j += 1) {
        const name = try decoder.expectString();
        const Keys = enum { foreground, background, bold, italic, reverse, underline, Unknown };
        const key = stringToEnum(Keys, name) orelse .Unknown;
        switch (key) {
            .foreground => {
                const num = try decoder.expectUInt();
                if (debug) dbg(" fg={}", .{num});
                attr.fg = @bitCast(@as(u24, @intCast(num)));
            },
            .background => {
                const num = try decoder.expectUInt();
                if (debug) dbg(" bg={}", .{num});
                attr.bg = @bitCast(@as(u24, @intCast(num)));
            },
            .bold => {
                attr.bold = try decoder.expectBool();
                if (debug) dbg(" BOLDEN", .{});
            },
            .italic => {
                attr.italic = try decoder.expectBool();
                if (debug) dbg(" ITALIC", .{});
            },
            .reverse => {
                attr.reverse = try decoder.expectBool();
                if (debug) dbg(" REVERSE", .{});
            },
            .underline => {
                attr.underline = try decoder.expectBool();
                if (debug) dbg(" UNDERLAIN", .{});
            },
            .Unknown => {
                if (debug) dbg(" {s}", .{name});
                // if this is the only skipAny, maybe this loop should be a state lol
                try decoder.skipAny(1);
            },
        }
    }
    attr.start = @intCast(self.ui.attr_arena.items.len);
    const w = self.ui.attr_arena.writer(self.ui.allocator);
    try w.writeAll("\x1b[0m");
    if (attr.fg) |rgb| {
        try doColors(w, true, rgb);
    }
    if (attr.bg) |rgb| {
        try doColors(w, false, rgb);
    }
    if (attr.bold) {
        try w.writeAll("\x1b[1m");
    }
    attr.end = @intCast(self.ui.attr_arena.items.len);
    try putAt(self.ui.allocator, &self.ui.attrs, id, attr);
    if (debug) dbg("\n", .{});

    base_decoder.consumed(decoder);
    base_decoder.toSkip(nsize - 2);
    self.event_calls -= 1;
}

const ModeState = struct {
    event_extra_args: usize,
    n_modes: u32,
};

fn mode_info_set(self: *Self, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.inner();
    const iarg = try decoder.expectArray();
    const cursor_style = try decoder.expectBool();
    _ = cursor_style;
    const n_modes = try decoder.expectArray();

    self.event_state = .{ .mode = .{
        .event_extra_args = iarg - 2,
        .n_modes = n_modes,
    } };
    base_decoder.consumed(decoder);
    self.event_calls -= 1;

    try self.ui.mode_info.ensureTotalCapacity(self.ui.allocator, n_modes);
    self.ui.mode_info.items.len = 0;

    try self.next_mode(base_decoder);
}

fn next_mode(self: *Self, base_decoder: *mpack.SkipDecoder) !void {
    const s = &self.event_state.mode;
    self.state = .next_mode;
    const debug = false;

    while (s.n_modes > 0) {
        var decoder = try base_decoder.inner();
        const nsize = try decoder.expectMap();
        var mode: UIState.ModeInfo = .{};
        for (0..nsize) |_| {
            const key = try decoder.expectString();
            const Keys = enum { name, cursor_shape, cell_percentage, attr_id, Unknown };
            switch (stringToEnum(Keys, key) orelse .Unknown) {
                .name => {
                    const name = try decoder.expectString();
                    if (debug) dbg("FOR mODE {s}: ", .{name});
                },
                .cursor_shape => {
                    const kinda = try decoder.expectString();
                    if (debug) dbg(" shape={s}", .{kinda});
                    mode.cursor_shape = stringToEnum(UIState.CursorShape, kinda) orelse .block;
                },
                .cell_percentage => {
                    const ival = try decoder.expectUInt();
                    if (debug) dbg(" CELL={}", .{ival});
                    mode.cell_percentage = @truncate(ival);
                },
                .attr_id => {
                    mode.attr_id = @intCast(try decoder.expectUInt());
                    if (debug) dbg(" attr_id={}", .{mode.attr_id});
                },
                .Unknown => {
                    if (debug) dbg(" {s}", .{key});
                    // skipAny is bull, this should also be a state :p
                    try decoder.skipAny(1);
                },
            }
        }

        base_decoder.consumed(decoder);
        if (debug) dbg("\n", .{});
        self.ui.mode_info.appendAssumeCapacity(mode);
        s.n_modes -= 1;
    }

    base_decoder.toSkip(s.event_extra_args);
    self.state = .redraw_call;
    try base_decoder.skipData();
}

fn mode_change(self: *Self, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.inner();
    const iarg = try decoder.expectArray();
    const mode = try decoder.expectString();
    const mode_idx = try decoder.expectUInt();

    // dbg("MODE {s} with {}\n", .{ mode, self.ui.mode_info.items[mode_idx] });
    _ = mode;
    self.ui.mode_idx = @intCast(mode_idx);

    base_decoder.consumed(decoder);
    base_decoder.toSkip(iarg - 2);
    self.event_calls -= 1;
}

fn grid_resize(self: *Self, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.inner();
    const iarg = try decoder.expectArray();
    const grid_id = try decoder.expectUInt();

    const grid = try self.ui.put_grid(@intCast(grid_id));
    grid.cols = @intCast(try decoder.expectUInt());
    grid.rows = @intCast(try decoder.expectUInt());

    try grid.cell.resize(self.ui.allocator, grid.rows * grid.cols);

    base_decoder.consumed(decoder);
    base_decoder.toSkip(iarg - 3);
    self.event_calls -= 1;

    dbg("REZISED {} x {}\n", .{ grid.cols, grid.rows });
}

fn grid_clear(self: *Self, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.inner();
    const iarg = try decoder.expectArray();
    const grid_id = try decoder.expectUInt();

    base_decoder.consumed(decoder);
    base_decoder.toSkip(iarg - 1); // TODO: we want decoder.pop() back!
    self.event_calls -= 1;

    const grid = self.ui.grid(@intCast(grid_id)) orelse return error.InvalidUIState;
    var char: [UIState.charsize]u8 = undefined;
    //char[0..2] = .{ ' ', 0 };
    char[0] = ' ';
    char[1] = 0;

    @memset(grid.cell.items, .{ .text = .{ .plain = char }, .attr_id = 0 });
}

fn grid_scroll(self: *Self, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.inner();
    const iarg = try decoder.expectArray();
    if (iarg < 7) return error.MalformatedRPCMessage;
    const grid_id: u32 = @intCast(try decoder.expectUInt());
    const top: i32 = @intCast(try decoder.expectUInt());
    const bot: i32 = @intCast(try decoder.expectUInt());
    const left: usize = @intCast(try decoder.expectUInt());
    const right: usize = @intCast(try decoder.expectUInt());
    const rows: i32 = @intCast(try decoder.expectInt());
    const cols: i32 = @intCast(try decoder.expectInt());

    base_decoder.consumed(decoder);
    base_decoder.toSkip(iarg - 7);
    self.event_calls -= 1;

    if (cols != 0) {
        dbg("ACHTUNG: column scrolling not implemented\n", .{});
    }

    const grid = self.ui.grid(grid_id) orelse return error.InvalidUIState;
    const cells = grid.cell.items;

    const start, const stop, const step: i32 = if (rows > 0)
        .{ top, bot - rows, 1 }
    else
        .{ bot - 1, top - rows - 1, -1 };

    var i: i32 = start;
    while (i != stop) : (i += step) {
        const target, const src = .{ @as(usize, @intCast(i)) * grid.cols, @as(usize, @intCast(i + rows)) * grid.cols };
        @memcpy(cells[target + left .. target + right], cells[src + left .. src + right]);
    }
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

    self.ui.default_colors = .{ .fg = @bitCast(fg), .bg = @bitCast(bg), .sp = @bitCast(sp) };

    base_decoder.consumed(decoder);
    base_decoder.toSkip(iarg - 3);
    self.event_calls -= 1;
}

fn flush(self: *Self, base_decoder: *mpack.SkipDecoder) !void {
    base_decoder.toSkip(1);
    self.event_calls -= 1;

    return error.FlushCondition;
}

const CellState = struct {
    event_extra_args: usize,
    grid: *UIState.Grid,
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

        const grid = self.ui.grid(@intCast(grid_id)) orelse return error.InvalidUIState;

        // dbg("with line: {} {} has cells {} and extra {}\n", .{ row, col, ncells, iarg - 4 });

        self.event_state = .{ .cell = .{
            .event_extra_args = iarg - 4,
            .grid = grid,
            .row = @intCast(row),
            .col = @intCast(col),
            .ncells = ncells,
            .attr_id = 0,
        } };
        base_decoder.consumed(decoder);
        self.event_calls -= 1;

        try self.next_cell(base_decoder);
    }
}

fn next_cell(self: *Self, base_decoder: *mpack.SkipDecoder) !void {
    const s = &self.event_state.cell;
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
        base_decoder.consumed(decoder);

        const cell_text = try self.ui.intern_glyph(str);
        const basepos = s.row * s.grid.cols;
        while (repeat > 0) : (repeat -= 1) {
            s.grid.cell.items[basepos + s.col] = .{ .text = cell_text, .attr_id = s.attr_id };
            s.col += 1;
            //dbg("{s}", .{str});
            // self.writer.writeAll(str) catch return RPCError.IOError;
        }
        // dbg("used {} out of {} to get str {s} attr={} x {}\n", .{ used, nsize, str, s.attr_id, repeat });

        s.ncells -= 1;
    }

    base_decoder.toSkip(s.event_extra_args);
    self.state = .redraw_call;
    try base_decoder.skipData();
}

fn win_pos(self: *Self, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.inner();
    const iarg = try decoder.expectArray();
    if (iarg < 6) return error.MalformatedRPCMessage;
    const grid: u32 = @intCast(try decoder.expectUInt());
    const win = try decoder.expectExt();
    _ = win; // who cares
    const row: u32 = @intCast(try decoder.expectUInt());
    const col: u32 = @intCast(try decoder.expectUInt());
    const width: u32 = @intCast(try decoder.expectUInt());
    const height: u32 = @intCast(try decoder.expectUInt());

    dbg("window: grid={} at ({},{}) size={},{}\n", .{ grid, row, col, width, height });

    base_decoder.consumed(decoder);
    base_decoder.toSkip(iarg - 6);
    self.event_calls -= 1;
}

fn win_hide(self: *Self, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.inner();
    const iarg = try decoder.expectArray();
    if (iarg < 1) return error.MalformatedRPCMessage;
    const grid: u32 = @intCast(try decoder.expectUInt());

    dbg("IT's HIDDEN: {}\n", .{grid});

    base_decoder.consumed(decoder);
    base_decoder.toSkip(iarg - 1);
    self.event_calls -= 1;
}

fn win_close(self: *Self, base_decoder: *mpack.SkipDecoder) !void {
    dbg("closed and ", .{});
    return win_hide(self, base_decoder);
}

fn msg_set_pos(self: *Self, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.inner();
    const iarg = try decoder.expectArray();
    if (iarg < 4) return error.MalformatedRPCMessage;
    const grid: u32 = @intCast(try decoder.expectUInt());
    const row: u32 = @intCast(try decoder.expectUInt());
    const scrolled = try decoder.expectBool();
    const char = try decoder.expectString();

    dbg("messages: grid={} at {} scrolled={} char='{s}'\n", .{ grid, row, scrolled, char });

    base_decoder.consumed(decoder);
    base_decoder.toSkip(iarg - 4);
    self.event_calls -= 1;
}
