const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const terence_css = b.addModule("terence_css", .{
        .root_source_file = b.path("src/terence_css.zig"),
    });

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("terence_css", terence_css);

    const exe = b.addExecutable(.{
        .name = "terence-css",
        .root_module = exe_module,
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("corpus", b.createModule(.{
        .root_source_file = b.path("test/corpus.zig"),
    }));

    const tests = b.addTest(.{ .root_module = test_module });

    const run_tests = b.addRunArtifact(tests);

    const public_api_test_module = b.createModule(.{
        .root_source_file = b.path("test/terence_css_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    public_api_test_module.addImport("terence_css", terence_css);
    const public_api_tests = b.addTest(.{
        .root_module = public_api_test_module,
    });
    const run_public_api_tests = b.addRunArtifact(public_api_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_public_api_tests.step);
}
