const std = @import("std");
const mpack = @import("./mpack.zig");
const ArrayList = std.ArrayList;
const mem = std.mem;
const stringToEnum = std.meta.stringToEnum;
const Self = @This();
const dbg = std.debug.print;

const State = enum {
    next_msg,
    notify_redraw,
};

state: State = .next_msg,

pub fn init(allocator: mem.Allocator) Self {
    _ = allocator;
    return .{};
}

pub fn process(self: *Self, decoder: *mpack.Decoder) !void {
    std.debug.print("haii {}\n", .{decoder.data.len});

    while (true) {
        const res = try switch (self.state) {
            .next_msg => self.next_msg(decoder),
            .notify_redraw => unreachable,
        };

        self.state = res orelse return;
    }
    // TODO: EAGAIN!
}

fn next_msg(self: *Self, base_decoder: *mpack.Decoder) !?State {
    _ = self;
    var decoder = base_decoder.copy();
    const tok = try decoder.expectArray() orelse return null;
    dbg("yarr: {}\n", .{tok});
    if (tok < 3) return error.MalformatedRPCMessage;
    const num = try decoder.expectUInt() orelse return null;
    dbg("num: {}\n", .{num});
    if (num != 2) @panic("handle replies and requests");
    const name = try decoder.expectString() orelse return null;
    dbg("name: {s}\n", .{name});

    base_decoder.accept(decoder);
    std.posix.exit(0);
}
