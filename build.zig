const std = @import("std");

pub fn build(b: *std.Build) !void {
    const t = b.standardTargetOptions(.{});
    const opt = b.standardOptimizeOption(.{});
    const llvm = b.option(bool, "llvm", "use llvm") orelse true;
    const use_vaxis = b.option(bool, "vaxis", "use vaxis") orelse false;
    const use_gtk = b.option(bool, "gtk", "use gtk") orelse false;

    if (!use_vaxis and !use_gtk) {
        std.debug.print("use at least one of -Dvaxis or -Dgtk!", .{});
        return error.ConfigError;
    }

    const io_test = b.step("io_test", "fooka amnitel");
    const io_test_exe = b.addExecutable(.{
        .name = "io_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/io_test.zig"),
            .optimize = opt,
            .target = t,
        }),
    });
    b.installArtifact(io_test_exe);
    const run_cmd = b.addRunArtifact(io_test_exe);
    io_test.dependOn(&run_cmd.step);

    if (use_vaxis) {
        const vaxis = b.lazyDependency("vaxis", .{ .optimize = opt, .target = t }) orelse return;
        const xev = b.lazyDependency("xev", .{ .optimize = opt, .target = t }) orelse return;
        const tui_step = b.step("tui", "terminal representation");
        const exe_tui = b.addExecutable(.{
            .name = "zignvim_tui",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tui_main.zig"),
                .optimize = opt,
                .target = t,
            }),
        });
        exe_tui.root_module.addImport("vaxis", vaxis.module("vaxis"));
        exe_tui.root_module.addImport("xev", xev.module("xev"));
        exe_tui.use_llvm = llvm;
        b.installArtifact(exe_tui);
        const tui_run_cmd = b.addRunArtifact(exe_tui);
        if (b.args) |args| {
            tui_run_cmd.addArgs(args);
        }
        tui_step.dependOn(&tui_run_cmd.step);
    }

    if (use_gtk) {
        const gtk_test = b.step("gtk_test", "visual representation");
        const exe_gtk = b.addExecutable(.{
            .name = "zignvim_gtk",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/gtk_main.zig"),
                .optimize = opt,
                .target = t,
                .link_libc = true,
            }),
        });
        exe_gtk.use_llvm = llvm;
        exe_gtk.root_module.linkSystemLibrary("gtk4", .{});
        exe_gtk.root_module.linkSystemLibrary("ibus-1.0", .{});
        b.installArtifact(exe_gtk);
        const gtk_run_cmd = b.addRunArtifact(exe_gtk);
        if (b.args) |args| {
            gtk_run_cmd.addArgs(args);
        }
        gtk_test.dependOn(&gtk_run_cmd.step);

        const pango_test = b.step("pango_test", "visual representation");
        const exe_pango = b.addExecutable(.{
            .name = "pango_test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/pango_test.zig"),
                .optimize = opt,
                .target = t,
                .link_libc = true,
            }),
        });
        exe_pango.use_llvm = llvm;
        exe_pango.root_module.linkSystemLibrary("gtk4", .{});
        exe_pango.root_module.linkSystemLibrary("ibus-1.0", .{}); // TODO: OPTIONAL!
        b.installArtifact(exe_pango);
        const pango = b.addRunArtifact(exe_pango);
        if (b.args) |args| {
            pango.addArgs(args);
        }
        pango_test.dependOn(&pango.step);
    }
}
