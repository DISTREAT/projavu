const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("projavu-lib", "src/lib.zig");
    const exe = b.addExecutable("projavu", "src/cli.zig");
    const tests = b.addTest("src/tests.zig");

    const zig_csv = std.build.Pkg{
        .name = "zig-csv",
        .source = .{ .path = "lib/zig-csv/src/zig-csv.zig" },
    };

    const zig_argtic = std.build.Pkg{
        .name = "zig-argtic",
        .source = .{ .path = "lib/zig-argtic/src/zig-argtic.zig" },
    };

    lib.addPackage(zig_csv);
    exe.addPackage(zig_csv);
    exe.addPackage(zig_argtic);
    tests.addPackage(zig_csv);

    exe.addIncludePath("lib/ctable/src");
    exe.addCSourceFile("lib/ctable/src/table.c", &[_][]const u8{});
    exe.addCSourceFile("lib/ctable/src/string_builder.c", &[_][]const u8{});
    exe.addCSourceFile("lib/ctable/src/string_util.c", &[_][]const u8{});
    exe.addCSourceFile("lib/ctable/src/vector.c", &[_][]const u8{});
    exe.addIncludePath("lib/levenshtein.c");
    exe.addCSourceFile("lib/levenshtein.c/levenshtein.c", &[_][]const u8{});
    exe.linkLibC();

    lib.setBuildMode(mode);
    exe.setBuildMode(mode);

    lib.setTarget(target);
    exe.setTarget(target);

    lib.emit_docs = .emit;

    lib.install();
    exe.install();

    const exe_run = exe.run();
    if (b.args) |args| {
        exe_run.addArgs(args);
    }

    const lib_step = b.step("lib", "Build the library");
    const tests_step = b.step("test", "Run all unit tests");
    const exe_step = b.step("exe", "Build the executable");
    const exe_run_step = b.step("run", "Run the executable");

    lib_step.dependOn(&lib.step);
    tests_step.dependOn(&tests.step);
    exe_step.dependOn(&exe.step);
    exe_run_step.dependOn(&exe_run.step);
}
