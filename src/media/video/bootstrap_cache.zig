const std = @import("std");
const builtin = @import("builtin");

pub const capacity = 4104;

pub fn read(directory: std.fs.Dir, path: []const u8, buffer: *[capacity + 1]u8) ![]const u8 {
    const file = try directory.openFile(path, .{});
    defer file.close();
    // Zig's File.stat() uses statx, which Linux 4.9 does not provide.
    const length = try file.readAll(buffer);
    if (length > capacity) return error.FileTooBig;
    return buffer[0..length];
}

const parameter_sets = [_]u8{ 0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0xce };

test "cache reads preserve parameter sets" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(.{ .sub_path = "cache.bin", .data = &parameter_sets });
    var buffer: [capacity + 1]u8 = undefined;
    const data = try read(directory.dir, "cache.bin", &buffer);
    try std.testing.expectEqualSlices(u8, &parameter_sets, data);

    const h264 = @import("h264_depacketizer");
    var depacketizer = h264.Depacketizer.init(102);
    try std.testing.expect(depacketizer.setBootstrap(data));
    @memset(&buffer, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0x67, 0x42 }, depacketizer.sps[0..depacketizer.sps_length]);
    try std.testing.expectEqualSlices(u8, &.{ 0x68, 0xce }, depacketizer.pps[0..depacketizer.pps_length]);
}

test "empty cache returns no parameter sets" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(.{ .sub_path = "cache.bin", .data = "" });
    var buffer: [capacity + 1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), (try read(directory.dir, "cache.bin", &buffer)).len);
}

test "malformed cache does not replace active parameter sets" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(.{ .sub_path = "cache.bin", .data = "invalid H.264" });
    var buffer: [capacity + 1]u8 = undefined;
    const data = try read(directory.dir, "cache.bin", &buffer);
    const h264 = @import("h264_depacketizer");
    var depacketizer = h264.Depacketizer.init(102);
    try std.testing.expect(depacketizer.setBootstrap(&parameter_sets));
    try std.testing.expect(!depacketizer.setBootstrap(data));
    try std.testing.expectEqualSlices(u8, &.{ 0x67, 0x42 }, depacketizer.sps[0..depacketizer.sps_length]);
    try std.testing.expectEqualSlices(u8, &.{ 0x68, 0xce }, depacketizer.pps[0..depacketizer.pps_length]);
}

test "cache accepts the exact capacity and rejects one extra byte" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var data = [_]u8{0x55} ** (capacity + 1);
    @memcpy(data[0..5], &[_]u8{ 0, 0, 0, 1, 0x67 });
    @memcpy(data[2052..2057], &[_]u8{ 0, 0, 0, 1, 0x68 });
    try directory.dir.writeFile(.{ .sub_path = "cache.bin", .data = data[0..capacity] });
    var buffer: [capacity + 1]u8 = undefined;
    const loaded = try read(directory.dir, "cache.bin", &buffer);
    try std.testing.expectEqualSlices(u8, data[0..capacity], loaded);
    const h264 = @import("h264_depacketizer");
    var depacketizer = h264.Depacketizer.init(102);
    try std.testing.expect(depacketizer.setBootstrap(loaded));

    try directory.dir.writeFile(.{ .sub_path = "cache.bin", .data = &data });
    try std.testing.expectError(error.FileTooBig, read(directory.dir, "cache.bin", &buffer));
}

test "large cache is rejected rather than parsed as a prefix" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var data = [_]u8{0x55} ** 16384;
    @memcpy(data[0..parameter_sets.len], &parameter_sets);
    try directory.dir.writeFile(.{ .sub_path = "cache.bin", .data = &data });
    var buffer: [capacity + 1]u8 = undefined;
    try std.testing.expectError(error.FileTooBig, read(directory.dir, "cache.bin", &buffer));
}

test "missing cache reports FileNotFound" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var buffer: [capacity + 1]u8 = undefined;
    try std.testing.expectError(error.FileNotFound, read(directory.dir, "missing.bin", &buffer));
}

test "cache read errors are returned" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.makeDir("not-a-file");
    var buffer: [capacity + 1]u8 = undefined;
    try std.testing.expectError(error.IsDir, read(directory.dir, "not-a-file", &buffer));
}

test "cache loads when the kernel has no statx syscall" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(.{ .sub_path = "cache.bin", .data = &parameter_sets });

    const pid = try std.posix.fork();
    if (pid == 0) {
        const linux = std.os.linux;
        const bpf = linux.BPF;
        const Filter = extern struct { code: u16, jt: u8 = 0, jf: u8 = 0, k: u32 };
        const Program = extern struct { len: u16, filter: [*]const Filter };
        const filters = [_]Filter{
            .{ .code = bpf.LD | bpf.W | bpf.ABS, .k = @offsetOf(linux.SECCOMP.data, "nr") },
            .{ .code = bpf.JMP | bpf.JEQ | bpf.K, .jf = 1, .k = @intFromEnum(linux.SYS.statx) },
            .{ .code = bpf.RET | bpf.K, .k = linux.SECCOMP.RET.ERRNO | @as(u32, @intFromEnum(linux.E.NOSYS)) },
            .{ .code = bpf.RET | bpf.K, .k = linux.SECCOMP.RET.ALLOW },
        };
        const program = Program{ .len = filters.len, .filter = &filters };
        // Keep the filter isolated from the test runner.
        if (linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0) != 0 or
            linux.seccomp(linux.SECCOMP.SET_MODE_FILTER, 0, &program) != 0) linux.exit(1);
        var stat: linux.Statx = undefined;
        if (linux.E.init(linux.statx(-1, "", 0, 0, &stat)) != .NOSYS) linux.exit(2);
        var buffer: [capacity + 1]u8 = undefined;
        const data = read(directory.dir, "cache.bin", &buffer) catch linux.exit(3);
        linux.exit(if (std.mem.eql(u8, &parameter_sets, data)) 0 else 4);
    }
    const result = std.posix.waitpid(pid, 0);
    try std.testing.expect(std.posix.W.IFEXITED(result.status));
    try std.testing.expectEqual(@as(u8, 0), std.posix.W.EXITSTATUS(result.status));
}
