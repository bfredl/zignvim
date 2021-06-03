const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("zignvim", "src/main.zig");
    lib.setBuildMode(mode);
    lib.install();

    const exe = b.addExecutable("iotest", "src/io.zig");
    exe.linkSystemLibrary("c");
    exe.linkSystemLibrary("uv");
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
    // test_step.dependOn(&main_tests.step);
    iotest_step.dependOn(&run.step);
}
