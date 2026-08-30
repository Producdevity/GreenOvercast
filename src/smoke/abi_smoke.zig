const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const stat_compat = @import("stat_compat");

extern fn go_smoke_cpp_probe() c_int;
extern fn gnu_get_libc_version() [*:0]const u8;

const stdout = std.io.getStdOut().writer();

// Zig's default panic path calls statx, which is unavailable on kernel 4.9.
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    stdout.print("SMOKE panic: {s}\n", .{msg}) catch {};
    posix.abort();
}

var g_pass: u32 = 0;
var g_fail: u32 = 0;

fn report(comptime name: []const u8, ok: bool, detail: anytype) void {
    if (ok) {
        g_pass += 1;
        stdout.print("SMOKE " ++ name ++ " ok {s}\n", .{detail}) catch {};
    } else {
        g_fail += 1;
        stdout.print("SMOKE " ++ name ++ " FAIL {s}\n", .{detail}) catch {};
    }
}

fn reportErr(comptime name: []const u8, err: anyerror) void {
    var buf: [64]u8 = undefined;
    const detail = std.fmt.bufPrint(&buf, "error={s}", .{@errorName(err)}) catch "error=?";
    report(name, false, detail);
}

var g_signal_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
threadlocal var g_tls_seen: u32 = 0;

fn onUsr1(_: c_int) callconv(.C) void {
    _ = g_signal_count.fetchAdd(1, .seq_cst);
}

const ThreadShared = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    counter: u32 = 0,
    done: bool = false,
};

fn threadWorker(shared: *ThreadShared) void {
    g_tls_seen = 77;
    shared.mutex.lock();
    defer shared.mutex.unlock();
    var i: u32 = 0;
    while (i < 1000) : (i += 1) shared.counter += 1;
    shared.done = true;
    shared.cond.signal();
}

fn caseThreads() !void {
    var shared = ThreadShared{};
    const t1 = try std.Thread.spawn(.{}, threadWorker, .{&shared});
    const t2 = try std.Thread.spawn(.{}, threadWorker, .{&shared});
    shared.mutex.lock();
    while (!shared.done) shared.cond.wait(&shared.mutex);
    const tls_main = g_tls_seen;
    shared.mutex.unlock();
    t1.join();
    t2.join();
    if (shared.counter != 2000 or tls_main != 0) return error.ThreadMismatch;
}

fn caseFileIo() !void {
    var dir = try std.fs.openDirAbsolute("/tmp", .{});
    defer dir.close();
    const tmp = "greenovercast-smoke.tmp";
    const final = "greenovercast-smoke.out";
    {
        const f = try dir.createFile(tmp, .{});
        defer f.close();
        try f.writeAll("greenovercast smoke\n");
        try f.sync();
    }
    try dir.rename(tmp, final);
    defer dir.deleteFile(final) catch {};
    const f = try dir.openFile(final, .{});
    defer f.close();
    var buf: [64]u8 = undefined;
    const n = try f.readAll(&buf);
    if (!std.mem.eql(u8, buf[0..n], "greenovercast smoke\n")) return error.ContentMismatch;
}

fn caseStatShim() !void {
    var dir = try std.fs.openDirAbsolute("/tmp", .{});
    defer dir.close();
    const f = try dir.createFile("greenovercast-smoke-stat.tmp", .{});
    defer {
        f.close();
        dir.deleteFile("greenovercast-smoke-stat.tmp") catch {};
    }
    try f.writeAll("12345");
    const st = try stat_compat.fstat(f.handle);
    if (st.size != 5) return error.StatSizeMismatch;
}

fn caseSignals() !void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = onUsr1 },
        .mask = posix.empty_sigset,
        .flags = 0,
    };
    posix.sigaction(posix.SIG.USR1, &act, null);
    try posix.raise(posix.SIG.USR1);
    if (g_signal_count.load(.seq_cst) != 1) return error.SignalNotDelivered;
}

fn caseEventLoop() !void {
    const epfd = try posix.epoll_create1(linux.EPOLL.CLOEXEC);
    defer posix.close(epfd);

    const evfd = try posix.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    defer posix.close(evfd);

    const tfd = try posix.timerfd_create(linux.TIMERFD_CLOCK.MONOTONIC, .{ .CLOEXEC = true });
    defer posix.close(tfd);

    var ev: linux.epoll_event = .{ .events = linux.EPOLL.IN, .data = .{ .fd = evfd } };
    try posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, evfd, &ev);
    ev.data.fd = tfd;
    try posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, tfd, &ev);

    _ = try posix.write(evfd, std.mem.asBytes(&@as(u64, 1)));
    try posix.timerfd_settime(tfd, .{}, &.{
        .it_interval = .{ .sec = 0, .nsec = 0 },
        .it_value = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms },
    }, null);

    var ready: [2]linux.epoll_event = undefined;
    var got_eventfd = false;
    var got_timerfd = false;
    var rounds: u32 = 0;
    while (rounds < 4 and !(got_eventfd and got_timerfd)) : (rounds += 1) {
        const n = posix.epoll_wait(epfd, &ready, 2000);
        for (ready[0..n]) |e| {
            var sink: u64 = undefined;
            if (e.data.fd == evfd) {
                got_eventfd = true;
                _ = try posix.read(evfd, std.mem.asBytes(&sink)); // drain so waits can block
            }
            if (e.data.fd == tfd) {
                got_timerfd = true;
                _ = try posix.read(tfd, std.mem.asBytes(&sink));
            }
        }
    }
    if (!got_eventfd or !got_timerfd) return error.EpollTimeout;
}

fn caseSignalfd() !void {
    var set = posix.empty_sigset;
    linux.sigaddset(&set, linux.SIG.USR2);
    posix.sigprocmask(linux.SIG.BLOCK, &set, null);
    const sfd = try posix.signalfd(-1, &set, linux.SFD.CLOEXEC);
    defer posix.close(sfd);
    try posix.raise(posix.SIG.USR2);
    var info: linux.signalfd_siginfo = undefined;
    const n = try posix.read(sfd, std.mem.asBytes(&info));
    if (n != @sizeOf(linux.signalfd_siginfo) or info.signo != linux.SIG.USR2)
        return error.SignalfdMismatch;
}

fn caseClock() !void {
    const before = try posix.clock_gettime(.MONOTONIC);
    std.time.sleep(5 * std.time.ns_per_ms);
    const after = try posix.clock_gettime(.MONOTONIC);
    _ = try posix.clock_gettime(.MONOTONIC_RAW);
    const elapsed_ns = (after.sec - before.sec) * std.time.ns_per_s + (after.nsec - before.nsec);
    if (elapsed_ns < 0) return error.ClockWentBackwards;
}

fn caseDns() !void {
    const list = try std.net.getAddressList(std.heap.page_allocator, "localhost", 80);
    defer list.deinit();
    if (list.addrs.len == 0) return error.NoAddresses;
}

fn caseSockets() !void {
    {
        const fd = try posix.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
        defer posix.close(fd);
        const addr = try std.net.Address.parseIp4("203.0.113.1", 9); // TEST-NET-3; UDP connect sends nothing
        try posix.connect(fd, &addr.any, addr.getOsSockLen());
        var local: linux.sockaddr = undefined;
        var len: linux.socklen_t = @sizeOf(linux.sockaddr);
        try posix.getsockname(fd, &local, &len);
    }
    {
        const fd = try posix.socket(linux.AF.INET6, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
        defer posix.close(fd);
        const addr = try std.net.Address.parseIp6("::1", 9); // loopback: no route dependency
        try posix.connect(fd, &addr.any, addr.getOsSockLen());
    }
}

fn caseEntropy() !void {
    var buf: [32]u8 = undefined;
    std.crypto.random.bytes(&buf);
    const zero: [32]u8 = @splat(0);
    if (std.mem.eql(u8, &buf, &zero)) return error.EntropyZero;
}

fn caseAllocator() !void {
    const alloc = std.heap.page_allocator;
    var blocks: [64][]u8 = undefined;
    for (&blocks, 0..) |*b, i| {
        b.* = try alloc.alloc(u8, 4096 + i * 257);
        b.*[0] = @truncate(i);
    }
    for (&blocks) |*b| {
        b.*[b.len - 1] = 1;
        alloc.free(b.*);
    }
}

fn caseCpp() !void {
    if (go_smoke_cpp_probe() != 0) return error.CppProbeFailed;
}

fn syscallPresence() void {
    const statx_rc = linux.syscall5(.statx, @as(usize, @bitCast(@as(isize, linux.AT.FDCWD))), @intFromPtr("/proc/self"), 0, 0, 0);
    printPresence("statx", statx_rc);

    const faccessat2_rc = linux.syscall4(.faccessat2, @as(usize, @bitCast(@as(isize, linux.AT.FDCWD))), @intFromPtr("/proc/self"), 0, 0);
    printPresence("faccessat2", faccessat2_rc);

    const cfr_rc = linux.syscall6(.copy_file_range, std.math.maxInt(u32), 0, std.math.maxInt(u32), 0, 1, 0);
    printPresence("copy_file_range", cfr_rc);

    var rnd: u8 = 0;
    const getrandom_rc = linux.syscall3(.getrandom, @intFromPtr(&rnd), 1, 0);
    printPresence("getrandom", getrandom_rc);

    const name = "greenovercast-smoke";
    const memfd_rc = linux.syscall2(.memfd_create, @intFromPtr(name.ptr), 0);
    if (linux.E.init(memfd_rc) == .SUCCESS) {
        posix.close(@intCast(memfd_rc));
    }
    printPresence("memfd_create", memfd_rc);

    stdout.print("SMOKE syscall-table note: ENOSYS entries are informational; platform code must feature-check\n", .{}) catch {};
}

fn printPresence(comptime name: []const u8, rc: usize) void {
    // Raw linux.syscallN returns -errno on failure; posix.errno() would read
    // the libc TLS errno instead and misreport. Interpret the raw value.
    const present = linux.E.init(rc) != .NOSYS;
    stdout.print("SMOKE syscall " ++ name ++ " {s}\n", .{if (present) "present" else "absent(ENOSYS)"}) catch {};
}

fn run(comptime name: []const u8, case: fn () anyerror!void) void {
    case() catch |err| {
        reportErr(name, err);
        return;
    };
    report(name, true, "");
}

pub fn main() !u8 {
    var uts: linux.utsname = posix.uname();
    stdout.print("SMOKE uname {s} {s} {s}\n", .{
        std.mem.sliceTo(&uts.sysname, 0),
        std.mem.sliceTo(&uts.release, 0),
        std.mem.sliceTo(&uts.machine, 0),
    }) catch {};
    stdout.print("SMOKE libc glibc {s}\n", .{gnu_get_libc_version()}) catch {};

    run("file-io", caseFileIo);
    run("stat-shim", caseStatShim);
    run("threads", caseThreads);
    run("signals", caseSignals);
    run("epoll-eventfd-timerfd", caseEventLoop);
    run("signalfd", caseSignalfd);
    run("clock", caseClock);
    run("dns", caseDns);
    run("sockets", caseSockets);
    run("entropy", caseEntropy);
    run("allocator", caseAllocator);
    run("cpp-static-libcxx", caseCpp);
    syscallPresence();

    stdout.print("SMOKE_SUMMARY pass={d} fail={d}\n", .{ g_pass, g_fail }) catch {};
    return if (g_fail == 0) 0 else 1;
}
