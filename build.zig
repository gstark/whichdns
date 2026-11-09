//! Zig build graph for the executable, unit tests, and local run step.

const std = @import("std");
const version = @import("src/core/version.zig");

comptime {
    // The release script reads version.zig, and the package manager reads the manifest.
    const manifest_version = @import("build.zig.zon").version;
    if (!std.mem.eql(u8, manifest_version, version.string)) {
        @compileError("build.zig.zon version " ++ manifest_version ++ " does not match version.zig " ++ version.string);
    }
}

/// Configures POSIX targets and extra size optimizations for ReleaseSmall.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_mod = createModule(b, "src/core/root.zig", target, optimize);
    const exe_mod = createModule(b, "src/app/main.zig", target, optimize);
    exe_mod.addImport("core", core_mod);

    const exe = b.addExecutable(.{
        .name = "whichdns",
        .root_module = exe_mod,
    });
    if (target.result.os.tag == .linux) {
        exe.root_module.addCMacro("_POSIX_C_SOURCE", "200809L");
        exe.root_module.linkSystemLibrary("pthread", .{});
    }
    b.installArtifact(exe);

    const core_tests = b.addTest(.{ .root_module = core_mod });
    const app_test_mod = createModule(b, "src/app/root_test.zig", target, optimize);
    app_test_mod.addImport("core", core_mod);
    const app_tests = b.addTest(.{ .root_module = app_test_mod });

    const test_step = b.step("test", "Run unit tests for the core and the CLI");
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    test_step.dependOn(&b.addRunArtifact(app_tests).step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run whichdns");
    run_step.dependOn(&run_cmd.step);
}

/// Creates a libc-linked module. ReleaseSmall also drops symbols, unwind
/// tables, stack checks, and frame pointers. scripts/release-macos.sh must
/// pass the same flags.
fn createModule(
    b: *std.Build,
    root_source_file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const small = optimize == .ReleaseSmall;
    return b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = if (small) true else null,
        .unwind_tables = if (small) .none else null,
        .stack_check = if (small) false else null,
        .omit_frame_pointer = if (small) true else null,
    });
}
