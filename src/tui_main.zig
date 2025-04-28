const std = @import("std");
const vaxis = @import("vaxis");
const xev = @import("xev");
const RPCState = @import("RPCState.zig");
const mpack = @import("./mpack.zig");
const io = @import("io_native.zig");
const ctlseqs = vaxis.ctlseqs;

const Self = @This();

allocator: std.mem.Allocator,
loop: xev.Loop,
parser: vaxis.Parser,
child: std.process.Child = undefined,
tty: vaxis.Tty,

enc_buf: std.ArrayListUnmanaged(u8) = .{},

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

    defer vx.deinit(alloc, ttyw);

    self.decoder = mpack.SkipDecoder{ .data = self.buf_nvim[0..0] };
    var read_buf: [1024]u8 = undefined;

    var c: xev.Completion = undefined;
    stream.read(&self.loop, &c, .{ .slice = &read_buf }, Self, &self, ttyReadCb);

    try self.attach(&.{});

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

fn attach(self: *Self, args: []const ?[*:0]const u8) !void {
    const width: u32, const height: u32 = .{ 80, 20 };

    var the_fd: ?i32 = null;
    if (false) {
        the_fd = try std.posix.dup(0);
    }

    self.child = try io.spawn(self.allocator, args, the_fd);

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

    while (self.decoder.data.len > 0) {
        self.rpc.process(&self.decoder) catch |err| {
            switch (err) {
                error.EOFError => {
                    // dbg("!!interrupted. {} bytes left in state {}\n", .{ self.decoder.data.len, self.rpc.state });
                    break;
                },
                error.FlushCondition => {
                    // dbg("!!flushed. but {} bytes left in state {}\n", .{ self.decoder.data.len, self.rpc.state });
                    self.flush() catch @panic("NotLikeThis");
                    continue; // there might be more data after the flush
                },
                else => @panic("go crazy yea"),
            }
        };
    }

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

fn flush(self: *Self) !void {
    const ui = &self.rpc.ui;
    const g = ui.grid(1) orelse return;
    // TODO: buffered writing?
    const tty = self.tty.anyWriter();

    try tty.writeAll(ctlseqs.home);
    var attr_id: u32 = 0;
    for (0..g.rows) |row| {
        const basepos = row * g.cols;
        for (0..g.cols) |col| {
            const cell = g.cell.items[basepos + col];

            if (cell.attr_id != attr_id) {
                attr_id = cell.attr_id;
                const slice = if (attr_id > 0) theslice: {
                    // TODO: cached slices are still cool, but we should build them using vaxis
                    const islice = ui.attrs.items[attr_id];
                    break :theslice ui.attr_arena.items[islice.start..islice.end];
                } else ctlseqs.sgr_reset;
                try tty.writeAll(slice);
            }
            try tty.writeAll(ui.text(&cell));
        }
        try tty.writeAll("\r\n");
    }
    try tty.writeAll(ctlseqs.sgr_reset);
    try tty.print(ctlseqs.cup, .{ ui.cursor.row + 1, ui.cursor.col + 1 });
}

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    foo: u8,
};
