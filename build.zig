const std = @import("std");

// H700 target profile: both devices run vendor kernel 4.9.170 with glibc
// 2.38 (muOS) / 2.40 (Knulli). Targeting the 2.38 ceiling covers both.
const h700_query: std.Target.Query = .{
    .cpu_arch = .aarch64,
    .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.cortex_a53 },
    .os_tag = .linux,
    .abi = .gnu,
    .glibc_version = .{ .major = 2, .minor = 38, .patch = 0 },
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const h700 = b.resolveTargetQuery(h700_query);

    const stat_compat = b.createModule(.{
        .root_source_file = b.path("src/platform/linux/stat_compat.zig"),
        .target = h700,
        .optimize = optimize,
    });

    const smoke = b.addExecutable(.{
        .name = "greenovercast-smoke",
        .root_source_file = b.path("src/smoke/abi_smoke.zig"),
        .target = h700,
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
            .target = h700,
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
}
