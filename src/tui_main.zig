const std = @import("std");
const vaxis = @import("vaxis");
const xev = @import("xev");

const Self = @This();
parser: vaxis.Parser,

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var tty = try vaxis.Tty.init();
    defer tty.deinit();

    const ttyw = tty.anyWriter();

    var vx = try vaxis.init(alloc, .{});
    defer vx.deinit(alloc, ttyw);

    // try vx.enterAltScreen(ttyw);

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    const stream = xev.Stream.initFd(tty.fd);
    defer stream.deinit();

    var read_buf: [1024]u8 = undefined;

    var c: xev.Completion = undefined;
    var self: Self = .{ .parser = .{ .grapheme_data = &vx.unicode.width_data.g_data } };
    stream.read(&loop, &c, .{ .slice = &read_buf }, Self, &self, readCb);

    std.debug.print("enter\r\n", .{});
    try loop.run(.until_done);
    std.debug.print("exit\r\n", .{});
}

fn readCb(
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
        std.debug.print("event {}\r\n", .{event});
    }

    if (n > 0 and slice[0] == 3) {
        return .disarm;
    }

    return .rearm;
}

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    foo: u8,
};
