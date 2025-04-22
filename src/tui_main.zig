const std = @import("std");
const vaxis = @import("vaxis");
const xev = @import("xev");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var tty = try vaxis.Tty.init();
    defer tty.deinit();

    var vx = try vaxis.init(alloc, .{});
    defer vx.deinit(alloc, tty.anyWriter());

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    const stream = xev.Stream.initFd(tty.fd);
    defer stream.deinit();

    var read_buf: [1024]u8 = undefined;

    var c: xev.Completion = undefined;
    var self: void = {};
    stream.read(&loop, &c, .{ .slice = &read_buf }, void, &self, readCb);

    std.debug.print("enter\r\n", .{});
    try loop.run(.until_done);
    std.debug.print("exit\r\n", .{});
}

fn readCb(
    self_: ?*void,
    loop: *xev.Loop,
    c: *xev.Completion,
    stream: xev.Stream,
    buf: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    _ = loop;
    _ = c;
    _ = stream;
    _ = self_;
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

    std.debug.print("Nommm {}\r\n", .{n});
    const slice = buf.slice[0..n];
    if (n > 0) std.debug.print("som {}\r\n", .{slice[0]});
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
