const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("zignvim", "src/main.zig");
    lib.setBuildMode(mode);
    //lib.install();

    const exe_uv = b.addExecutable("iotest_uv", "src/io_uv.zig");
    exe_uv.linkSystemLibrary("c");
    exe_uv.linkSystemLibrary("uv");
    exe_uv.setBuildMode(mode);
    // exe_uv.install();

    const exe_gtk = b.addExecutable("gtk_main", "src/gtk_main.zig");
    exe_gtk.linkLibC();
    exe_gtk.linkSystemLibrary("gtk4");
    exe_gtk.setBuildMode(mode);
    exe_gtk.install();

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
