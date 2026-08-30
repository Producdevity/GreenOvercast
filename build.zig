const std = @import("std");

// glibc 2.38 is the oldest userspace supported by the packaged release.
const aarch64_linux_query: std.Target.Query = .{
    .cpu_arch = .aarch64,
    .os_tag = .linux,
    .abi = .gnu,
    .glibc_version = .{ .major = 2, .minor = 38, .patch = 0 },
};

const c_test_flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" };

const project_include_paths = [_][]const u8{
    ".tools/deps/aarch64-linux-gnu/include",
    "vendor/libdatachannel/include",
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

const ZigImport = struct { name: []const u8, path: []const u8 };

const release_zig_roots = [_]struct {
    name: []const u8,
    path: []const u8,
    imports: []const ZigImport = &.{},
}{
    .{
        .name = "greenovercast-auth",
        .path = "src/auth/xbox_auth.zig",
        .imports = &.{
            .{ .name = "form_writer", .path = "src/net/form_writer.zig" },
            .{ .name = "json_reader", .path = "src/net/json_reader.zig" },
        },
    },
    .{
        .name = "greenovercast-cloud",
        .path = "src/session/cloud_session.zig",
        .imports = &.{.{ .name = "json_reader", .path = "src/net/json_reader.zig" }},
    },
    .{
        .name = "greenovercast-webrtc",
        .path = "src/session/webrtc_session.zig",
        .imports = &.{
            .{ .name = "json_reader", .path = "src/net/json_reader.zig" },
            .{ .name = "json_writer", .path = "src/net/json_writer.zig" },
        },
    },
    .{ .name = "greenovercast-controller", .path = "src/input/controller.zig" },
    .{
        .name = "greenovercast-ui",
        .path = "src/ui/handheld_ui.zig",
        .imports = &.{.{ .name = "catalog_search", .path = "src/catalog/catalog_search.zig" }},
    },
    .{ .name = "greenovercast-sdl-platform", .path = "src/platform/sdl_platform.zig" },
    .{
        .name = "greenovercast-audio-pipeline",
        .path = "src/media/audio/audio_pipeline.zig",
        .imports = &.{.{ .name = "rtp_packet", .path = "src/media/rtp/packet.zig" }},
    },
    .{ .name = "greenovercast-mpp-loader", .path = "src/media/video/mpp_loader.zig" },
    .{ .name = "greenovercast-video-decoder-mpp", .path = "src/media/video/video_decoder_mpp.zig" },
    .{ .name = "greenovercast-cedar-loader", .path = "src/media/video/cedar_loader.zig" },
    .{ .name = "greenovercast-video-decoder-cedar", .path = "src/media/video/video_decoder_cedar.zig" },
    .{ .name = "greenovercast-video-pipeline", .path = "src/media/video/video_pipeline.zig" },
    .{ .name = "greenovercast-h264-depacketizer", .path = "src/media/rtp/h264_depacketizer.zig" },
    .{ .name = "greenovercast-video-decoder", .path = "src/media/video/video_decoder.zig" },
    .{ .name = "greenovercast-video-decoder-selection", .path = "src/media/video/video_decoder_selection.zig" },
    .{ .name = "greenovercast-video-frame-copy", .path = "src/media/video/video_frame_copy.zig" },
};

const release_c_sources = [_][]const u8{
    "src/media/video/video_decoder_ffmpeg.c",
    "src/media/video/video_decoder_v4l2_request.c",
    "src/auth/token_store_adapter.c",
    "src/net/http_client.c",
    "src/ui/artwork_decoder.c",
};

const cedar_sources = [_][]const u8{
    "vendor/cedarx/base/AwPool.c",
    "vendor/cedarx/base/CdxList.c",
    "vendor/cedarx/base/CdxQueue.c",
    "vendor/cedarx/base/CdxUtils.c",
    "vendor/cedarx/vdecoder/adapter.c",
    "vendor/cedarx/vdecoder/fbm.c",
    "vendor/cedarx/vdecoder/sbm.c",
    "vendor/cedarx/vdecoder/vdecoder.c",
    "vendor/cedarx/vdecoder/videoengine.c",
    "vendor/cedarx/plugin/vdecoder/h264/h264.c",
    "vendor/cedarx/plugin/vdecoder/h264/h264_dec.c",
    "vendor/cedarx/plugin/vdecoder/h264/h264_hal.c",
    "vendor/cedarx/plugin/vdecoder/h264/h264_mmco.c",
    "vendor/cedarx/plugin/vdecoder/h264/h264_nalu.c",
    "src/media/video/cedar_h616_runtime.c",
    "src/media/video/cedar_bridge.c",
};

fn addProjectIncludes(b: *std.Build, module: *std.Build.Module) void {
    for (project_include_paths) |path| module.addIncludePath(b.path(path));
}

fn addReleaseZigObject(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    source: []const u8,
    imports: []const ZigImport,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addProjectIncludes(b, module);
    for (imports) |item|
        addZigImport(b, module, target, optimize, item.name, item.path);
    return b.addObject(.{ .name = name, .root_module = module });
}

fn addZigImport(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    source: []const u8,
) void {
    module.addImport(name, b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
    }));
}

fn addStaticArchive(module: *std.Build.Module, b: *std.Build, path: []const u8) void {
    module.addObjectFile(b.path(path));
}

fn addReleaseArtifacts(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step {
    const native_dependencies = b.addSystemCommand(&.{
        "sh",
        b.pathFromRoot("tools/build-dependencies.sh"),
    });
    native_dependencies.setCwd(b.path("."));

    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .strip = true,
    });
    addProjectIncludes(b, main_module);
    main_module.addLibraryPath(b.path(".tools/deps/aarch64-linux-gnu/lib"));
    main_module.addRPathSpecial("$ORIGIN");
    main_module.addCSourceFiles(.{
        .files = &release_c_sources,
        .flags = &.{ "-std=gnu11", "-D_GNU_SOURCE", "-Wall", "-Wextra", "-Werror" },
    });

    for (release_zig_roots) |root| {
        const object = addReleaseZigObject(b, target, optimize, root.name, root.path, root.imports);
        object.step.dependOn(&native_dependencies.step);
        main_module.addObject(object);
    }

    const libdatachannel = ".tools/build/libdatachannel-aarch64-release";
    addStaticArchive(main_module, b, libdatachannel ++ "/libdatachannel.a");
    addStaticArchive(main_module, b, libdatachannel ++ "/deps/libjuice/libjuice.a");
    addStaticArchive(main_module, b, libdatachannel ++ "/deps/usrsctp/usrsctplib/libusrsctp.a");
    addStaticArchive(main_module, b, libdatachannel ++ "/deps/libsrtp/libsrtp2.a");
    addStaticArchive(main_module, b, ".tools/deps/aarch64-linux-gnu/lib/libcurl.a");
    addStaticArchive(main_module, b, ".tools/deps/aarch64-linux-gnu/lib/libssl.a");
    addStaticArchive(main_module, b, ".tools/deps/aarch64-linux-gnu/lib/libcrypto.a");
    addStaticArchive(main_module, b, ".tools/deps/aarch64-linux-gnu/lib/libopus.a");
    for ([_][]const u8{ "pthread", "dl", "SDL2", "avcodec", "avutil", "swscale" }) |library| {
        main_module.linkSystemLibrary(library, .{ .use_pkg_config = .no });
    }

    const executable = b.addExecutable(.{
        .name = "webrtc_stream",
        .root_module = main_module,
    });
    executable.step.dependOn(&native_dependencies.step);
    const install_executable = b.addInstallArtifact(executable, .{});

    const cedar_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
        .strip = true,
    });
    for ([_][]const u8{
        "vendor/cedarx/base/include",
        "vendor/cedarx/common/include",
        "vendor/cedarx/vdecoder/include",
        "vendor/cedarx/plugin/vdecoder/h264",
        "src/media/video",
    }) |path| cedar_module.addIncludePath(b.path(path));
    cedar_module.addCSourceFiles(.{
        .files = &cedar_sources,
        .flags = &.{
            "-std=gnu11",
            "-D_GNU_SOURCE",
            "-includestdint.h",
            "-fvisibility=hidden",
            "-Wno-int-to-pointer-cast",
            "-Wno-pointer-to-int-cast",
            "-Wno-format",
            "-Wno-unused-variable",
            "-Wno-unused-parameter",
        },
    });
    cedar_module.linkSystemLibrary("pthread", .{ .use_pkg_config = .no });
    cedar_module.linkSystemLibrary("dl", .{ .use_pkg_config = .no });
    const cedar = b.addSharedLibrary(.{
        .name = "greenovercast-cedar",
        .root_module = cedar_module,
    });
    const install_cedar = b.addInstallArtifact(cedar, .{});

    const cedar_test_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = true,
    });
    cedar_test_module.addIncludePath(b.path("src/media/video"));
    cedar_test_module.addCSourceFile(.{
        .file = b.path("tests/device/cedar_bridge_test.c"),
        .flags = c_test_flags,
    });
    cedar_test_module.linkLibrary(cedar);
    cedar_test_module.addRPathSpecial("$ORIGIN");
    const cedar_test = b.addExecutable(.{
        .name = "cedar_bridge_test",
        .root_module = cedar_test_module,
    });
    const install_cedar_test = b.addInstallArtifact(cedar_test, .{});

    const mpp_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
        .strip = true,
    });
    mpp_module.addIncludePath(b.path("src/media/video"));
    mpp_module.addIncludePath(b.path("vendor/mpp/inc"));
    mpp_module.addLibraryPath(b.path(".tools/build/mpp-aarch64-release/mpp"));
    mpp_module.addRPathSpecial("$ORIGIN");
    mpp_module.addCSourceFile(.{
        .file = b.path("src/media/video/mpp_bridge.c"),
        .flags = c_test_flags,
    });
    mpp_module.linkSystemLibrary("rockchip_mpp", .{
        .use_pkg_config = .no,
        .preferred_link_mode = .dynamic,
        .search_strategy = .paths_first,
    });
    const mpp = b.addSharedLibrary(.{
        .name = "greenovercast-mpp",
        .root_module = mpp_module,
    });
    mpp.step.dependOn(&native_dependencies.step);
    const install_mpp = b.addInstallFile(
        mpp.getEmittedBin(),
        "rockchip/libgreenovercast-mpp.so",
    );

    const mpp_runtime_copy = b.addObjCopy(
        b.path(".tools/build/mpp-aarch64-release/mpp/librockchip_mpp.so.0"),
        .{ .basename = "librockchip_mpp.so.1", .strip = .debug_and_symbols },
    );
    mpp_runtime_copy.step.dependOn(&native_dependencies.step);
    const install_mpp_runtime = b.addInstallFile(
        mpp_runtime_copy.getOutput(),
        "rockchip/librockchip_mpp.so.1",
    );

    const mpp_device_sources = [_]struct { name: []const u8, source: []const u8 }{
        .{ .name = "greenovercast-mpp-probe.aarch64", .source = "tests/device/mpp_probe.c" },
        .{ .name = "greenovercast-mpp-bridge-test.aarch64", .source = "tests/device/mpp_bridge_test.c" },
    };
    const mpp_loader_device_object = addReleaseZigObject(
        b,
        target,
        optimize,
        "greenovercast-mpp-loader-device",
        "src/media/video/mpp_loader.zig",
        &.{},
    );
    var mpp_device_installs: [mpp_device_sources.len]*std.Build.Step.InstallFile = undefined;
    for (mpp_device_sources, 0..) |item, index| {
        const module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = true,
        });
        module.addIncludePath(b.path("src/media/video"));
        module.addRPathSpecial("$ORIGIN");
        module.addCSourceFile(.{ .file = b.path(item.source), .flags = c_test_flags });
        module.addObject(mpp_loader_device_object);
        module.linkSystemLibrary("dl", .{ .use_pkg_config = .no });
        const tool = b.addExecutable(.{ .name = item.name, .root_module = module });
        mpp_device_installs[index] = b.addInstallFile(
            tool.getEmittedBin(),
            b.fmt("rockchip/{s}", .{item.name}),
        );
    }

    const private_libraries = [_]struct { source: []const u8, name: []const u8 }{
        .{ .source = ".tools/deps/aarch64-linux-gnu/lib/libavcodec.so.63", .name = "libavcodec.so.63" },
        .{ .source = ".tools/deps/aarch64-linux-gnu/lib/libavutil.so.61", .name = "libavutil.so.61" },
        .{ .source = ".tools/deps/aarch64-linux-gnu/lib/libswscale.so.10", .name = "libswscale.so.10" },
    };
    var private_library_installs: [private_libraries.len]*std.Build.Step.InstallFile = undefined;
    for (private_libraries, 0..) |library, index| {
        const copy = b.addObjCopy(b.path(library.source), .{
            .basename = library.name,
            .strip = .debug_and_symbols,
        });
        copy.step.dependOn(&native_dependencies.step);
        private_library_installs[index] = b.addInstallBinFile(copy.getOutput(), library.name);
    }

    const release = b.step("release", "Build the aarch64 application and decoder plugins");
    release.dependOn(&install_executable.step);
    release.dependOn(&install_cedar.step);
    release.dependOn(&install_cedar_test.step);
    release.dependOn(&install_mpp.step);
    release.dependOn(&install_mpp_runtime.step);
    for (mpp_device_installs) |install| release.dependOn(&install.step);
    for (private_library_installs) |install| release.dependOn(&install.step);
    return release;
}

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
    const release = addReleaseArtifacts(b, aarch64_linux, .ReleaseSafe);
    b.default_step.dependOn(release);

    const product_check = b.step("product-check", "Build the complete aarch64 product");
    product_check.dependOn(release);

    const package_command = b.addSystemCommand(&.{
        "sh",
        b.pathFromRoot("tools/package-portmaster.sh"),
    });
    package_command.setCwd(b.path("."));
    package_command.step.dependOn(release);
    const package = b.step("package", "Build the PortMaster archive");
    package.dependOn(&package_command.step);

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
        "src/input/guide_chord.zig",
        "src/session/message_protocol.zig",
        "src/ui/keyboard.zig",
        "src/ui/navigation_repeat.zig",
        "src/ui/persistent_settings.zig",
        "src/ui/stream_dimensions.zig",
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
    const cedar_loader_object =
        addHostZigObject(b, "cedar-loader", "src/media/video/cedar_loader.zig");
    const cedar_decoder_object = addHostZigObject(
        b,
        "video-decoder-cedar",
        "src/media/video/video_decoder_cedar.zig",
    );
    const mpp_loader_object =
        addHostZigObject(b, "mpp-loader", "src/media/video/mpp_loader.zig");
    const mpp_decoder_object = addHostZigObject(
        b,
        "video-decoder-mpp",
        "src/media/video/video_decoder_mpp.zig",
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
        &.{"tests/video_decoder_cedar_test.c"},
        &.{ video_decoder_object, cedar_loader_object, cedar_decoder_object },
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
        &.{"tests/mpp_loader_test.c"},
        &.{mpp_loader_object},
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
        &.{"tests/video_decoder_mpp_test.c"},
        &.{ video_decoder_object, mpp_loader_object, mpp_decoder_object },
        true,
    );
    const run_mpp_decoder_test = b.addRunArtifact(mpp_decoder_test);
    run_mpp_decoder_test.addArtifactArg(fake_mpp_valid);
    test_step.dependOn(&run_mpp_decoder_test.step);
}
