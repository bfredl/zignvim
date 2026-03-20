const std = @import("std");
const vaxis = @import("vaxis");
const RPCState = @import("RPCState.zig");
const UIState = @import("UIState.zig");
const mpack = @import("mpack.zig");
const io_native = @import("io_native.zig");
const ctlseqs = vaxis.ctlseqs;

const Self = @This();

allocator: std.mem.Allocator,
parser: vaxis.Parser,
child: std.process.Child = undefined,
tty: vaxis.Tty,
winsize: vaxis.Winsize = undefined,

enc_buf: std.ArrayListUnmanaged(u8) = .empty,

quitting: bool = false,
signal_stopped: bool = false,

// buf only for cell rendering. high prio messages might be sent directly
// or use another buf
render: struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
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

decoder: mpack.SkipDecoder = undefined,
rpc: RPCState,

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var mega_buffer: [512]u8 = undefined;

    var vx = try vaxis.init(gpa, .{});
    var self: Self = .{
        .parser = .{},
        .rpc = try .init(gpa),
        // .loop = try xev.Loop.init(.{}),
        .allocator = gpa,
        .tty = try .init(&mega_buffer),
    };
    defer self.loop.deinit();
    defer self.tty.deinit();

    const ttyw = self.tty.anyWriter();

    const tty_read: std.IO.File = .{ .handle = self.tty.fd, .flags = .{ .nonblocking = false } };

    self.winsize = try vaxis.Tty.getWinsize(self.tty.fd);
    try vaxis.Tty.notifyWinsize(.{ .callback = on_winch, .context = @ptrCast(&self) });

    try vx.enterAltScreen(ttyw);
    defer vx.deinit(gpa, ttyw);

    // XX: encoder will be set with data when it is available
    self.decoder = mpack.SkipDecoder{ .data = undefined };

    var nvim: ?[]const u8 = null;
    var argv_rest = std.os.argv[1..];
    if (argv_rest.len >= 2 and std.mem.eql(u8, std.mem.span(argv_rest[0]), "--nvim")) {
        nvim = std.mem.span(argv_rest[1]);
        argv_rest = argv_rest[2..];
    }
    try self.attach(nvim, argv_rest, self.winsize.cols, self.winsize.rows);
    const nvim_read: std.IO.File = .{ .handle = self.nvim_read_fd, .flags = .{ .nonblocking = false } };

    // WOW they actually implemted something very useful: essentially
    // a mini-event loop which "just" tracks N fd:s and a resizing
    // buffer for each, GOOD JOB ZIG CORE DEVS:)
    var multi_reader_buffer: std.IopFile.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(gpa, std.io, multi_reader_buffer.toStreams(), &.{ nvim_read, tty_read });
    defer multi_reader.deinit_checkthis();

    const nvim_reader = multi_reader.reader(0);
    const tty_reader = multi_reader.reader(1);

    var tty_available_last: u32 = 0;
    var nvim_available_last: u32 = 0;
    while (multi_reader.fill()) |_| {
        // TODO: check EOF
        const tty_buffered = tty_reader.buffered();
        if (tty_buffered.size > tty_available_last) {
            const read = self.ttyReadCb(tty_buffered);
            tty_reader.toss(read);
            tty_available_last = tty_reader.buffered_size();
        }

        // TODO: nvim EOF
        if (false) {
            std.debug.print("nvim EOF!\n", .{});
            break;
        }
        const nvim_buffered = nvim_reader.buffered();
        if (nvim_buffered.size > nvim_available_last) {
            const read = self.nvimReadCb(nvim_buffered);
            nvim_reader.toss(read);
            nvim_available_last = nvim_reader.buffered_size();
        }

        if (self.quitting) break;

        if (self.signal_stopped) {
            // XXX: this is a bit of a hack. preferably the event loop should natively
            // handle signals as events
            self.signal_stopped = false;
            try self.checkResize();
        }
    } else |err| {
        // TODO;
        return err;
    }
}

fn ttyReadCb(
    self: *Self,
    buf: []const u8,
) !usize {
    // std.debug.print("Nommm {}\r\n", .{n});
    var seq_start: usize = 0;
    while (seq_start < buf.size) {
        const result = self.parser.parse(buf[seq_start..buf.size], undefined) catch {
            std.debug.print("??parser panik\r\n", .{});
            return error.PANIK;
        };
        if (result.n == 0) {
            // cannot parse more, return how much we consumed
            return seq_start;
        }
        seq_start += result.n;

        const event = result.event orelse continue;

        switch (event) {
            .key_press => |k| {
                self.handleKeyPress(k);
                self.flush_input() catch @panic("RETURN TO SENDER");
            },
            else => std.debug.print("event {}\r\n", .{event}),
        }
    }

    if (false and buf.size > 0 and buf[0] == 3) {
        self.loop.stop();
        return .disarm;
    }

    return seq_start;
}

fn handleKeyPress(self: *Self, k: vaxis.Key) void {
    const Key = vaxis.Key;
    if (k.text) |text| {
        self.enqueueInput(text);
    } else if (k.codepoint < 32) {
        self.enqueueInput(&.{@intCast(k.codepoint)});
    } else if (k.codepoint >= 127 and k.mods.ctrl == false and k.mods.alt == false and k.mods.shift == false) {
        const string = switch (k.codepoint) {
            127 => "bs",
            Key.page_up => "PageUp",
            Key.page_down => "PageDown",
            Key.home => "Home",
            Key.end => "End",
            Key.f3 => "F3",
            else => null,
        };
        if (string) |s| {
            var buf: [128]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "<{s}>", .{s}) catch unreachable;
            self.enqueueInput(key);
        } else std.debug.print("keypress {}\r\n", .{k});
    } else if (k.mods.ctrl == true and k.mods.alt == false and k.codepoint >= 'a' and k.codepoint <= 'z') {
        self.enqueueInput(&.{@intCast(k.codepoint - 'a' + 1)});
    } else {
        std.debug.print("keypress {}\r\n", .{k});
    }
}

fn attach(self: *Self, io: std.Io, nvim_exe: ?[]const u8, args: []const ?[*:0]const u8, width: u32, height: u32) !void {
    var the_fd: ?i32 = null;
    if (false) {
        the_fd = try std.posix.dup(0);
    }

    self.child = try io_native.spawn(self.allocator, io, nvim_exe, args, the_fd);

    const encoder: mpack.Encoder = .init(self.enc_buf.writer(self.allocator));
    try io_native.attach(encoder, width, height, if (the_fd) |_| @as(i32, 3) else null, false);
    try self.flush_input();

    self.fd_nvim = self.child.stdout.?.handle;
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
    const encoder: mpack.Encoder = .init(self.enc_buf.writer(self.allocator));
    io_native.unsafe_input(encoder, str) catch @panic("memory error");
}

fn on_winch(context: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.signal_stopped = true;
}

fn checkResize(self: *Self) !void {
    const new_size = try vaxis.Tty.getWinsize(self.tty.fd);
    if (new_size.rows != self.winsize.rows or new_size.cols != self.winsize.cols) {
        self.winsize = new_size;

        const encoder: mpack.Encoder = .init(self.enc_buf.writer(self.allocator));
        io_native.try_resize(encoder, 1, self.winsize.cols, self.winsize.rows) catch @panic("memory error");
        try self.flush_input();
    }
}

fn nvimReadCb(
    self: *Self,
    buf: []const u8,
) usize {
    self.decoder.data = buf;
    self.rpc.process(&self.decoder) catch @panic("go crazy yea");
    // TODO: this is a little messy. rework mpack.SkipDecoder to work nicely with
    // std.Io.Reader style buffering
    const consumed = buf.size - self.decoder.data.size;
    self.decoder.data = undefined;

    return consumed;
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
