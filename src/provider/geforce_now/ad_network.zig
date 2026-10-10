const std = @import("std");
const vast = @import("vast.zig");
const protocol = @import("ad_protocol.zig");
const c = @cImport({
    @cInclude("curl/curl.h");
    @cInclude("http_client.h");
});

pub const Reporter = struct {
    context: *anyopaque,
    send: *const fn (*anyopaque, protocol.Update) anyerror!void,
};
pub const Source = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque, std.mem.Allocator, []const u8, usize, *std.atomic.Value(bool)) anyerror![]u8,
};
pub const Fetch = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    result: ?[]u8 = null,
    failure: ?anyerror = null,
};
const Job = union(enum) {
    report: protocol.Update,
    beacon: []u8,
    fetch: struct { address: []const u8, limit: usize, output: *Fetch },
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    reporter: Reporter,
    source: ?Source = null,
    abort: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    threads: [2]?std.Thread = .{ null, null },
    mutex: std.Thread.Mutex = .{},
    wake: std.Thread.Condition = .{},
    jobs: [256]Job = undefined,
    count: usize = 0,
    working: [2]bool = .{ false, false },
    closing: bool = false,
    failure: ?anyerror = null,
    beacon_failures: usize = 0,

    pub fn start(self: *Worker) !void {
        if (self.threads[0] != null or self.closing) return error.AdWorkerStopped;
        errdefer self.deinit();
        for (&self.threads, 0..) |*thread, index| thread.* = try std.Thread.spawn(.{}, run, .{ self, index });
    }

    fn enqueue(self: *Worker, job: Job) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closing or self.threads[1] == null) return error.AdWorkerStopped;
        if (self.count == self.jobs.len) return error.AdReportQueueFull;
        self.jobs[self.count] = job;
        self.count += 1;
        self.wake.broadcast();
    }

    pub fn report(self: *Worker, update: protocol.Update) !void {
        try self.enqueue(.{ .report = update });
    }
    pub fn beacon(self: *Worker, address: []const u8) !void {
        const owned = try self.allocator.dupe(u8, address);
        errdefer self.allocator.free(owned);
        try self.enqueue(.{ .beacon = owned });
    }
    pub fn fetch(self: *Worker, address: []const u8, limit: usize, output: *Fetch) !void {
        try self.enqueue(.{ .fetch = .{ .address = address, .limit = limit, .output = output } });
    }
    pub fn idle(self: *Worker) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.failure) |failure| return failure;
        return self.count == 0 and !self.working[0] and !self.working[1];
    }

    pub fn reportsIdle(self: *Worker) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.failure) |failure| return failure;
        if (self.working[0]) return false;
        for (self.jobs[0..self.count]) |job| if (job == .report) return false;
        return true;
    }

    fn nextJob(self: *Worker, index: usize) ?Job {
        var found: ?usize = null;
        for (self.jobs[0..self.count], 0..) |job, position| {
            if (index == 0 and job == .report) {
                found = position;
                break;
            }
            if (index == 1 and job != .report) {
                if (found == null) found = position;
                if (job == .fetch) {
                    found = position;
                    break;
                }
            }
        }
        const position = found orelse return null;
        const job = self.jobs[position];
        std.mem.copyForwards(Job, self.jobs[position .. self.count - 1], self.jobs[position + 1 .. self.count]);
        self.count -= 1;
        return job;
    }

    fn run(self: *Worker, index: usize) void {
        while (true) {
            self.mutex.lock();
            const job = while (true) {
                if (self.nextJob(index)) |job| break job;
                if (self.closing) {
                    self.mutex.unlock();
                    return;
                }
                self.wake.wait(&self.mutex);
            };
            self.working[index] = true;
            self.mutex.unlock();
            switch (job) {
                .report => |update| if (!self.abort.load(.acquire)) self.reporter.send(self.reporter.context, update) catch |err| {
                    self.mutex.lock();
                    if (self.failure == null) self.failure = err;
                    self.mutex.unlock();
                    self.abort.store(true, .release);
                },
                .beacon => |address| {
                    defer self.allocator.free(address);
                    const bytes = self.download(address, 64 * 1024, 3) catch |err| {
                        if (err != error.Cancelled) self.beacon_failures += 1;
                        self.finishJob(index);
                        continue;
                    };
                    self.allocator.free(bytes);
                },
                .fetch => |request| {
                    request.output.result = self.download(request.address, request.limit, 30) catch |err| result: {
                        request.output.failure = err;
                        break :result null;
                    };
                    request.output.done.store(true, .release);
                },
            }
            self.finishJob(index);
        }
    }
    fn download(self: *Worker, address: []const u8, limit: usize, timeout_seconds: c_long) ![]u8 {
        try vast.validateUrl(address);
        if (self.abort.load(.acquire)) return error.Cancelled;
        if (self.source) |source| {
            const bytes = try source.read(source.context, self.allocator, address, limit, &self.abort);
            if (bytes.len > limit) {
                self.allocator.free(bytes);
                return error.AdResponseTooLarge;
            }
            return bytes;
        }
        return get(self.allocator, address, limit, &self.abort, timeout_seconds);
    }
    fn finishJob(self: *Worker, index: usize) void {
        self.mutex.lock();
        self.working[index] = false;
        self.mutex.unlock();
    }
    pub fn deinit(self: *Worker) void {
        self.abort.store(true, .release);
        self.mutex.lock();
        self.closing = true;
        self.wake.broadcast();
        self.mutex.unlock();
        for (&self.threads) |*thread| {
            if (thread.*) |running| running.join();
            thread.* = null;
        }
        if (self.beacon_failures > 0) std.debug.print("GeForce NOW ad tracking failures: {d}\n", .{self.beacon_failures});
        self.beacon_failures = 0;
    }
};

const Transfer = struct {
    bytes: std.ArrayList(u8),
    location: ?[]u8 = null,
    limit: usize,
    abort: *std.atomic.Value(bool),
    failure: ?anyerror = null,
};
fn body(data: [*]const u8, size: usize, count: usize, context: ?*anyopaque) callconv(.c) usize {
    const transfer: *Transfer = @ptrCast(@alignCast(context.?));
    const length = std.math.mul(usize, size, count) catch return 0;
    if (length > transfer.limit - transfer.bytes.items.len) {
        transfer.failure = error.AdResponseTooLarge;
        return 0;
    }
    transfer.bytes.appendSlice(data[0..length]) catch |err| {
        transfer.failure = err;
        return 0;
    };
    return length;
}
fn header(data: [*]const u8, size: usize, count: usize, context: ?*anyopaque) callconv(.c) usize {
    const transfer: *Transfer = @ptrCast(@alignCast(context.?));
    const length = std.math.mul(usize, size, count) catch return 0;
    const line = data[0..length];
    if (std.ascii.startsWithIgnoreCase(line, "Location:")) {
        const address = std.mem.trim(u8, line[9..], " \t\r\n");
        if (address.len > 8192) return 0;
        if (transfer.location) |previous| transfer.bytes.allocator.free(previous);
        transfer.location = transfer.bytes.allocator.dupe(u8, address) catch return 0;
    }
    return length;
}
fn cancelled(context: ?*anyopaque, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t) callconv(.c) c_int {
    const transfer: *Transfer = @ptrCast(@alignCast(context.?));
    return @intFromBool(transfer.abort.load(.acquire));
}
fn connected(_: ?*anyopaque, remote: [*c]const u8, _: [*c]const u8, _: c_int, _: c_int) callconv(.c) c_int {
    return if (publicIp(std.mem.span(remote))) c.CURL_PREREQFUNC_OK else c.CURL_PREREQFUNC_ABORT;
}

fn publicIp(address: []const u8) bool {
    const parsed = std.net.Address.parseIp(address, 443) catch return false;
    if (parsed.any.family == std.posix.AF.INET) {
        const bytes = std.mem.asBytes(&parsed.in.sa.addr);
        return bytes[0] != 0 and bytes[0] != 10 and bytes[0] != 127 and bytes[0] < 224 and
            !(bytes[0] == 169 and bytes[1] == 254) and !(bytes[0] == 172 and bytes[1] >= 16 and bytes[1] <= 31) and
            !(bytes[0] == 192 and bytes[1] == 168) and !(bytes[0] == 100 and bytes[1] >= 64 and bytes[1] <= 127) and
            !(bytes[0] == 198 and (bytes[1] == 18 or bytes[1] == 19));
    }
    // Only global unicast IPv6; excludes loopback, link-local and mapped IPv4.
    return parsed.in6.sa.addr[0] & 0xe0 == 0x20;
}

fn get(allocator: std.mem.Allocator, address: []const u8, limit: usize, abort: *std.atomic.Value(bool), timeout_seconds: c_long) ![]u8 {
    var current = try allocator.dupeZ(u8, address);
    defer allocator.free(current);
    for (0..6) |_| {
        if (abort.load(.acquire)) return error.Cancelled;
        try vast.validateUrl(current);
        var transfer = Transfer{ .bytes = std.ArrayList(u8).init(allocator), .limit = limit, .abort = abort };
        defer transfer.bytes.deinit();
        defer if (transfer.location) |location| allocator.free(location);
        const handle = c.curl_easy_init() orelse return error.HttpUnavailable;
        defer c.curl_easy_cleanup(handle);
        if (c.curl_easy_setopt(handle, c.CURLOPT_URL, current.ptr) != c.CURLE_OK or
            c.curl_easy_setopt(handle, c.CURLOPT_PROTOCOLS_STR, @as([*:0]const u8, "https")) != c.CURLE_OK or
            c.curl_easy_setopt(handle, c.CURLOPT_USERAGENT, @as([*:0]const u8, "GreenOvercast")) != c.CURLE_OK or
            c.curl_easy_setopt(handle, c.CURLOPT_TIMEOUT, timeout_seconds) != c.CURLE_OK or
            c.curl_easy_setopt(handle, c.CURLOPT_CONNECTTIMEOUT, @min(@as(c_long, 10), timeout_seconds)) != c.CURLE_OK or
            c.curl_easy_setopt(handle, c.CURLOPT_NOSIGNAL, @as(c_long, 1)) != c.CURLE_OK or
            c.curl_easy_setopt(handle, c.CURLOPT_WRITEFUNCTION, body) != c.CURLE_OK or
            c.curl_easy_setopt(handle, c.CURLOPT_WRITEDATA, &transfer) != c.CURLE_OK or
            c.curl_easy_setopt(handle, c.CURLOPT_HEADERFUNCTION, header) != c.CURLE_OK or
            c.curl_easy_setopt(handle, c.CURLOPT_HEADERDATA, &transfer) != c.CURLE_OK or
            c.curl_easy_setopt(handle, c.CURLOPT_NOPROGRESS, @as(c_long, 0)) != c.CURLE_OK or
            c.curl_easy_setopt(handle, c.CURLOPT_XFERINFOFUNCTION, cancelled) != c.CURLE_OK or
            c.curl_easy_setopt(handle, c.CURLOPT_XFERINFODATA, &transfer) != c.CURLE_OK or
            c.curl_easy_setopt(handle, c.CURLOPT_PREREQFUNCTION, connected) != c.CURLE_OK)
            return error.HttpConfigurationFailed;
        const ca = c.go_http_ca_bundle();
        if (ca != null and c.curl_easy_setopt(handle, c.CURLOPT_CAINFO, ca) != c.CURLE_OK)
            return error.HttpConfigurationFailed;
        const result = c.curl_easy_perform(handle);
        if (abort.load(.acquire)) return error.Cancelled;
        if (transfer.failure) |failure| return failure;
        if (result != c.CURLE_OK) return error.AdDownloadFailed;
        var status: c_long = 0;
        if (c.curl_easy_getinfo(handle, c.CURLINFO_RESPONSE_CODE, &status) != c.CURLE_OK) return error.HttpStatusUnavailable;
        if (status >= 200 and status < 300) return transfer.bytes.toOwnedSlice();
        if (status < 300 or status >= 400) return error.AdDownloadRejected;
        const location = transfer.location orelse return error.MissingRedirect;
        // Redirects never carry account headers, cookies or shared curl state.
        const next = try redirect(allocator, current, location);
        allocator.free(current);
        current = next;
    }
    return error.AdRedirectLimit;
}

fn redirect(allocator: std.mem.Allocator, base: []const u8, location: []const u8) ![:0]u8 {
    if (location.len == 0 or location.len > 8192) return error.InvalidAdUrl;
    const buffer = try allocator.alloc(u8, 32768);
    defer allocator.free(buffer);
    var available = buffer;
    const resolved = try std.Uri.resolve_inplace(try std.Uri.parse(base), location, &available);
    const address = try std.fmt.allocPrintZ(allocator, "{}", .{resolved});
    errdefer allocator.free(address);
    try vast.validateUrl(address);
    return address;
}

test "relative redirects are resolved without allowing credentials or HTTP" {
    const address = try redirect(std.testing.allocator, "https://example.invalid/path/tag", "../media?key=one");
    defer std.testing.allocator.free(address);
    try std.testing.expectEqualStrings("https://example.invalid/media?key=one", address);
    try std.testing.expectError(error.InvalidAdUrl, redirect(std.testing.allocator, "https://example.invalid/", "http://example.invalid/media"));
    try std.testing.expectError(error.InvalidAdUrl, redirect(std.testing.allocator, "https://example.invalid/", "https://user:pass@example.invalid/media"));
}

test "ad connections reject local networks including IPv4 mapped IPv6" {
    for ([_][]const u8{ "127.0.0.1", "10.0.0.1", "169.254.1.1", "172.16.0.1", "192.168.1.1", "::1", "::ffff:127.0.0.1", "fe80::1", "fc00::1" }) |value|
        try std.testing.expect(!publicIp(value));
    try std.testing.expect(publicIp("8.8.8.8"));
    try std.testing.expect(publicIp("2001:4860:4860::8888"));
}

test "report queue is bounded and stop joins an in-flight fetch" {
    const Fake = struct {
        entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        stop: *std.atomic.Value(bool),
        received: usize = 0,

        fn send(context: *anyopaque, _: protocol.Update) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.entered.store(true, .release);
            while (!self.release.load(.acquire) and !self.stop.load(.acquire)) std.Thread.sleep(std.time.ns_per_ms);
            self.received += 1;
        }
        fn read(context: *anyopaque, _: std.mem.Allocator, _: []const u8, _: usize, stop: *std.atomic.Value(bool)) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.entered.store(true, .release);
            while (!stop.load(.acquire)) std.Thread.sleep(std.time.ns_per_ms);
            return error.Cancelled;
        }
        fn wait(self: *@This()) !void {
            for (0..2000) |_| {
                if (self.entered.load(.acquire)) return;
                std.Thread.sleep(std.time.ns_per_ms);
            }
            return error.TestTimedOut;
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    var fake = Fake{ .stop = &stop };
    var worker = Worker{ .allocator = std.testing.allocator, .reporter = .{ .context = &fake, .send = Fake.send } };
    fake.stop = &worker.abort;
    try worker.start();
    defer worker.deinit();
    try worker.report(.{ .action = .start });
    try fake.wait();
    for (0..256) |_| try worker.report(.{ .action = .event, .event = "test" });
    try std.testing.expectError(error.AdReportQueueFull, worker.report(.{ .action = .finish }));
    fake.release.store(true, .release);
    for (0..2000) |_| {
        if (try worker.idle()) break;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(try worker.idle());
    worker.deinit();
    try std.testing.expectEqual(@as(usize, 257), fake.received);
    try std.testing.expectError(error.AdWorkerStopped, worker.report(.{ .action = .finish }));

    fake.entered.store(false, .release);
    var fetch_worker = Worker{ .allocator = std.testing.allocator, .reporter = .{ .context = &fake, .send = Fake.send }, .source = .{ .context = &fake, .read = Fake.read } };
    try fetch_worker.start();
    defer fetch_worker.deinit();
    var result = Fetch{};
    try fetch_worker.fetch("https://example.invalid", 1024, &result);
    try fake.wait();
    fetch_worker.deinit();
    try std.testing.expect(result.done.load(.acquire));
    try std.testing.expect(result.failure.? == error.Cancelled and result.result == null);
}

test "slow advertiser tracking cannot block session reports" {
    const Fake = struct {
        entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        reported: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        fn read(context: *anyopaque, _: std.mem.Allocator, _: []const u8, _: usize, stop: *std.atomic.Value(bool)) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.entered.store(true, .release);
            while (!stop.load(.acquire)) std.Thread.sleep(std.time.ns_per_ms);
            return error.Cancelled;
        }
        fn send(context: *anyopaque, _: protocol.Update) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.reported.store(true, .release);
        }
    };
    var fake = Fake{};
    var worker = Worker{ .allocator = std.testing.allocator, .reporter = .{ .context = &fake, .send = Fake.send }, .source = .{ .context = &fake, .read = Fake.read } };
    try worker.start();
    defer worker.deinit();
    try worker.beacon("https://example.invalid/slow-tracker");
    for (0..2000) |_| {
        if (fake.entered.load(.acquire)) break;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(fake.entered.load(.acquire));
    try worker.report(.{ .action = .finish });
    for (0..2000) |_| {
        if (fake.reported.load(.acquire)) break;
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(fake.reported.load(.acquire));
    try std.testing.expect(!try worker.idle());
    worker.deinit();
    try std.testing.expect(try worker.reportsIdle());
}
