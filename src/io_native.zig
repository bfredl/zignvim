const std = @import("std");
const mem = std.mem;
const stringToEnum = std.meta.stringToEnum;
const dbg = std.debug.print;
//pub fn dbg(a: anytype, b: anytype) void {}
const mpack = @import("./mpack.zig");
const ArrayList = std.ArrayList;

const ChildProcess = std.ChildProcess;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const argv = &[_][]const u8{ "nvim", "--embed" };
    //const argv = &[_][]const u8{ "nvim", "--embed", "-u", "NORC" };
    const child = try std.ChildProcess.init(argv, &gpa.allocator);
    defer child.deinit();

    child.stdout_behavior = ChildProcess.StdIo.Pipe;
    child.stdin_behavior = ChildProcess.StdIo.Pipe;
    child.stderr_behavior = ChildProcess.StdIo.Inherit;

    try child.spawn();

    var stdin = &child.stdin.?;
    var stdout = &child.stdout.?;

    const ByteArray = ArrayList(u8);
    var x = ByteArray.init(&gpa.allocator);
    defer x.deinit();
    var encoder = mpack.Encoder(ByteArray.Writer){ .writer = x.writer() };

    if (false) {
        try encoder.putArrayHead(4);
        try encoder.putInt(0); // request
        try encoder.putInt(0); // msgid
        try encoder.putStr("nvim_get_api_info");
        try encoder.putArrayHead(0);
    } else {
        try encoder.putArrayHead(4);
        try encoder.putInt(0); // request
        try encoder.putInt(0); // msgid
        try encoder.putStr("nvim_ui_attach");
        try encoder.putArrayHead(3);
        try encoder.putInt(80); // width
        try encoder.putInt(24); // height
        try encoder.putMapHead(1);
        try encoder.putStr("ext_linegrid");
        try encoder.putBool(true);
    }

    try stdin.writeAll(x.items);
    var buf: [1024]u8 = undefined;
    var lenny = try stdout.read(&buf);
    var decoder = mpack.Decoder{ .data = buf[0..lenny] };
    var state = init_state(&gpa.allocator);
    var decodeFrame = async decodeLoop(&decoder, &state);

    // @compileLog(@sizeOf(@Frame(decodeLoop)));
    // 11920 with fully async readHead()
    // 5928 without

    while (decoder.frame != null) {
        const oldlen = decoder.data.len;
        if (oldlen > 0 and decoder.data.ptr != &buf) {
            // TODO: avoid move if remaining space is plenty (like > 900)
            std.mem.copy(u8, &buf, decoder.data);
        }
        lenny = try stdout.read(buf[oldlen..]);
        decoder.data = buf[0 .. oldlen + lenny];

        resume decoder.frame.?;
    }

    try nosuspend await decodeFrame;
}

const State = struct {
    const AttrOffset = struct { start: u32, end: u32 };
    attr_arena: ArrayList(u8),
    attr_off: ArrayList(AttrOffset),

    hl_id: u32,
};

fn init_state(allocator: *mem.Allocator) State {
    return .{
        .attr_arena = ArrayList(u8).init(allocator),
        .attr_off = ArrayList(State.AttrOffset).init(allocator),
        .hl_id = 0,
    };
}

const RPCError = mpack.Decoder.Error || error{
    MalformatedRPCMessage,
    InvalidRedraw,
    OutOfMemory,
};

fn decodeLoop(decoder: *mpack.Decoder, state: *State) RPCError!void {
    while (true) {
        try decoder.start();
        var msgHead = try decoder.expectArray();
        if (msgHead < 3) {
            return RPCError.MalformatedRPCMessage;
        }

        var msgKind = try decoder.expectUInt();
        switch (msgKind) {
            1 => try decodeResponse(decoder, msgHead),
            2 => try decodeEvent(decoder, state, msgHead),
            else => return error.MalformatedRPCMessage,
        }
    }
}

fn decodeResponse(decoder: *mpack.Decoder, arraySize: u32) RPCError!void {
    if (arraySize != 4) {
        return error.MalformatedRPCMessage;
    }
    var id = try decoder.expectUInt();
    dbg("id: {}\n", .{id});
    var state = try decoder.readHead();
    dbg("{}\n", .{state});
    state = try decoder.readHead();
    dbg("{}\n", .{state});
}

fn decodeEvent(decoder: *mpack.Decoder, state: *State, arraySize: u32) RPCError!void {
    if (arraySize != 3) {
        return error.MalformatedRPCMessage;
    }
    var name = try decoder.expectString();
    if (mem.eql(u8, name, "redraw")) {
        try handleRedraw(decoder, state);
    } else {
        // TODO: untested
        dbg("FEEEEL: {s}\n", .{name});
        try decoder.skipAhead(1); // args array
    }
}

const RedrawEvents = enum {
    hl_attr_define,
    hl_group_set,
    grid_line,
    flush,
    Unknown,
};

fn handleRedraw(decoder: *mpack.Decoder, state: *State) RPCError!void {
    dbg("==BEGIN REDRAW\n", .{});
    var args = try decoder.expectArray();
    dbg("n-event: {}\n", .{args});
    while (args > 0) : (args -= 1) {
        const saved = try decoder.push();
        const iargs = try decoder.expectArray();
        const iname = try decoder.expectString();
        const event = stringToEnum(RedrawEvents, iname) orelse .Unknown;
        switch (event) {
            .grid_line => try handleGridLine(decoder, state, iargs - 1),
            .flush => {
                //if (iargs != 2 or try decoder.expectArray() > 0) {
                //    return error.InvalidRedraw;
                // }
                try decoder.skipAhead(iargs - 1);

                dbg("==FLUSHED\n", .{});
            },
            .hl_attr_define => {
                try handleHlAttrDef(decoder, state, iargs - 1);
            },
            .hl_group_set => {
                try decoder.skipAhead(iargs - 1);
            },
            .Unknown => {
                dbg("! {s} {}\n", .{ iname, iargs - 1 });
                try decoder.skipAhead(iargs - 1);
            },
        }
        try decoder.pop(saved);
    }
    dbg("==DUN REDRAW\n\n", .{});
}

fn handleGridLine(decoder: *mpack.Decoder, state: *State, nlines: u32) RPCError!void {
    dbg("==LINES {}\n", .{nlines});
    var i: u32 = 0;
    while (i < nlines) : (i += 1) {
        const saved = try decoder.push();
        const iytem = try decoder.expectArray();
        const grid = try decoder.expectUInt();
        const row = try decoder.expectUInt();
        const col = try decoder.expectUInt();
        const ncells = try decoder.expectArray();
        dbg("LINE: {} {} {} {}: [", .{ grid, row, col, ncells });
        var j: u32 = 0;
        while (j < ncells) : (j += 1) {
            const nsize = try decoder.expectArray();
            const str = try decoder.expectString();
            var used: u8 = 1;
            var repeat: u64 = 1;
            var hl_id: u32 = state.hl_id;

            if (nsize >= 2) {
                hl_id = @intCast(u32, try decoder.expectUInt());
                used = 2;
                if (nsize >= 3) {
                    repeat = try decoder.expectUInt();
                    used = 3;
                }
            }
            if (hl_id != state.hl_id) {
                state.hl_id = hl_id;
                const islice = state.attr_off.items[hl_id];
                const slice = state.attr_arena.items[islice.start..islice.end];
                dbg("{s}", .{slice});
            }
            while (repeat > 0) : (repeat -= 1) {
                dbg("{s}", .{str});
            }
            try decoder.skipAhead(nsize - used);
        }
        dbg("]\n", .{});

        try decoder.skipAhead(iytem - 4);

        try decoder.pop(saved);
    }
}

//const native_endian = std.Target.current.cpu.arch.endian();
const RGB = struct { a: u8, r: u8, g: u8, b: u8 };

fn doColors(w: anytype, fg: bool, rgb: RGB) RPCError!void {
    const kod = if (fg) "3" else "4";
    try w.print("\x1b[{s}8;2;{};{};{}m", .{ kod, rgb.r, rgb.g, rgb.b });
}

fn handleHlAttrDef(decoder: *mpack.Decoder, state: *State, nattrs: u32) RPCError!void {
    dbg("==ATTRS {}\n", .{nattrs});
    var i: u32 = 0;
    while (i < nattrs) : (i += 1) {
        const saved = try decoder.push();
        const nsize = try decoder.expectArray();
        const id = try decoder.expectUInt();
        const rgb_attrs = try decoder.expectMap();
        dbg("ATTEN: {} {}", .{ id, rgb_attrs });
        var j: u32 = 0;
        while (j < rgb_attrs) : (j += 1) {
            const name = try decoder.expectString();
            const Keys = enum { foreground, background, bold, Unknown };
            const key = stringToEnum(Keys, name) orelse .Unknown;
            var fg: ?u32 = null;
            switch (key) {
                .foreground => {
                    const num = try decoder.expectUInt();
                    dbg(" fg={}", .{num});
                    fg = @intCast(u32, num);
                },
                .background => {
                    const num = decoder.expectUInt();
                    dbg(" bg={}", .{num});
                },
                .bold => {
                    _ = try decoder.readHead();
                    dbg(" BOLDEN", .{});
                },
                .Unknown => {
                    dbg(" {s}", .{name});
                    try decoder.skipAhead(1);
                },
            }
            const pos = @intCast(u32, state.attr_arena.items.len);
            const w = state.attr_arena.writer();
            if (fg) |the_fg| {
                const rgb = @bitCast(RGB, the_fg);
                try doColors(w, true, rgb);
            } else {
                try w.writeAll("\x1b[0m");
            }
            const endpos = @intCast(u32, state.attr_arena.items.len);
            try state.attr_off.append(.{ .start = pos, .end = endpos });
        }
        dbg("\n", .{});

        try decoder.skipAhead(nsize - 2);
        try decoder.pop(saved);
    }
}
