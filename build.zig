const std = @import("std");

const errno_src = blk: {
    @setEvalBranchQuota(50_000);
    var fields: []const u8 = "";
    var prongs: []const u8 = "";
    for (@typeInfo(std.os.linux.E).@"enum".fields) |f| {
        if (std.mem.eql(u8, f.name, "SUCCESS")) continue;
        fields = fields ++ "    @\"" ++ f.name ++ "\",\n";
        prongs = prongs ++ "        .@\"" ++ f.name ++
            "\" => return error.@\"" ++ f.name ++ "\",\n";
    }
    break :blk "const std = @import(\"std\");\n\n" ++
        "pub const LinuxError = error{\n" ++
        fields ++
        "    Unexpected,\n};\n\n" ++
        "pub fn check(rc: usize) LinuxError!void {\n" ++
        "    switch (std.os.linux.errno(rc)) {\n" ++
        "        .SUCCESS => return,\n" ++
        prongs ++
        "        else => return error.Unexpected,\n" ++
        "    }\n}\n\n" ++
        "pub fn checkFd(rc: usize) LinuxError!i32 {\n" ++
        "    try check(rc);\n" ++
        "    return @intCast(rc);\n}\n";
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const prof_mod = b.createModule(.{
        .root_source_file = b.path("src/prof.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "profiler",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "prof", .module = prof_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const wf = b.addWriteFiles();
    const errno_file = wf.add("linux_error.zig", errno_src);
    exe.root_module.addAnonymousImport("linux_error", .{ .root_source_file = errno_file });

    const setcap_cmd = b.addSystemCommand(&.{ "sudo", "setcap", "cap_perfmon+ep" });
    setcap_cmd.addArtifactArg(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.step.dependOn(&setcap_cmd.step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
