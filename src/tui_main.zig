const std = @import("std");
const vaxis = @import("vaxis");
const xev = @import("xev");
const RPCState = @import("RPCState.zig");
const UIState = @import("UIState.zig");
const mpack = @import("mpack.zig");
const io = @import("io_native.zig");
const ctlseqs = vaxis.ctlseqs;

const Self = @This();

allocator: std.mem.Allocator,
loop: xev.Loop,
parser: vaxis.Parser,
child: std.process.Child = undefined,
tty: vaxis.Tty,

enc_buf: std.ArrayListUnmanaged(u8) = .{},

// buf only for cell rendering. high prio messages might be sent directly
// or use another buf
render: struct {
    buf: std.ArrayListUnmanaged(u8) = .{},
    // this is the position emitting buf would take you to. might
    // want another for "assumed start position"
    pos_r: u32 = 0,
    pos_c: u32 = 0,
    attr_id: ?u32 = null,
    const Render = @This();

    pub fn print(self: *Render, comptime fmt: []const u8, vals: anytype) !void {
        try self.buf.writer(@as(*Self, @fieldParentPtr("render", self)).allocator).print(fmt, vals);
    }
    pub fn put(self: *Render, str: []const u8) !void {
        try self.buf.writer(@as(*Self, @fieldParentPtr("render", self)).allocator).writeAll(str);
    }

    pub fn cup(self: *Render, row: u32, col: u32) !void {
        try self.print(ctlseqs.cup, .{ row + 1, col + 1 });
    }
} = .{},

buf_nvim: [1024]u8 = undefined,
decoder: mpack.SkipDecoder = undefined,
rpc: RPCState,
c_nvim: xev.Completion = undefined,
stream_nvim: xev.Stream = undefined,

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // try vx.enterAltScreen(ttyw);

    var vx = try vaxis.init(alloc, .{});
    var self: Self = .{
        .parser = .{ .grapheme_data = &vx.unicode.width_data.g_data },
        .rpc = try .init(alloc),
        .loop = try xev.Loop.init(.{}),
        .allocator = alloc,
        .tty = try .init(),
    };
    defer self.loop.deinit();
    defer self.tty.deinit();

    const ttyw = self.tty.anyWriter();
    const stream = xev.Stream.initFd(self.tty.fd);
    defer stream.deinit();

    const winsize = try vaxis.Tty.getWinsize(self.tty.fd);

    defer vx.deinit(alloc, ttyw);

    self.decoder = mpack.SkipDecoder{ .data = self.buf_nvim[0..0] };
    var read_buf: [1024]u8 = undefined;

    var c: xev.Completion = undefined;
    stream.read(&self.loop, &c, .{ .slice = &read_buf }, Self, &self, ttyReadCb);

    var nvim: ?[]const u8 = null;
    var argv_rest = std.os.argv[1..];
    if (argv_rest.len >= 2 and std.mem.eql(u8, std.mem.span(argv_rest[0]), "--nvim")) {
        nvim = std.mem.span(argv_rest[1]);
        argv_rest = argv_rest[2..];
    }
    try self.attach(nvim, argv_rest, winsize.cols, winsize.rows);

    try self.loop.run(.until_done);
}

fn ttyReadCb(
    self_: ?*Self,
    loop: *xev.Loop,
    c: *xev.Completion,
    stream: xev.Stream,
    buf: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    _ = loop;
    _ = c;
    _ = stream;
    const self = self_.?;
    const n = r catch |err| switch (err) {
        error.EOF => {
            std.debug.print("handle EOF!\n", .{});
            return .disarm;
        },
        else => {
            std.log.warn("tty unexpected err={}", .{err});
            return .disarm;
        },
    };

    // std.debug.print("Nommm {}\r\n", .{n});
    const slice = buf.slice[0..n];
    var seq_start: usize = 0;
    while (seq_start < n) {
        const result = self.parser.parse(slice[seq_start..n], undefined) catch {
            std.debug.print("??parser panik\r\n", .{});
            return .disarm;
        };
        if (result.n == 0) {
            // TODO: keep unfinished sequence and move read head
            std.debug.print("??UNHANDLED??completion \r\n", .{});
            return .rearm;
        }
        seq_start += result.n;

        const event = result.event orelse continue;

        switch (event) {
            .key_press => |k| {
                if (k.text) |text| {
                    self.enqueueInput(text);
                } else if (k.codepoint < 32) {
                    self.enqueueInput(&.{@intCast(k.codepoint)});
                } else if (k.codepoint == 127) {
                    self.enqueueInput("<bs>");
                } else if (k.mods.ctrl == true and k.mods.alt == false and k.codepoint >= 'a' and k.codepoint <= 'z') {
                    self.enqueueInput(&.{@intCast(k.codepoint - 'a' + 1)});
                } else {
                    std.debug.print("keypress {}\r\n", .{k});
                }
                self.flush_input() catch @panic("RETURN TO SENDER");
            },
            else => std.debug.print("event {}\r\n", .{event}),
        }
    }

    if (false and n > 0 and slice[0] == 3) {
        self.loop.stop();
        return .disarm;
    }

    return .rearm;
}

fn attach(self: *Self, nvim_exe: ?[]const u8, args: []const ?[*:0]const u8, width: u32, height: u32) !void {
    var the_fd: ?i32 = null;
    if (false) {
        the_fd = try std.posix.dup(0);
    }

    self.child = try io.spawn(self.allocator, nvim_exe, args, the_fd);

    var encoder = mpack.encoder(self.enc_buf.writer(self.allocator));
    try io.attach(&encoder, width, height, if (the_fd) |_| @as(i32, 3) else null, false);
    try self.flush_input();

    self.stream_nvim = .initFd(self.child.stdout.?.handle);
    self.stream_nvim.read(&self.loop, &self.c_nvim, .{ .slice = &self.buf_nvim }, Self, self, nvimReadCb);
}

fn flush_input(self: *Self) !void {
    self.child.stdin.?.writeAll(self.enc_buf.items) catch |err| switch (err) {
        error.BrokenPipe => {
            // Nvim exited. we will handle this later
            @panic("handle nvim exit somehowe reasonable");
        },
        else => |e| return e,
    };
    self.enc_buf.items.len = 0;
}

fn enqueueInput(self: *Self, str: []const u8) void {
    // dbg("aha: {s}\n", .{str});
    const encoder = mpack.encoder(self.enc_buf.writer(self.allocator));
    io.unsafe_input(encoder, str) catch @panic("memory error");
}

fn nvimReadCb(
    self_: ?*Self,
    loop: *xev.Loop,
    c: *xev.Completion,
    stream: xev.Stream,
    buf: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    _ = c;
    _ = stream;
    _ = buf;
    _ = loop;
    const self = self_.?;
    const n = r catch |err| switch (err) {
        error.EOF => {
            std.debug.print("nvim EOF!\n", .{});
            self.loop.stop();
            return .disarm;
        },
        else => {
            std.log.warn("nvim unexpected err={}", .{err});
            return .disarm;
        },
    };

    self.decoder.data.len += n;
    self.rpc.process(&self.decoder) catch @panic("go crazy yea");

    // move any unhandled RPC data to start
    if (self.decoder.data.len > 0) {
        std.mem.copyForwards(u8, &self.buf_nvim, self.decoder.data);
    }
    self.decoder.data.ptr = &self.buf_nvim;

    // std.debug.print("Nommm {}\r\n", .{n});
    // don't use .rearm as buf start position might change.
    self.stream_nvim.read(&self.loop, &self.c_nvim, .{ .slice = self.buf_nvim[self.decoder.data.len..] }, Self, self, nvimReadCb);

    // TODO: this might be racy on epoll backend, just don't support that or edit c inplace instead????
    return .disarm;
}

pub fn attr_slice(self: *Self, id: u32) []const u8 {
    if (id > 0 and id < self.rpc.ui.attrs.items.len) {
        // TODO: cached slices are still cool, but we should build them using vaxis
        const islice = self.rpc.ui.attrs.items[id];
        return self.rpc.ui.attr_arena.items[islice.start..islice.end];
    }
    return ctlseqs.sgr_reset;
}

pub fn cb_grid_clear(self: *Self, grid_id: u32) !void {
    self.render.buf.items.len = 0;
    if (grid_id != 1) return;
    try self.render.put(ctlseqs.home ++ ctlseqs.erase_below_cursor);
    self.render.pos_r = 0;
    self.render.pos_c = 0;
}

const csr = "\x1b[{};{}r";
// TODO: safe to just ENTER 69 on startup (restore on exit);
const enter_lrmm = "\x1b[?69h";
const exit_lrmm = "\x1b[?69l";
const smglr = "\x1b[{};{}s";

fn grid(self: *Self) ?*UIState.Grid {
    return self.rpc.ui.grid(1);
}

pub fn cb_grid_scroll(self: *Self, grid_id: u32, top: u32, bot: u32, left: u32, right: u32, rows: i32) !void {
    std.debug.print("scrollen {}: {}-{} X {}-{} delta {}\n", .{ grid_id, top, bot, left, right, rows });
    const g = self.grid() orelse return;
    const render = &self.render;
    const top_bot = true;
    const left_right = left > 0 or right < g.cols;

    if (top_bot) {
        try render.print(csr, .{ top + 1, bot });
    }
    if (left_right) {
        try render.print(enter_lrmm ++ smglr, .{ left + 1, right });
    }
    try render.cup(top, left);
    try render.put(ctlseqs.sgr_reset);
    if (rows > 0) {
        try render.print("\x1b[{}M", .{rows});
    } else if (rows < 0) {
        try render.print("\x1b[{}L", .{-rows});
    }
    if (top_bot) {
        try render.put("\x1b[r");
    }
    if (left_right) {
        try render.put("\x1b[s" ++ exit_lrmm);
    }
    render.pos_r = invalid_fixme;
    render.pos_c = invalid_fixme;
}

const invalid_fixme = 0xFFFFFFFF;

// note: RPC callbacks happen in the nvim read callback. heavy work need to be scheduled..
pub fn cb_grid_line(self: *Self, grid_id: u32, row: u32, start_col: u32, end_col: u32) !void {
    dbg("boll: {} {}, {}-{}\n", .{ grid_id, row, start_col, end_col });
    const render = &self.render;
    const ui = &self.rpc.ui;
    const g = ui.grid(1) orelse return;
    const basepos = row * g.cols;

    if (render.buf.items.len == 0 or render.pos_r != row or render.pos_c != start_col) {
        try render.cup(row, start_col);
        render.pos_r = row;
    }

    var c = start_col;
    var attr_id = render.attr_id;
    while (c < end_col) : (c += 1) {
        const cell = &g.cell.items[basepos + c];
        if (cell.attr_id != attr_id) {
            attr_id = cell.attr_id;
            try render.put(self.attr_slice(cell.attr_id));
        }
        try render.put(ui.text(cell));
    }
    render.pos_c = c;
    render.attr_id = attr_id;

    // TODO: flow control. like check if cell buffer is almost full at the end of nvimReadCb ?
}
const dbg = std.debug.print;

pub fn put_grid(self: *Self) !void {
    // TODO: buffered writing?
    const tty = self.tty.anyWriter();
    const ui = &self.rpc.ui;
    const g = ui.grid(1) orelse return;

    try tty.writeAll(ctlseqs.home);
    var attr_id: u32 = 0;
    for (0..g.rows) |row| {
        const basepos = row * g.cols;
        for (0..g.cols) |col| {
            const cell = g.cell.items[basepos + col];

            if (cell.attr_id != attr_id) {
                attr_id = cell.attr_id;
                try tty.writeAll(self.attr_slice(attr_id));
            }
            try tty.writeAll(ui.text(&cell));
        }
        try tty.writeAll("\r\n");
    }
}

pub fn cb_flush(self: *Self) !void {
    const ui = &self.rpc.ui;
    const tty = self.tty.anyWriter();
    try tty.writeAll(ctlseqs.sgr_reset);
    dbg("flish: {}\n", .{self.render.buf.items.len});
    try tty.writeAll(self.render.buf.items);
    self.render.buf.items.len = 0;

    // only if needed
    try tty.print(ctlseqs.cup, .{ ui.cursor.row + 1, ui.cursor.col + 1 });
}
