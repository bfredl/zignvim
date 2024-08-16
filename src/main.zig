const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const ChildProcess = std.ChildProcess;
const StdIo = ChildProcess.StdIo;

const Neovim = struct {
    nvim_child_proc: *std.ChildProcess,
    allocator: *mem.Allocator,

    pub fn spawn(a: *mem.Allocator, optional_argv: ?[]const []const u8) !Neovim {
        const argv = optional_argv orelse &[_][]const u8{ "nvim", "--embed" };
        const child = try std.ChildProcess.init(argv, a);
        errdefer child.deinit();

        child.stdout_behavior = StdIo.Pipe;
        child.stdin_behavior = StdIo.Pipe;
        child.stderr_behavior = StdIo.Pipe;

        _ = try child.spawn();

        return Neovim{ .nvim_child_proc = child, .allocator = a };
    }

    pub fn do_nothing(x: c_int) void {}

    pub fn call(self: Neovim, function_name: []const u8) !void {}

    pub fn deinit(self: Neovim) void {
        self.nvim_child_proc.deinit();
    }
};

test "whatever yo" {
    const nvim = try Neovim.spawn(std.heap.c_allocator, null);
    defer nvim.deinit();

    _ = try nvim.call("nvim_eval");

    var buffer: [5]u8 = undefined;
    _ = try nvim.nvim_child_proc.stdout.?.read(&buffer);
}
