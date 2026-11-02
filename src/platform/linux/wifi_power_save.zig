const std = @import("std");
const builtin = @import("builtin");
const c = if (builtin.os.tag == .linux) @cImport({
    @cInclude("linux/genetlink.h");
    @cInclude("linux/nl80211.h");
    @cInclude("sys/socket.h");
    @cInclude("net/if.h");
    @cInclude("poll.h");
}) else struct {};

const endian = builtin.cpu.arch.endian();
const max_interfaces = 8;
const Interface = struct {
    name: [16:0]u8 = [_:0]u8{0} ** 16,
    index: u32,
    wireless_id: u64 = 0,

    fn slice(self: *const Interface) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
};

pub const Guard = struct {
    connection: ?Netlink = null,
    changed: [max_interfaces]Interface = undefined,
    count: usize = 0,

    pub fn begin(self: *Guard) void {
        if (builtin.os.tag != .linux or self.connection != null) return;
        if (self.count != 0) {
            self.connection = Netlink.open() catch return;
            self.restore(&self.connection.?);
            if (self.count != 0) return;
        }
        var interfaces = std.fs.openDirAbsolute("/sys/class/net", .{ .iterate = true }) catch return;
        defer interfaces.close();
        var iterator = interfaces.iterate();
        while (iterator.next() catch null) |entry| {
            if (self.count == max_interfaces) break;
            if (entry.name.len >= 16) continue;
            var path_buffer: [128]u8 = undefined;
            const phy_path = std.fmt.bufPrint(&path_buffer, "{s}/phy80211", .{entry.name}) catch continue;
            interfaces.access(phy_path, .{}) catch continue;
            const carrier_path = std.fmt.bufPrint(&path_buffer, "{s}/carrier", .{entry.name}) catch continue;
            var carrier: [8]u8 = undefined;
            const value = interfaces.readFile(carrier_path, &carrier) catch continue;
            if (!std.mem.eql(u8, std.mem.trim(u8, value, "\r\n"), "1")) continue;
            var interface: Interface = .{ .index = 0 };
            @memcpy(interface.name[0..entry.name.len], entry.name);
            interface.index = c.if_nametoindex(&interface.name);
            if (interface.index == 0) continue;
            if (self.connection == null) {
                self.connection = Netlink.open() catch |err| {
                    std.debug.print("Wi-Fi power-save control unavailable: {s}\n", .{@errorName(err)});
                    return;
                };
            }
            self.disable(&self.connection.?, interface) catch |err|
                std.debug.print("Unable to disable Wi-Fi power save on {s}: {s}\n", .{ interface.slice(), @errorName(err) });
        }
    }

    fn disable(self: *Guard, backend: anytype, interface: Interface) !void {
        if (self.count == max_interfaces) return error.TooManyInterfaces;
        var owned = interface;
        owned.wireless_id = try backend.identity(interface.index);
        if (!(try backend.get(interface.index))) return;
        if (try backend.identity(interface.index) != owned.wireless_id) return error.InterfaceUnavailable;
        self.changed[self.count] = owned;
        self.count += 1;
        backend.set(interface.index, false) catch |err| {
            switch (err) {
                error.AccessDenied, error.NotSupported, error.InterfaceUnavailable, error.KernelRejected => self.count -= 1,
                else => {
                    _ = restoreInterface(backend, owned) catch |rollback_error| {
                        std.debug.print("Wi-Fi power-save rollback failed on {s}: {s}\n", .{ interface.slice(), @errorName(rollback_error) });
                        return err;
                    };
                    self.count -= 1;
                },
            }
            return err;
        };
        std.debug.print("Wi-Fi power save disabled on {s}\n", .{interface.slice()});
    }

    fn restore(self: *Guard, backend: anytype) void {
        var pending: usize = 0;
        for (self.changed[0..self.count]) |interface| {
            const restored = restoreInterface(backend, interface) catch |err| {
                std.debug.print("Wi-Fi power-save restore failed on {s}: {s}\n", .{ interface.slice(), @errorName(err) });
                self.changed[pending] = interface;
                pending += 1;
                continue;
            };
            if (restored) std.debug.print("Wi-Fi power save restored on {s}\n", .{interface.slice()});
        }
        self.count = pending;
    }

    fn restoreInterface(backend: anytype, interface: Interface) !bool {
        if (backend.index(interface.slice()) != interface.index) return false;
        const identity = backend.identity(interface.index) catch |err| {
            if (err == error.InterfaceUnavailable) return false;
            return err;
        };
        // WDEV distinguishes a replacement radio reusing the name and index.
        if (identity != interface.wireless_id) return false;
        try backend.set(interface.index, true);
        return true;
    }

    pub fn end(self: *Guard) void {
        if (builtin.os.tag != .linux) return;
        if (self.connection) |*connection| {
            self.restore(connection);
            std.posix.close(connection.fd);
            self.connection = null;
        }
    }
};

const Netlink = struct {
    fd: c_int,
    family: u16 = 0,
    sequence: u32 = 0,
    response: [8192]u8 = undefined,

    fn open() !Netlink {
        const fd = c.socket(c.AF_NETLINK, c.SOCK_RAW | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK, c.NETLINK_GENERIC);
        if (fd < 0) return systemError();
        errdefer std.posix.close(fd);
        var address = std.mem.zeroes(c.struct_sockaddr_nl);
        address.nl_family = c.AF_NETLINK;
        if (c.bind(fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) < 0) return systemError();
        var result = Netlink{ .fd = fd };
        var message = Message.init(c.GENL_ID_CTRL, c.CTRL_CMD_GETFAMILY, false);
        try message.attribute(c.CTRL_ATTR_FAMILY_NAME, "nl80211\x00");
        const value = try result.request(&message, c.CTRL_ATTR_FAMILY_ID);
        if (value.len != 2) return error.InvalidReply;
        result.family = std.mem.readInt(u16, value[0..2], endian);
        return result;
    }

    fn index(_: *Netlink, name: []const u8) u32 {
        var buffer: [16:0]u8 = [_:0]u8{0} ** 16;
        if (name.len >= buffer.len) return 0;
        @memcpy(buffer[0..name.len], name);
        return c.if_nametoindex(&buffer);
    }

    fn get(self: *Netlink, interface: u32) !bool {
        var message = Message.init(self.family, c.NL80211_CMD_GET_POWER_SAVE, false);
        try message.integer(c.NL80211_ATTR_IFINDEX, interface);
        const value = try self.request(&message, c.NL80211_ATTR_PS_STATE);
        if (value.len != 4) return error.InvalidReply;
        return switch (std.mem.readInt(u32, value[0..4], endian)) {
            c.NL80211_PS_DISABLED => false,
            c.NL80211_PS_ENABLED => true,
            else => error.InvalidReply,
        };
    }

    fn identity(self: *Netlink, interface: u32) !u64 {
        var message = Message.init(self.family, c.NL80211_CMD_GET_INTERFACE, false);
        try message.integer(c.NL80211_ATTR_IFINDEX, interface);
        const value = try self.request(&message, c.NL80211_ATTR_WDEV);
        if (value.len != 8) return error.InvalidReply;
        return std.mem.readInt(u64, value[0..8], endian);
    }

    fn set(self: *Netlink, interface: u32, enabled: bool) !void {
        var message = Message.init(self.family, c.NL80211_CMD_SET_POWER_SAVE, true);
        try message.integer(c.NL80211_ATTR_IFINDEX, interface);
        try message.integer(c.NL80211_ATTR_PS_STATE, @intFromBool(enabled));
        _ = try self.request(&message, null);
    }

    fn request(self: *Netlink, message: *Message, attribute: ?u16) ![]const u8 {
        self.sequence +%= 1;
        std.mem.writeInt(u32, message.bytes[8..12], self.sequence, endian);
        var address = std.mem.zeroes(c.struct_sockaddr_nl);
        address.nl_family = c.AF_NETLINK;
        const sent = c.sendto(self.fd, &message.bytes, message.length, 0, @ptrCast(&address), @sizeOf(@TypeOf(address)));
        if (sent < 0) return systemError();
        if (sent != message.length) return error.ShortWrite;
        var timer = try std.time.Timer.start();
        const timeout = 300 * std.time.ns_per_ms;
        while (timer.read() < timeout) {
            var poll = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            const remaining: c_int = @intCast((timeout -| timer.read()) / std.time.ns_per_ms + 1);
            const ready = c.poll(&poll, 1, remaining);
            if (ready < 0) {
                if (std.posix.errno(ready) == .INTR) continue;
                return systemError();
            }
            if (ready == 0) return error.TimedOut;
            if (poll.revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0) return error.SocketError;
            var address_length: c.socklen_t = @sizeOf(@TypeOf(address));
            const received = c.recvfrom(self.fd, &self.response, self.response.len, c.MSG_TRUNC, @ptrCast(&address), &address_length);
            if (received < 0) {
                if (std.posix.errno(received) == .AGAIN or std.posix.errno(received) == .INTR) continue;
                return systemError();
            }
            if (received > self.response.len) return error.TruncatedReply;
            if (address_length != @sizeOf(@TypeOf(address)) or address.nl_pid != 0) continue;
            if (try reply(self.response[0..@intCast(received)], self.sequence, message.family(), attribute)) |value|
                return value;
        }
        return error.TimedOut;
    }
};

fn systemError() anyerror {
    return switch (std.posix.errno(@as(c_int, -1))) {
        .PERM, .ACCES => error.AccessDenied,
        .NODEV, .NXIO => error.InterfaceUnavailable,
        .OPNOTSUPP, .NOENT => error.NotSupported,
        else => error.SocketError,
    };
}

const Message = struct {
    bytes: [256]u8 = [_]u8{0} ** 256,
    length: usize = 20,

    fn init(family_id: u16, command: u8, ack: bool) Message {
        var result: Message = .{};
        std.mem.writeInt(u32, result.bytes[0..4], 20, endian);
        std.mem.writeInt(u16, result.bytes[4..6], family_id, endian);
        std.mem.writeInt(u16, result.bytes[6..8], 1 | @as(u16, if (ack) 4 else 0), endian);
        result.bytes[16] = command;
        result.bytes[17] = 1;
        return result;
    }

    fn family(self: *const Message) u16 {
        return std.mem.readInt(u16, self.bytes[4..6], endian);
    }

    fn attribute(self: *Message, kind: u16, data: []const u8) !void {
        const size = 4 + data.len;
        const aligned = std.mem.alignForward(usize, size, 4);
        if (aligned > self.bytes.len - self.length) return error.MessageTooLarge;
        const offset = self.length;
        std.mem.writeInt(u16, self.bytes[offset..][0..2], @intCast(size), endian);
        std.mem.writeInt(u16, self.bytes[offset + 2 ..][0..2], kind, endian);
        @memcpy(self.bytes[offset + 4 ..][0..data.len], data);
        self.length += aligned;
        std.mem.writeInt(u32, self.bytes[0..4], @intCast(self.length), endian);
    }

    fn integer(self: *Message, kind: u16, value: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, endian);
        try self.attribute(kind, &bytes);
    }
};

fn reply(bytes: []const u8, sequence: u32, family: u16, wanted: ?u16) !?[]const u8 {
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (bytes.len - offset < 16) return error.TruncatedReply;
        const message = bytes[offset..];
        const length = std.mem.readInt(u32, message[0..4], endian);
        if (length < 16 or length > message.len) return error.InvalidReply;
        offset += std.mem.alignForward(usize, length, 4);
        if (std.mem.readInt(u32, message[8..12], endian) != sequence) continue;
        const kind = std.mem.readInt(u16, message[4..6], endian);
        if (kind == 2) {
            if (length < 20) return error.TruncatedReply;
            const status = std.mem.readInt(i32, message[16..20], endian);
            switch (status) {
                0 => if (wanted == null) return bytes[0..0],
                -1, -13 => return error.AccessDenied,
                -19, -6 => return error.InterfaceUnavailable,
                -95, -2 => return error.NotSupported,
                else => return error.KernelRejected,
            }
            continue;
        }
        if (kind != family or wanted == null) continue;
        if (length < 20) return error.TruncatedReply;
        var attributes = message[20..length];
        while (attributes.len > 0) {
            if (attributes.len < 4) return error.TruncatedReply;
            const size = std.mem.readInt(u16, attributes[0..2], endian);
            const attribute_kind = std.mem.readInt(u16, attributes[2..4], endian) & 0x3fff;
            if (size < 4 or size > attributes.len) return error.InvalidReply;
            if (attribute_kind == wanted.?) return attributes[4..size];
            const aligned = std.mem.alignForward(usize, size, 4);
            if (aligned > attributes.len) return error.TruncatedReply;
            attributes = attributes[aligned..];
        }
        return error.MissingAttribute;
    }
    return null;
}

const Fake = struct {
    enabled: bool = true,
    writes: usize = 0,
    get_error: ?anyerror = null,
    set_error: ?anyerror = null,
    identity_error: ?anyerror = null,
    lose_ack: bool = false,
    rollback_error: bool = false,
    current_index: u32 = 3,
    current_wireless_id: u64 = 11,
    replace_on_disable: bool = false,

    fn get(self: *Fake, _: u32) !bool {
        if (self.get_error) |err| return err;
        return self.enabled;
    }

    fn set(self: *Fake, _: u32, enabled: bool) !void {
        if (self.set_error) |err| return err;
        if (enabled and self.rollback_error) return error.SocketError;
        self.enabled = enabled;
        self.writes += 1;
        if (self.replace_on_disable and !enabled) self.current_wireless_id += 1;
        if (self.lose_ack and !enabled) return error.TimedOut;
    }

    fn index(self: *Fake, _: []const u8) u32 {
        return self.current_index;
    }

    fn identity(self: *Fake, _: u32) !u64 {
        if (self.identity_error) |err| return err;
        return self.current_wireless_id;
    }
};

fn testInterface() Interface {
    var interface = Interface{ .index = 3 };
    @memcpy(interface.name[0..5], "wlan0");
    return interface;
}

test "Wi-Fi power save is disabled for a session and restored exactly once" {
    var backend: Fake = .{};
    var guard: Guard = .{};
    try guard.disable(&backend, testInterface());
    try std.testing.expect(!backend.enabled);
    try std.testing.expectEqual(@as(usize, 1), guard.count);
    guard.restore(&backend);
    try std.testing.expect(backend.enabled);
    try std.testing.expectEqual(@as(usize, 2), backend.writes);
    guard.restore(&backend);
    try std.testing.expectEqual(@as(usize, 2), backend.writes);
    try guard.disable(&backend, testInterface());
    guard.restore(&backend);
    try std.testing.expect(backend.enabled);
    try std.testing.expectEqual(@as(usize, 4), backend.writes);
}

test "preexisting disabled power save is never enabled" {
    var backend: Fake = .{ .enabled = false };
    var guard: Guard = .{};
    try guard.disable(&backend, testInterface());
    guard.restore(&backend);
    try std.testing.expect(!backend.enabled);
    try std.testing.expectEqual(@as(usize, 0), backend.writes);
}

test "unavailable or denied power-save control does not acquire ownership" {
    var guard: Guard = .{};
    var backend: Fake = .{ .get_error = error.NotSupported };
    try std.testing.expectError(error.NotSupported, guard.disable(&backend, testInterface()));
    backend.get_error = null;
    backend.set_error = error.AccessDenied;
    try std.testing.expectError(error.AccessDenied, guard.disable(&backend, testInterface()));
    guard.restore(&backend);
    try std.testing.expectEqual(@as(usize, 0), guard.count);
    try std.testing.expectEqual(@as(usize, 0), backend.writes);
}

test "a lost set acknowledgement rolls back a possibly applied change" {
    var backend: Fake = .{ .lose_ack = true };
    var guard: Guard = .{};
    try std.testing.expectError(error.TimedOut, guard.disable(&backend, testInterface()));
    try std.testing.expect(backend.enabled);
    try std.testing.expectEqual(@as(usize, 2), backend.writes);
    try std.testing.expectEqual(@as(usize, 0), guard.count);
}

test "a failed rollback keeps ownership until cleanup can retry" {
    var backend: Fake = .{ .lose_ack = true };
    var guard: Guard = .{};
    backend.rollback_error = true;
    try std.testing.expectError(error.TimedOut, guard.disable(&backend, testInterface()));
    try std.testing.expect(!backend.enabled);
    try std.testing.expectEqual(@as(usize, 1), guard.count);
    backend.rollback_error = false;
    guard.restore(&backend);
    try std.testing.expect(backend.enabled);
    try std.testing.expectEqual(@as(usize, 0), guard.count);
}

test "removed or replaced interfaces are not modified on restoration" {
    for ([_]u32{ 0, 4 }) |index| {
        var backend: Fake = .{};
        var guard: Guard = .{};
        try guard.disable(&backend, testInterface());
        backend.current_index = index;
        guard.restore(&backend);
        try std.testing.expectEqual(@as(usize, 1), backend.writes);
        try std.testing.expectEqual(@as(usize, 0), guard.count);
    }
}

test "a replacement radio reusing the name and index is not restored" {
    var backend: Fake = .{};
    var guard: Guard = .{};
    try guard.disable(&backend, testInterface());
    backend.current_wireless_id += 1;
    guard.restore(&backend);
    try std.testing.expectEqual(@as(usize, 1), backend.writes);
    try std.testing.expectEqual(@as(usize, 0), guard.count);
}

test "rollback does not modify a replacement radio after a lost acknowledgement" {
    var backend: Fake = .{ .lose_ack = true, .replace_on_disable = true };
    var guard: Guard = .{};
    try std.testing.expectError(error.TimedOut, guard.disable(&backend, testInterface()));
    try std.testing.expectEqual(@as(usize, 1), backend.writes);
    try std.testing.expectEqual(@as(usize, 0), guard.count);
}

test "unavailable identity prevents mutation and temporary lookup failure retains restoration" {
    var backend: Fake = .{ .identity_error = error.NotSupported };
    var guard: Guard = .{};
    try std.testing.expectError(error.NotSupported, guard.disable(&backend, testInterface()));
    try std.testing.expectEqual(@as(usize, 0), backend.writes);
    backend.identity_error = null;
    try guard.disable(&backend, testInterface());
    backend.identity_error = error.TimedOut;
    guard.restore(&backend);
    try std.testing.expectEqual(@as(usize, 1), guard.count);
    try std.testing.expectEqual(@as(usize, 1), backend.writes);
    backend.identity_error = null;
    guard.restore(&backend);
    try std.testing.expect(backend.enabled);
    try std.testing.expectEqual(@as(usize, 0), guard.count);
}

test "restoration failure is bounded and retains ownership for a later attempt" {
    var backend: Fake = .{};
    var guard: Guard = .{};
    try guard.disable(&backend, testInterface());
    backend.set_error = error.InterfaceUnavailable;
    guard.restore(&backend);
    try std.testing.expectEqual(@as(usize, 1), guard.count);
    try std.testing.expectEqual(@as(usize, 1), backend.writes);
    backend.set_error = null;
    guard.restore(&backend);
    try std.testing.expect(backend.enabled);
    try std.testing.expectEqual(@as(usize, 0), guard.count);
}

test "interface capacity is checked before changing power save" {
    var backend: Fake = .{};
    var guard: Guard = .{ .count = max_interfaces };
    try std.testing.expectError(error.TooManyInterfaces, guard.disable(&backend, testInterface()));
    try std.testing.expectEqual(@as(usize, 0), backend.writes);
}

test "netlink messages align attributes and keep native-endian integers" {
    var message = Message.init(16, 3, false);
    try message.attribute(2, "nl80211\x00");
    try message.integer(3, 123);
    try std.testing.expectEqual(@as(usize, 40), message.length);
    try std.testing.expectEqual(@as(u16, 12), std.mem.readInt(u16, message.bytes[20..22], endian));
    try std.testing.expectEqual(@as(u32, 123), std.mem.readInt(u32, message.bytes[36..40], endian));
    var too_large: [256]u8 = undefined;
    try std.testing.expectError(error.MessageTooLarge, message.attribute(1, &too_large));
}

fn testReply(kind: u16) Message {
    var message = Message.init(kind, 62, false);
    std.mem.writeInt(u32, message.bytes[8..12], 42, endian);
    return message;
}

test "netlink response matches family sequence and attribute" {
    var message = testReply(21);
    try message.integer(93, 1);
    const bytes = message.bytes[0..message.length];
    const value = (try reply(bytes, 42, 21, 93)).?;
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, value[0..4], endian));
    try std.testing.expectEqual(@as(?[]const u8, null), try reply(bytes, 41, 21, 93));
    try std.testing.expectEqual(@as(?[]const u8, null), try reply(bytes, 42, 22, 93));
    try std.testing.expectError(error.MissingAttribute, reply(bytes, 42, 21, 94));
}

test "netlink kernel acknowledgements and errors are distinguished" {
    var message = testReply(2);
    std.mem.writeInt(i32, message.bytes[16..20], 0, endian);
    try std.testing.expect((try reply(message.bytes[0..20], 42, 21, null)) != null);
    try std.testing.expect((try reply(message.bytes[0..20], 42, 21, 93)) == null);
    for ([_]struct { status: i32, err: anyerror }{
        .{ .status = -1, .err = error.AccessDenied },
        .{ .status = -13, .err = error.AccessDenied },
        .{ .status = -19, .err = error.InterfaceUnavailable },
        .{ .status = -95, .err = error.NotSupported },
        .{ .status = -22, .err = error.KernelRejected },
    }) |case| {
        std.mem.writeInt(i32, message.bytes[16..20], case.status, endian);
        try std.testing.expectError(case.err, reply(message.bytes[0..20], 42, 21, null));
    }
}

test "netlink rejects truncated headers and malformed attributes" {
    var message = testReply(21);
    try message.integer(93, 1);
    try std.testing.expectError(error.TruncatedReply, reply(message.bytes[0..15], 42, 21, 93));
    try std.testing.expectError(error.InvalidReply, reply(message.bytes[0..27], 42, 21, 93));
    std.mem.writeInt(u16, message.bytes[20..22], 3, endian);
    try std.testing.expectError(error.InvalidReply, reply(message.bytes[0..message.length], 42, 21, 93));
    std.mem.writeInt(u16, message.bytes[20..22], 100, endian);
    try std.testing.expectError(error.InvalidReply, reply(message.bytes[0..message.length], 42, 21, 93));
}
