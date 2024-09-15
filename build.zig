const std = @import("std");

pub fn build(b: *std.Build) void {
    const t = b.standardTargetOptions(.{});
    const opt = b.standardOptimizeOption(.{});

    const io_test = b.step("io_test", "fooka amnitel");
    const io_test_exe = b.addExecutable(.{
        .name = "io_test",
        .root_source_file = b.path("src/io_test.zig"),
        .optimize = opt,
        .target = t,
    });
    b.installArtifact(io_test_exe);
    const run_cmd = b.addRunArtifact(io_test_exe);
    io_test.dependOn(&run_cmd.step);

    const gtk_test = b.step("gtk_test", "visual representation");
    const exe_gtk = b.addExecutable(.{
        .name = "zignvim_gtk",
        .root_source_file = b.path("src/gtk_main.zig"),
        .optimize = opt,
        .target = t,
    });
    exe_gtk.linkLibC();
    exe_gtk.linkSystemLibrary("gtk4");
    exe_gtk.linkSystemLibrary("ibus-1.0");
    b.installArtifact(exe_gtk);
    const gtk_run_cmd = b.addRunArtifact(exe_gtk);
    if (b.args) |args| {
        gtk_run_cmd.addArgs(args);
    }
    gtk_test.dependOn(&gtk_run_cmd.step);

    const pango_test = b.step("pango_test", "visual representation");
    const exe_pango = b.addExecutable(.{
        .name = "pango_test",
        .root_source_file = b.path("src/pango_test.zig"),
        .optimize = opt,
        .target = t,
    });
    exe_pango.linkLibC();
    exe_pango.linkSystemLibrary("gtk4");
    exe_pango.linkSystemLibrary("ibus-1.0"); // TODO: OPTIONAL!
    b.installArtifact(exe_pango);
    const pango = b.addRunArtifact(exe_pango);
    if (b.args) |args| {
        pango.addArgs(args);
    }
    pango_test.dependOn(&pango.step);

    if (false) {
        const mode = b.standardReleaseOptions();
        const lib = b.addStaticLibrary("zignvim", "src/main.zig");
        lib.setBuildMode(mode);
        //lib.install();

        const exe_uv = b.addExecutable("iotest_uv", "src/io_uv.zig");
        exe_uv.linkSystemLibrary("c");
        exe_uv.linkSystemLibrary("uv");
        exe_uv.setBuildMode(mode);
        // exe_uv.install();

        const exe = b.addExecutable("iotest", "src/io_test.zig");
        exe.setBuildMode(mode);
        exe.install();

        var main_tests = b.addTest("src/main.zig");
        main_tests.setBuildMode(mode);

        var msgpack_tests = b.addTest("src/mpack.zig");
        msgpack_tests.setBuildMode(mode);

        const test_step = b.step("test", "Run library tests");
        // test_step.dependOn(&main_tests.step);
        test_step.dependOn(&msgpack_tests.step);

        const iotest_step = b.step("iotest", "Basic ");
        const run = exe.run();
        iotest_step.dependOn(&run.step);

        const gtktest_step = b.step("gtktest", "Accomplished ");
        const gtkrun = exe_gtk.run();
        gtktest_step.dependOn(&gtkrun.step);
    }
}
