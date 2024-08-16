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
};

state: State = .next_msg,
redraw_events: u64 = 0,

pub fn init(allocator: mem.Allocator) Self {
    _ = allocator;
    return .{};
}

pub fn process(self: *Self, decoder: *mpack.Decoder) !void {
    std.debug.print("haii {}\n", .{decoder.data.len});

    while (true) {
        const res = try switch (self.state) {
            .next_msg => self.next_msg(decoder),
            .redraw_event => self.redraw_event(decoder),
        };

        self.state = res orelse return;
    }
    // TODO: EAGAIN!
}

fn next_msg(self: *Self, base_decoder: *mpack.Decoder) !?State {
    var decoder = base_decoder.copy();
    const tok = try decoder.expectArray() orelse return null;
    if (tok < 3) return error.MalformatedRPCMessage;
    const num = try decoder.expectUInt() orelse return null;
    if (num != 2) @panic("handle replies and requests");
    if (tok != 3) return error.MalformatedRPCMessage;

    const name = try decoder.expectString() orelse return null;

    if (!std.mem.eql(u8, name, "redraw")) @panic("handle notifications other than 'redraw'");

    self.redraw_events = try decoder.expectArray() orelse return null;
    base_decoder.accept(decoder);
    return .redraw_event;
}

fn redraw_event(self: *Self, base_decoder: *mpack.Decoder) !?State {
    if (self.redraw_events == 0) {
        return .next_msg;
    }

    var decoder = base_decoder.copy();
    const nitems = try decoder.expectArray() orelse return null;
    if (nitems < 1) return error.MalformatedRPCMessage;
    const name = try decoder.expectString() orelse return null;

    dbg("EVENT: '{s}' with {}\n", .{ name, nitems - 1 });

    base_decoder.accept(decoder);
    std.posix.exit(0);
}
