const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "projavu-lib",
        .root_source_file = .{ .cwd_relative = "src/lib.zig" },
        .target = target,
        .optimize = optimize,
    });
    lib.want_lto = true;
    const exe = b.addExecutable(.{
        .name = "projavu",
        .root_source_file = .{ .cwd_relative = "src/cli.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    const tests = b.addTest(.{
        .root_source_file = .{ .cwd_relative = "src/tests.zig" },
        .target = target,
        .optimize = optimize,
    });
    const docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const zig_csv = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "lib/zig-csv/src/zig-csv.zig" },
    });

    const zig_argtic = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "lib/zig-argtic/src/zig-argtic.zig" },
    });

    lib.root_module.addImport("zig-csv", zig_csv);
    exe.root_module.addImport("zig-csv", zig_csv);
    exe.root_module.addImport("zig-argtic", zig_argtic);
    tests.root_module.addImport("zig-csv", zig_csv);

    const ctable_dir = "lib/ctable/src";
    exe.addIncludePath(.{ .cwd_relative = ctable_dir });
    exe.addCSourceFiles(.{
        .files = &.{
            ctable_dir ++ "/table.c",
            ctable_dir ++ "/string_builder.c",
            ctable_dir ++ "/string_util.c",
            ctable_dir ++ "/vector.c",
        },
        .flags = &.{},
    });
    const levenshtein_dir = "lib/levenshtein.c";
    exe.addIncludePath(.{ .cwd_relative = levenshtein_dir });
    exe.addCSourceFiles(.{
        .files = &.{
            levenshtein_dir ++ "/levenshtein.c",
        },
        .flags = &.{},
    });

    b.installArtifact(lib);
    b.installArtifact(exe);

    const exe_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        exe_cmd.addArgs(args);
    }

    const tests_step = b.step("test", "Run unit tests");
    const exe_run_step = b.step("run", "Run the application");
    const docs_step = b.step("docs", "Generate library documentation");

    tests_step.dependOn(&b.addRunArtifact(tests).step);
    exe_run_step.dependOn(&exe_cmd.step);
    docs_step.dependOn(&docs.step);
}
