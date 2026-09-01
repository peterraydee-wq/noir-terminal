const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "noirterm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // needed for @cImport (d2d.zig) to see libc/mingw headers
        }),
    });
    exe.root_module.addIncludePath(b.path("src")); // so @cInclude("d2d_shim.h") resolves
    if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("user32", .{});
        exe.root_module.linkSystemLibrary("gdi32", .{});
        exe.root_module.linkSystemLibrary("kernel32", .{});
        exe.root_module.linkSystemLibrary("d2d1", .{});
        exe.root_module.linkSystemLibrary("dwrite", .{});
    }
    b.installArtifact(exe);

    // noirprompt: the standalone starship-style prompt-generator binary
    // (phase 7, "widgets") — a separate program, same as real starship,
    // not baked into the terminal itself. See prompt_main.zig's header
    // for how a shell invokes it.
    const prompt_exe = b.addExecutable(.{
        .name = "noirprompt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/prompt_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (target.result.os.tag == .windows) {
        prompt_exe.root_module.linkSystemLibrary("kernel32", .{});
    }
    b.installArtifact(prompt_exe);

    const run_prompt_cmd = b.addRunArtifact(prompt_exe);
    run_prompt_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_prompt_cmd.addArgs(args);
    const run_prompt_step = b.step("run-prompt", "Run noirprompt (pass an exit code as an arg, e.g. `zig build run-prompt -- 1`)");
    run_prompt_step.dependOn(&run_prompt_cmd.step);

    // noirfiles: the standalone file manager TUI binary (phase 8).
    const files_exe = b.addExecutable(.{
        .name = "noirfiles",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/filemanager_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (target.result.os.tag == .windows) {
        files_exe.root_module.linkSystemLibrary("kernel32", .{});
    }
    b.installArtifact(files_exe);
    const run_files_cmd = b.addRunArtifact(files_exe);
    run_files_cmd.step.dependOn(b.getInstallStep());
    const run_files_step = b.step("run-files", "Run noirfiles (the file manager TUI)");
    run_files_step.dependOn(&run_files_cmd.step);

    // noirplay: the standalone music player TUI binary (phase 8).
    const play_exe = b.addExecutable(.{
        .name = "noirplay",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/musicplayer_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (target.result.os.tag == .windows) {
        play_exe.root_module.linkSystemLibrary("kernel32", .{});
        play_exe.root_module.linkSystemLibrary("winmm", .{});
    }
    b.installArtifact(play_exe);
    const run_play_cmd = b.addRunArtifact(play_exe);
    run_play_cmd.step.dependOn(b.getInstallStep());
    const run_play_step = b.step("run-play", "Run noirplay (the music player TUI)");
    run_play_step.dependOn(&run_play_cmd.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run noirterm");
    run_step.dependOn(&run_cmd.step);

    // Unit tests live alongside their modules (see src/vt/parser.zig,
    // src/grid.zig, src/layout.zig).
    const parser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vt/parser.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const grid_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/grid.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const layout_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/layout.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const kitty_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kitty_graphics.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const theme_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/theme.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const gitinfo_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gitinfo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const prompt_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/prompt.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(parser_tests).step);
    test_step.dependOn(&b.addRunArtifact(grid_tests).step);
    test_step.dependOn(&b.addRunArtifact(layout_tests).step);
    test_step.dependOn(&b.addRunArtifact(kitty_tests).step);
    test_step.dependOn(&b.addRunArtifact(theme_tests).step);
    test_step.dependOn(&b.addRunArtifact(gitinfo_tests).step);
    test_step.dependOn(&b.addRunArtifact(prompt_tests).step);
}
