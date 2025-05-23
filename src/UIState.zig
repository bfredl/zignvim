const std = @import("std");
const mem = std.mem;
const Self = @This();
const dbg = std.debug.print;

allocator: mem.Allocator,
attr_arena: std.ArrayListUnmanaged(u8) = .{},
glyph_arena: std.ArrayListUnmanaged(u8) = .{},
glyph_cache: std.HashMapUnmanaged(u32, void, std.hash_map.StringIndexContext, std.hash_map.default_max_load_percentage) = .{},
attrs: std.ArrayListUnmanaged(Attr) = .{},
mode_info: std.ArrayListUnmanaged(ModeInfo) = .{},
mode_idx: u32 = 0,

cursor: struct { grid: u32, row: u16, col: u16 } = undefined,
default_colors: struct { fg: RGB, bg: RGB, sp: RGB } = undefined,

grid_nr: ?u32 = null,
grid_cached: *Grid = undefined,
grids: std.AutoArrayHashMapUnmanaged(u32, Grid) = .{},
msg: ?struct {
    grid: u32,
    row: u32,
    scrolled: bool,
    char: CellText,
} = null,

pub fn grid(self: *Self, id: u32) ?*Grid {
    if (self.grid_nr == id) {
        return self.grid_cached;
    }
    return self.grids.getPtr(id);
}

pub fn put_grid(self: *Self, id: u32) !*Grid {
    if (self.grid_nr == id) {
        return self.grid_cached;
    }
    const gop = try self.grids.getOrPut(self.allocator, id);
    if (!gop.found_existing) {
        gop.value_ptr.* = Grid{};
    }
    return gop.value_ptr;
}

pub const Attr = struct {
    start: u32 = 0,
    end: u32 = 0,
    fg: ?RGB = null,
    bg: ?RGB = null,
    sp: ?RGB = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    undercurl: bool = false,
    underdouble: bool = false,
    reverse: bool = false,
    altfont: bool = false,
};

pub const CursorShape = enum { block, horizontal, vertical };
pub const ModeInfo = struct {
    cursor_shape: CursorShape = .block,
    cell_percentage: u8 = 100,
    attr_id: u32 = 0,
    short_name: [2]u8 = .{ '?', '?' },
};
pub fn mode(self: *Self) ModeInfo {
    return if (self.mode_info.items.len > self.mode_idx) self.mode_info.items[self.mode_idx] else .{};
}
pub fn attr(self: *Self, attr_id: u32) Attr {
    return self.attrs.items[if (self.attrs.items.len > attr_id) attr_id else 0];
}

pub fn get_colors(self: *Self, a: Attr) struct { RGB, RGB, RGB } {
    const bg = a.bg orelse self.default_colors.bg;
    const fg = a.fg orelse self.default_colors.fg;
    const sp = a.sp orelse self.default_colors.sp;
    return if (a.reverse) .{ fg, bg, sp } else .{ bg, fg, sp };
}

pub const Grid = struct {
    rows: u16 = 0,
    cols: u16 = 0,
    cell: std.ArrayListUnmanaged(Cell) = .{},
    info: GridInfo = .none,
};

pub const GridInfo = union(enum) {
    none: void,
    window: struct { row: u32, col: u32, width: u32, height: u32 },
    // float: stuff,
};

// base charsize
pub const charsize = 4;

pub const CellText = union(enum) { plain: [charsize]u8, indexed: u32 };

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

pub fn init(allocator: mem.Allocator) !Self {
    var attrs: std.ArrayListUnmanaged(Attr) = .{};
    try attrs.append(allocator, .{});
    return .{
        .allocator = allocator,
        .attrs = attrs,
    };
}

pub fn text(self: *@This(), cell: *const Cell) []const u8 {
    return switch (cell.text) {
        // oo I eat plain toast
        .plain => |*str| str[0 .. std.mem.indexOfScalar(u8, str, 0) orelse charsize],
        .indexed => |idx| mem.span(@as([*:0]u8, @ptrCast(self.glyph_arena.items[idx..]))),
    };
}

pub fn intern_glyph(self: *@This(), str: []const u8) !CellText {
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

pub fn dump_grid(self: *Self, id: u32) void {
    var attr_id: u32 = 0;
    dbg("GRID {} begin ======\n", .{id});
    const g = self.grid(id) orelse &Grid{};
    for (0..g.rows) |row| {
        const basepos = row * g.cols;
        for (0..g.cols) |col| {
            const cell = g.cell.items[basepos + col];

            if (cell.attr_id != attr_id) {
                attr_id = cell.attr_id;
                const slice = if (attr_id > 0) theslice: {
                    const islice = self.attrs.items[attr_id];
                    break :theslice self.attr_arena.items[islice.start..islice.end];
                } else "\x1b[0m";
                dbg("{s}", .{slice});
            }
            dbg("{s}", .{self.text(&cell)});
        }
        dbg("\r\n", .{});
    }
    dbg("\x1b[0mGRID end ======\n", .{});
}
