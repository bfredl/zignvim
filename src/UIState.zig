const std = @import("std");
const mem = std.mem;
const Self = @This();
const dbg = std.debug.print;

allocator: mem.Allocator,
attr_arena: std.ArrayListUnmanaged(u8) = .{},
glyph_arena: std.ArrayListUnmanaged(u8) = .{},
glyph_cache: std.HashMapUnmanaged(u32, void, std.hash_map.StringIndexContext, std.hash_map.default_max_load_percentage) = .{},
attr: std.ArrayListUnmanaged(Attr) = .{},
mode_info: std.ArrayListUnmanaged(ModeInfo) = .{},
mode_idx: u32 = 0,

cursor: struct { grid: u32, row: u16, col: u16 } = undefined,
default_colors: struct { fg: u24, bg: u24, sp: u24 } = undefined,

grid: [1]Grid = .{.{}},

pub const Attr = struct {
    start: u32,
    end: u32,
    fg: ?u24,
    bg: ?u24,
};

pub const CursorShape = enum { block, horizontal, vertical };
pub const ModeInfo = struct {
    cursor_shape: CursorShape = .block,
    cell_percentage: u8 = 100,
    short_name: [2]u8 = .{ '?', '?' },
};
pub fn mode(self: *Self) ModeInfo {
    return if (self.mode_info.items.len > self.mode_idx) self.mode_info.items[self.mode_idx] else .{};
}

pub const Grid = struct {
    rows: u16 = 0,
    cols: u16 = 0,
    cell: std.ArrayListUnmanaged(Cell) = .{},
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
    var attr: std.ArrayListUnmanaged(Attr) = .{};
    try attr.append(allocator, Attr{ .start = 0, .end = 0, .fg = null, .bg = null });
    return .{
        .allocator = allocator,
        .attr = attr,
    };
}

pub fn text(self: *@This(), cell: *const Cell) []const u8 {
    return switch (cell.text) {
        // oo I eat plain toast
        .plain => |str| str[0 .. std.mem.indexOfScalar(u8, &str, 0) orelse charsize],
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

pub fn dump_grid(self: *Self) void {
    var attr_id: u32 = 0;
    dbg("SCREEN begin ======\n", .{});
    const grid = self.grid[0];
    for (0..grid.rows) |row| {
        const basepos = row * grid.cols;
        for (0..grid.cols) |col| {
            const cell = grid.cell.items[basepos + col];

            if (cell.attr_id != attr_id) {
                attr_id = cell.attr_id;
                const slice = if (attr_id > 0) theslice: {
                    const islice = self.attr.items[attr_id];
                    break :theslice self.attr_arena.items[islice.start..islice.end];
                } else "\x1b[0m";
                dbg("{s}", .{slice});
            }
            dbg("{s}", .{self.text(&cell)});
        }
        dbg("\n", .{});
    }
    dbg("SCREEN end ======\n", .{});
}
