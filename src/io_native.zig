const std = @import("std");
const mem = std.mem;
const mpack = @import("./mpack.zig");
const RPCState = @import("./RPCState.zig");

const Child = std.process.Child;

const os = std.os;

pub fn spawn(gpa: mem.Allocator, io: std.Io, nvim_exe: ?[]const u8, args: []const ?[*:0]const u8, stdin_fd: ?i32) !std.process.Child {
    //const argv = &[_][]const u8{ "nvim", "--embed" };
    const base_argv = &[_][]const u8{ nvim_exe orelse "nvim", "--embed" };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, base_argv);
    for (args) |arg| {
        try argv.append(gpa, mem.span(arg.?));
    }

    if (stdin_fd) |_| unreachable;
    const child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdout = .pipe,
        .stdin = .pipe,
        .stderr = .inherit,
        // .bonus_fd = stdin_fd;
    });

    return child;
}

pub fn attach(encoder: mpack.Encoder, width: u32, height: u32, stdin_fd: ?i32, multigrid: bool) !void {
    if (false) {
        try encoder.putArrayHead(4);
        try encoder.putInt(0); // request
        try encoder.putInt(0); // msgid
        try encoder.putStr("nvim_get_api_info");
        try encoder.putArrayHead(0);
    } else {
        if (false) {
            // we prefer this once we have implemented replies..
            try encoder.putArrayHead(4);
            try encoder.putInt(0); // request
            try encoder.putInt(0); // msgid
        } else {
            try encoder.putArrayHead(3);
            try encoder.putInt(2); // notify
        }

        try encoder.putStr("nvim_ui_attach");
        try encoder.putArrayHead(3);
        try encoder.putInt(width);
        try encoder.putInt(height);
        const EINS: u32 = 1;
        const items: u32 = 1 + (if (stdin_fd != null) EINS else 0) + (if (multigrid) EINS else 0);
        try encoder.putMapHead(items);
        try encoder.putStr("ext_linegrid");
        try encoder.putBool(true);
        if (stdin_fd) |fd| {
            try encoder.putStr("stdin_fd");
            try encoder.putInt(fd);
        }
        if (multigrid) {
            try encoder.putStr("ext_multigrid");
            try encoder.putBool(true);
        }
    }
}

pub fn unsafe_input(encoder: mpack.Encoder, input: []const u8) !void {
    try encoder.putArrayHead(3);
    try encoder.putInt(2); // notify
    try encoder.putStr("nvim_input");
    try encoder.putArrayHead(1);
    try encoder.putStr(input);
}

pub fn try_resize(encoder: mpack.Encoder, grid: u32, width: u32, height: u32) !void {
    try encoder.putArrayHead(3);
    try encoder.putInt(2); // notify
    try encoder.putStr("nvim_ui_try_resize_grid");
    try encoder.putArrayHead(3);
    try encoder.putInt(grid);
    try encoder.putInt(width);
    try encoder.putInt(height);
}
