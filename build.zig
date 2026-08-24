const std = @import("std");

// glibc 2.38 is the oldest userspace supported by the packaged release.
const aarch64_linux_query: std.Target.Query = .{
    .cpu_arch = .aarch64,
    .os_tag = .linux,
    .abi = .gnu,
    .glibc_version = .{ .major = 2, .minor = 38, .patch = 0 },
};

const c_test_flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" };

fn addHostZigObject(b: *std.Build, name: []const u8, source: []const u8) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path(source),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    });
    module.addIncludePath(b.path("src/media/video"));
    return b.addObject(.{ .name = name, .root_module = module });
}

fn addHostCExecutable(
    b: *std.Build,
    name: []const u8,
    sources: []const []const u8,
    objects: []const *std.Build.Step.Compile,
    link_dl: bool,
) *std.Build.Step.Compile {
    const executable = b.addExecutable(.{
        .name = name,
        .root_source_file = null,
        .target = b.graph.host,
        .optimize = .Debug,
    });
    executable.addIncludePath(b.path("src/media/video"));
    executable.addCSourceFiles(.{ .files = sources, .flags = c_test_flags });
    for (objects) |object| executable.addObject(object);
    executable.linkLibC();
    if (link_dl) executable.linkSystemLibrary("dl");
    return executable;
}

fn addHostCFakeLibrary(
    b: *std.Build,
    name: []const u8,
    source: []const u8,
) *std.Build.Step.Compile {
    const library = b.addSharedLibrary(.{
        .name = name,
        .root_source_file = null,
        .target = b.graph.host,
        .optimize = .Debug,
    });
    library.addIncludePath(b.path("src/media/video"));
    library.addCSourceFile(.{ .file = b.path(source), .flags = c_test_flags });
    library.linkLibC();
    return library;
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const aarch64_linux = b.resolveTargetQuery(aarch64_linux_query);

    const stat_compat = b.createModule(.{
        .root_source_file = b.path("src/platform/linux/stat_compat.zig"),
        .target = aarch64_linux,
        .optimize = optimize,
    });

    const smoke = b.addExecutable(.{
        .name = "greenovercast-smoke",
        .root_source_file = b.path("src/smoke/abi_smoke.zig"),
        .target = aarch64_linux,
        .optimize = optimize,
        .link_libc = true,
    });
    smoke.root_module.addImport("stat_compat", stat_compat);
    smoke.addCSourceFile(.{
        .file = b.path("src/smoke/cpp_probe.cpp"),
        .flags = &.{"-std=c++17"},
    });
    smoke.linkLibCpp();

    const smoke_install = b.addInstallArtifact(smoke, .{});
    const smoke_step = b.step("smoke", "Cross-build the aarch64 ABI smoke binary");
    smoke_step.dependOn(&smoke_install.step);
    b.default_step.dependOn(&smoke_install.step);

    const product_check = b.step("product-check", "Compile the aarch64 Zig product modules");
    const product_roots = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "greenovercast-main", .path = "src/main.zig" },
        .{ .name = "greenovercast-auth", .path = "src/auth/xbox_auth.zig" },
        .{ .name = "greenovercast-cloud", .path = "src/session/cloud_session.zig" },
        .{ .name = "greenovercast-controller", .path = "src/input/controller.zig" },
        .{ .name = "greenovercast-ui", .path = "src/ui/handheld_ui.zig" },
        .{ .name = "greenovercast-video-decoder", .path = "src/media/video/video_decoder.zig" },
        .{ .name = "greenovercast-video-decoder-selection", .path = "src/media/video/video_decoder_selection.zig" },
        .{ .name = "greenovercast-video-frame-copy", .path = "src/media/video/video_frame_copy.zig" },
    };
    const product_include_paths = [_][]const u8{
        "vendor/headers",
        "src/media/audio",
        "src/media/video",
        "src/media/rtp",
        "src/auth",
        "src/catalog",
        "src/input",
        "src/net",
        "src/platform",
        "src/session",
        "src/ui",
    };
    for (product_roots) |root| {
        const module = b.createModule(.{
            .root_source_file = b.path(root.path),
            .target = aarch64_linux,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        });
        for (product_include_paths) |include_path| module.addIncludePath(b.path(include_path));
        const object = b.addObject(.{ .name = root.name, .root_module = module });
        product_check.dependOn(&object.step);
    }

    const fmt_check = b.step("fmt-check", "Check zig fmt on project Zig sources");
    fmt_check.dependOn(&b.addFmt(.{
        .paths = &.{ "src", "build.zig" },
        .check = true,
    }).step);

    const test_step = b.step("test", "Run host unit tests");
    const test_roots = [_][]const u8{
        "src/app/state.zig",
        "src/catalog/catalog_parser.zig",
        "src/catalog/catalog_search.zig",
        "src/input/wire_encoder.zig",
        "src/media/rtp/h264_depacketizer.zig",
        "src/net/json_reader.zig",
        "src/net/json_writer.zig",
        "src/net/form_writer.zig",
    };
    for (test_roots) |root| {
        const unit_tests = b.addTest(.{
            .root_source_file = b.path(root),
            .target = b.graph.host,
            .optimize = .Debug,
        });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }

    const video_decoder_object =
        addHostZigObject(b, "video-decoder", "src/media/video/video_decoder.zig");
    const video_frame_copy_object =
        addHostZigObject(b, "video-frame-copy", "src/media/video/video_frame_copy.zig");
    const video_decoder_selection_object = addHostZigObject(
        b,
        "video-decoder-selection",
        "src/media/video/video_decoder_selection.zig",
    );

    const decoder_contract_test = addHostCExecutable(
        b,
        "video-decoder-test",
        &.{"tests/video_decoder_test.c"},
        &.{video_decoder_object},
        false,
    );
    test_step.dependOn(&b.addRunArtifact(decoder_contract_test).step);

    const decoder_selection_test = addHostCExecutable(
        b,
        "video-decoder-selection-test",
        &.{"tests/video_decoder_selection_test.c"},
        &.{ video_decoder_object, video_decoder_selection_object },
        false,
    );
    test_step.dependOn(&b.addRunArtifact(decoder_selection_test).step);

    const frame_copy_test = addHostCExecutable(
        b,
        "video-frame-copy-test",
        &.{"tests/video_frame_copy_test.c"},
        &.{video_frame_copy_object},
        false,
    );
    test_step.dependOn(&b.addRunArtifact(frame_copy_test).step);

    const fake_cedar_valid =
        addHostCFakeLibrary(b, "fake-cedar-valid", "tests/cedar_fake_valid.c");
    const cedar_decoder_test = addHostCExecutable(
        b,
        "video-decoder-cedar-test",
        &.{
            "src/media/video/cedar_loader.c",
            "src/media/video/video_decoder_cedar.c",
            "tests/video_decoder_cedar_test.c",
        },
        &.{video_decoder_object},
        true,
    );
    const run_cedar_decoder_test = b.addRunArtifact(cedar_decoder_test);
    run_cedar_decoder_test.addArtifactArg(fake_cedar_valid);
    test_step.dependOn(&run_cedar_decoder_test.step);

    const fake_mpp_valid = addHostCFakeLibrary(b, "fake-mpp-valid", "tests/mpp_fake_valid.c");
    const fake_mpp_wrong_abi =
        addHostCFakeLibrary(b, "fake-mpp-wrong-abi", "tests/mpp_fake_wrong_abi.c");
    const fake_mpp_missing_symbol =
        addHostCFakeLibrary(b, "fake-mpp-missing-symbol", "tests/mpp_fake_missing_symbol.c");

    const mpp_loader_test = addHostCExecutable(
        b,
        "mpp-loader-test",
        &.{
            "src/media/video/mpp_loader.c",
            "tests/mpp_loader_test.c",
        },
        &.{},
        true,
    );
    const run_mpp_loader_test = b.addRunArtifact(mpp_loader_test);
    run_mpp_loader_test.addArtifactArg(fake_mpp_valid);
    run_mpp_loader_test.addArtifactArg(fake_mpp_wrong_abi);
    run_mpp_loader_test.addArtifactArg(fake_mpp_missing_symbol);
    test_step.dependOn(&run_mpp_loader_test.step);

    const mpp_decoder_test = addHostCExecutable(
        b,
        "video-decoder-mpp-test",
        &.{
            "src/media/video/mpp_loader.c",
            "src/media/video/video_decoder_mpp.c",
            "tests/video_decoder_mpp_test.c",
        },
        &.{video_decoder_object},
        true,
    );
    const run_mpp_decoder_test = b.addRunArtifact(mpp_decoder_test);
    run_mpp_decoder_test.addArtifactArg(fake_mpp_valid);
    test_step.dependOn(&run_mpp_decoder_test.step);
}
