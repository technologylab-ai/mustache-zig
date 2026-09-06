const std = @import("std");

pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, @import("builtin").zig_version_string, std.mem.trim(u8, @embedFile(".zig-version"), " \r\n")))
        @panic("Use exactly the Zig release in .zig-version");
    const mode = b.standardOptimizeOption(.{});

    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_model = .baseline,
        },
    });

    // Zig module
    const module = b.addModule("mustache", .{ .root_source_file = b.path("src/mustache.zig"), .target = target, .optimize = mode });

    // Tests

    var comptime_tests = b.addOptions();
    // TODO: Re-enable comptime tests
    const comptime_tests_enabled = b.option(bool, "comptime-tests", "Run comptime tests") orelse false;
    comptime_tests.addOption(bool, "comptime_tests_enabled", comptime_tests_enabled);
    module.addOptions("build_comptime_tests", comptime_tests);
    const verify = b.step("verify", "Run runtime, official core specification, and Zap compatibility tests");
    const check = b.step("check", "Compile verification suites without executing target binaries");
    const format = b.addFmt(.{ .paths = &.{ "build.zig", "build.zig.zon", "src", "tests" }, .check = true });
    verify.dependOn(&format.step);
    check.dependOn(&format.step);
    for ([_][]const u8{ "spec", "zap" }) |name| {
        const suite = b.addTest(.{ .name = name, .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("tests/{s}.zig", .{name})),
            .target = target,
            .optimize = mode,
            .imports = &.{.{ .name = "mustache", .module = module }},
        }) });
        check.dependOn(&suite.step);
        const run = b.addRunArtifact(suite);
        verify.dependOn(&run.step);
    }

    {
        const filter = b.option(
            []const u8,
            "test-filter",
            "Skip tests that do not match filter",
        );
        if (filter) |filter_value| std.log.debug("filter: {s}", .{filter_value});

        const test_mod = b.createModule(.{
            .root_source_file = b.path("src/mustache.zig"),
            .target = target,
            .optimize = mode,
        });
        test_mod.addOptions("build_comptime_tests", comptime_tests);

        const main_tests = b.addTest(.{
            .name = "tests",
            .root_module = test_mod,
            .filters = if (filter) |f| &.{f} else &.{},
        });

        const coverage = b.option(bool, "test-coverage", "Generate test coverage") orelse false;

        const run_main_tests = b.addRunArtifact(main_tests);
        verify.dependOn(&run_main_tests.step);
        check.dependOn(&main_tests.step);

        if (coverage) {
            // with kcov
            const kcov = b.addSystemCommand(&.{
                "kcov",    "--exclude-pattern",
                "lib/std", "kcov-output",
            });
            kcov.addArtifactArg(main_tests);

            run_main_tests.step.dependOn(&kcov.step);
        }

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_main_tests.step);
    }

    {
        const test_exe_mod = b.createModule(.{
            .root_source_file = b.path("src/mustache.zig"),
            .target = target,
            .optimize = mode,
        });
        test_exe_mod.addOptions("build_comptime_tests", comptime_tests);

        const test_exe = b.addTest(.{
            .name = "tests",
            .root_module = test_exe_mod,
        });

        const test_exe_install = b.addInstallArtifact(test_exe, .{});

        const test_build = b.step("build_tests", "Build library tests");
        test_build.dependOn(&test_exe_install.step);
    }
}
