const std = @import("std");
const gfn_stream_preferences = @import("gfn_stream_preferences");

pub const max_games = 1024;
pub const product_id_capacity = 64;

pub const FaceButtonMode = enum {
    system,
    swapped,
};

pub const GameSettings = struct {
    product_id: [product_id_capacity]u8 = [_]u8{0} ** product_id_capacity,
    favorite: bool = false,
};

pub const Store = struct {
    path: [512]u8 = [_]u8{0} ** 512,
    path_length: usize = 0,
    face_buttons: FaceButtonMode = .system,
    artwork_enabled: bool = true,
    geforce_now: gfn_stream_preferences.Preferences = .{},
    games: [max_games]GameSettings = [_]GameSettings{.{}} ** max_games,
    game_count: usize = 0,

    pub fn init(path: ?[]const u8) !Store {
        var store = Store{};
        if (path) |value| {
            if (value.len == 0 or value.len >= store.path.len) return error.InvalidPath;
            @memcpy(store.path[0..value.len], value);
            store.path_length = value.len;
            store.load() catch |err| switch (err) {
                error.FileNotFound => {},
                else => std.debug.print("Ignoring invalid settings: {s}\n", .{@errorName(err)}),
            };
        }
        return store;
    }

    pub fn game(self: *Store, product_id: []const u8) ?*GameSettings {
        if (!validProductId(product_id)) return null;
        for (self.games[0..self.game_count]) |*entry| {
            if (std.mem.eql(u8, productId(entry), product_id)) return entry;
        }
        if (self.game_count == self.games.len) return null;
        const entry = &self.games[self.game_count];
        entry.* = .{};
        @memcpy(entry.product_id[0..product_id.len], product_id);
        self.game_count += 1;
        return entry;
    }

    pub fn findGame(self: *const Store, product_id: []const u8) ?*const GameSettings {
        for (self.games[0..self.game_count]) |*entry| {
            if (std.mem.eql(u8, productId(entry), product_id)) return entry;
        }
        return null;
    }

    pub fn save(self: *const Store) !void {
        const path = self.path[0..self.path_length];
        if (path.len == 0) return;
        var temporary_buffer: [517]u8 = undefined;
        const temporary_path = try std.fmt.bufPrint(&temporary_buffer, "{s}.tmp", .{path});
        const cwd = std.fs.cwd();
        errdefer cwd.deleteFile(temporary_path) catch {};

        var file = try cwd.createFile(temporary_path, .{ .truncate = true, .mode = 0o600 });
        var closed = false;
        defer if (!closed) file.close();
        try self.write(file.writer());
        try file.sync();
        file.close();
        closed = true;
        try cwd.rename(temporary_path, path);
    }

    fn write(self: *const Store, writer: anytype) !void {
        try writer.writeAll("version\t1\n");
        try writer.print("face_buttons\t{s}\n", .{@tagName(self.face_buttons)});
        try writer.print("artwork\t{d}\n", .{@intFromBool(self.artwork_enabled)});
        try writer.print("geforce_now.frames_per_second\t{d}\n", .{self.geforce_now.frames_per_second});
        try writer.print("geforce_now.max_bitrate_kbps\t{d}\n", .{self.geforce_now.max_bitrate_kbps});
        for (self.games[0..self.game_count]) |*entry| {
            try writer.print("game\t{s}\t{d}\n", .{
                productId(entry),
                @intFromBool(entry.favorite),
            });
        }
    }

    fn load(self: *Store) !void {
        const file = try std.fs.cwd().openFile(self.path[0..self.path_length], .{});
        defer file.close();
        const data = try file.readToEndAlloc(std.heap.page_allocator, 256 * 1024);
        defer std.heap.page_allocator.free(data);
        var parsed = Store{};
        parsed.path = self.path;
        parsed.path_length = self.path_length;
        try parsed.parse(data);
        self.* = parsed;
    }

    fn parse(self: *Store, data: []const u8) !void {
        var lines = std.mem.splitScalar(u8, data, '\n');
        var found_version = false;
        while (lines.next()) |raw_line| {
            const line = std.mem.trimRight(u8, raw_line, "\r");
            if (line.len == 0) continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const kind = fields.next() orelse continue;
            if (!found_version) {
                if (!std.mem.eql(u8, kind, "version") or
                    !std.mem.eql(u8, fields.next() orelse "", "1") or
                    fields.next() != null) return error.UnsupportedSettings;
                found_version = true;
                continue;
            }
            if (std.mem.eql(u8, kind, "version")) {
                return error.UnsupportedSettings;
            } else if (std.mem.eql(u8, kind, "face_buttons")) {
                const value = fields.next() orelse continue;
                if (std.mem.eql(u8, value, "system")) self.face_buttons = .system;
                if (std.mem.eql(u8, value, "swapped")) self.face_buttons = .swapped;
            } else if (std.mem.eql(u8, kind, "artwork")) {
                const value = fields.next() orelse continue;
                self.artwork_enabled = std.mem.eql(u8, value, "1");
            } else if (std.mem.eql(u8, kind, "geforce_now.frames_per_second")) {
                const value = fields.next() orelse continue;
                const parsed = std.fmt.parseUnsigned(u16, value, 10) catch continue;
                if (gfn_stream_preferences.validFramesPerSecond(parsed))
                    self.geforce_now.frames_per_second = parsed;
            } else if (std.mem.eql(u8, kind, "geforce_now.max_bitrate_kbps")) {
                const value = fields.next() orelse continue;
                const parsed = std.fmt.parseUnsigned(u32, value, 10) catch continue;
                if (gfn_stream_preferences.validBitrate(parsed))
                    self.geforce_now.max_bitrate_kbps = parsed;
            } else if (std.mem.eql(u8, kind, "game")) {
                const id = fields.next() orelse continue;
                const favorite = fields.next() orelse continue;
                const entry = self.game(id) orelse continue;
                entry.favorite = std.mem.eql(u8, favorite, "1");
            }
        }
        if (!found_version) return error.UnsupportedSettings;
    }
};

pub fn productId(game_settings: *const GameSettings) []const u8 {
    return std.mem.sliceTo(&game_settings.product_id, 0);
}

pub fn validProductId(value: []const u8) bool {
    if (value.len == 0 or value.len >= product_id_capacity) return false;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    }
    return true;
}

test "settings round trip through the file format" {
    var store = Store{};
    store.face_buttons = .swapped;
    store.artwork_enabled = false;
    store.geforce_now = .{ .frames_per_second = 60, .max_bitrate_kbps = 12000 };
    const game_settings = store.game("PRODUCT-1").?;
    game_settings.favorite = true;

    var data = std.ArrayList(u8).init(std.testing.allocator);
    defer data.deinit();
    try store.write(data.writer());

    var parsed = Store{};
    try parsed.parse(data.items);
    try std.testing.expectEqual(FaceButtonMode.swapped, parsed.face_buttons);
    try std.testing.expect(!parsed.artwork_enabled);
    try std.testing.expectEqualDeep(store.geforce_now, parsed.geforce_now);
    const parsed_game = parsed.findGame("PRODUCT-1").?;
    try std.testing.expect(parsed_game.favorite);
}

test "settings reject unknown versions and unsafe ids" {
    var store = Store{};
    try std.testing.expectError(error.UnsupportedSettings, store.parse("version\t2\n"));
    try std.testing.expectError(error.UnsupportedSettings, store.parse("version\t2\nversion\t1\n"));
    try std.testing.expectError(error.UnsupportedSettings, store.parse("version\t1\nversion\t1\n"));
    try std.testing.expectError(error.UnsupportedSettings, store.parse("artwork\t0\nversion\t1\n"));
    try std.testing.expect(store.game("bad\tid") == null);
}

test "settings keep GFN stream quality within the supported choices" {
    var store = Store{};
    try store.parse("version\t1\ngeforce_now.frames_per_second\t60\ngeforce_now.max_bitrate_kbps\t12000\n");
    try std.testing.expectEqual(@as(u16, 60), store.geforce_now.frames_per_second);
    try std.testing.expectEqual(@as(u32, 12000), store.geforce_now.max_bitrate_kbps);

    var invalid = Store{};
    try invalid.parse("version\t1\ngeforce_now.frames_per_second\t1\ngeforce_now.max_bitrate_kbps\t0\n");
    try std.testing.expectEqualDeep(gfn_stream_preferences.Preferences{}, invalid.geforce_now);

    try invalid.parse("version\t1\ngeforce_now.max_bitrate_kbps\t4294967295\n");
    try std.testing.expectEqualDeep(gfn_stream_preferences.Preferences{}, invalid.geforce_now);
}

test "only GFN-qualified keys change GFN quality" {
    var store = Store{};
    try store.parse("version\t1\nxbox.frames_per_second\t60\nxbox.max_bitrate_kbps\t16000\nframes_per_second\t60\nmax_bitrate_kbps\t16000\n");
    try std.testing.expectEqualDeep(gfn_stream_preferences.Preferences{}, store.geforce_now);
}

test "provider preferences survive saving and reopening the settings file" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const root = try directory.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "settings.tsv" });
    defer std.testing.allocator.free(path);
    var store = try Store.init(path);
    store.geforce_now = .{ .frames_per_second = 60, .max_bitrate_kbps = 16000 };
    store.face_buttons = .swapped;
    store.artwork_enabled = false;
    try store.save();

    const reloaded = try Store.init(path);
    try std.testing.expectEqualDeep(store.geforce_now, reloaded.geforce_now);
    try std.testing.expectEqual(store.face_buttons, reloaded.face_buttons);
    try std.testing.expectEqual(store.artwork_enabled, reloaded.artwork_enabled);
}
