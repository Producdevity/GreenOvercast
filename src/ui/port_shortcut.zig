const std = @import("std");
const builtin = @import("builtin");
const settings = @import("persistent_settings.zig");

// Second line of every generated script; only files carrying it are ever replaced or removed.
pub const marker = "# GreenOvercast game shortcut";
pub const name_capacity = 64;
/// Longest launcher path writeScript accepts; keeps every script within what state() reads.
pub const max_launcher_length = 512;
/// Written only when the shortcut created its artwork. Port artwork folders such as muOS's
/// shared catalogue also hold other ports' images, so artwork is replaced or removed only
/// when this record exists and still matches the file on disk.
pub const artwork_prefix = "# GreenOvercast artwork: ";
const max_artwork_bytes = 4 * 1024 * 1024;

const script_read_capacity = 1024;
const max_script_length = ("#!/bin/bash\n" ++ marker ++ "\n").len + "# \n".len + name_capacity +
    "export GREENOVERCAST_SERVICE=geforce-now\n".len + "export GREENOVERCAST_AUTOSTART=1\n".len +
    (artwork_prefix ++ "crc32=00000000 size=\n").len + std.fmt.count("{d}", .{std.math.maxInt(u64)}) +
    "exec /bin/bash '' ''\n".len + max_launcher_length + settings.product_id_capacity;
comptime {
    std.debug.assert(max_script_length < script_read_capacity);
}

pub const Service = enum {
    xbox,
    geforce_now,

    fn value(self: Service) []const u8 {
        return switch (self) {
            .xbox => "xbox",
            .geforce_now => "geforce-now",
        };
    }
};

pub const Shortcut = struct {
    /// Absolute path of the GreenOvercast port launcher the shortcut runs.
    launcher: []const u8,
    service: Service,
    product_id: []const u8,
};

pub const State = enum {
    absent,
    shortcut,
    foreign,
};

/// Identifies the exact artwork file a shortcut wrote.
pub const ArtworkRecord = struct {
    crc32: u32,
    size: u64,

    pub fn of(data: []const u8) ArtworkRecord {
        return .{ .crc32 = std.hash.Crc32.hash(data), .size = data.len };
    }
};

/// Turns a catalog title into a file name every CFW frontend accepts: printable ASCII
/// without path, quoting or wildcard characters, single spaces, no leading or trailing
/// spaces or dots.
pub fn portName(buffer: *[name_capacity]u8, title: []const u8) []const u8 {
    var length: usize = 0;
    var pending_space = false;
    for (title) |byte| {
        const keep = std.ascii.isAlphanumeric(byte) or switch (byte) {
            '-', '_', '.', ',', '!', '&', '(', ')', '+', '\'' => true,
            else => false,
        };
        if (!keep) {
            if (byte == ' ' or byte == ':' or byte == '/' or byte == '\t') pending_space = length > 0;
            continue;
        }
        if (pending_space) {
            if (length + 1 >= buffer.len) break;
            buffer[length] = ' ';
            length += 1;
            pending_space = false;
        }
        if (length == buffer.len) break;
        buffer[length] = byte;
        length += 1;
    }
    while (length > 0 and (buffer[length - 1] == ' ' or buffer[length - 1] == '.')) length -= 1;
    var start: usize = 0;
    while (start < length and (buffer[start] == '.' or buffer[start] == ' ')) start += 1;
    return buffer[start..length];
}

pub fn writeScript(writer: anytype, shortcut: Shortcut, name: []const u8, artwork: ?ArtworkRecord) !void {
    if (!std.fs.path.isAbsolute(shortcut.launcher) or shortcut.launcher.len > max_launcher_length or
        std.mem.indexOfAny(u8, shortcut.launcher, "'\n\r") != null) return error.InvalidLauncher;
    if (!settings.validProductId(shortcut.product_id)) return error.InvalidProductId;
    // portName() already guarantees these; checked here too because a ':' could make the
    // "# <name>" comment imitate the artwork record line.
    if (name.len == 0 or name.len > name_capacity or std.mem.indexOfAny(u8, name, "\n\r:") != null)
        return error.InvalidName;
    try writer.writeAll("#!/bin/bash\n" ++ marker ++ "\n");
    try writer.print("# {s}\n", .{name});
    try writer.print("export GREENOVERCAST_SERVICE={s}\n", .{shortcut.service.value()});
    try writer.writeAll("export GREENOVERCAST_AUTOSTART=1\n");
    if (artwork) |record|
        try writer.print(artwork_prefix ++ "crc32={x:0>8} size={d}\n", .{ record.crc32, record.size });
    // exec keeps $0 as the real launcher, which PortMaster's control.txt resolves GAMEDIR from.
    try writer.print("exec /bin/bash '{s}' '{s}'\n", .{ shortcut.launcher, shortcut.product_id });
}

const Inspection = struct {
    state: State,
    content: []const u8 = "",
};

fn inspect(
    directory: std.fs.Dir,
    script_name: []const u8,
    product_id: []const u8,
    buffer: *[script_read_capacity]u8,
) Inspection {
    const file = directory.openFile(script_name, .{}) catch |err| return switch (err) {
        error.FileNotFound => .{ .state = .absent },
        else => .{ .state = .foreign },
    };
    defer file.close();
    const length = file.readAll(buffer) catch return .{ .state = .foreign };
    if (length == buffer.len) return .{ .state = .foreign };
    const content = buffer[0..length];
    var lines = std.mem.splitScalar(u8, content, '\n');
    _ = lines.next();
    const second = lines.next() orelse return .{ .state = .foreign };
    if (!std.mem.eql(u8, second, marker)) return .{ .state = .foreign };
    var ending_buffer: [settings.product_id_capacity + 8]u8 = undefined;
    const ending = std.fmt.bufPrint(&ending_buffer, " '{s}'\n", .{product_id}) catch
        return .{ .state = .foreign };
    if (!std.mem.endsWith(u8, content, ending)) return .{ .state = .foreign };
    return .{ .state = .shortcut, .content = content };
}

/// `.shortcut` only for a generated script that launches this product. Different titles
/// can share a port name, so a marked script for another product counts as foreign.
pub fn state(directory: std.fs.Dir, script_name: []const u8, product_id: []const u8) State {
    var buffer: [script_read_capacity]u8 = undefined;
    return inspect(directory, script_name, product_id, &buffer).state;
}

/// The artwork a generated script recorded as its own, if any.
pub fn recordedArtwork(script: []const u8) ?ArtworkRecord {
    var lines = std.mem.splitScalar(u8, script, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, artwork_prefix)) continue;
        var fields = std.mem.tokenizeScalar(u8, line[artwork_prefix.len..], ' ');
        const crc_field = fields.next() orelse return null;
        const size_field = fields.next() orelse return null;
        if (fields.next() != null or !std.mem.startsWith(u8, crc_field, "crc32=") or
            !std.mem.startsWith(u8, size_field, "size=")) return null;
        return .{
            .crc32 = std.fmt.parseUnsigned(u32, crc_field["crc32=".len..], 16) catch return null,
            .size = std.fmt.parseUnsigned(u64, size_field["size=".len..], 10) catch return null,
        };
    }
    return null;
}

/// The artwork's bytes when the file on disk is still exactly what `record` describes, so
/// add() can restore it if saving the script fails. Reads the file rather than calling
/// stat(), which needs statx and fails on 4.9 kernels. Free with std.heap.page_allocator.
fn readOwnedArtwork(directory: std.fs.Dir, cover_name: []const u8, record: ArtworkRecord) ?[]u8 {
    const file = directory.openFile(cover_name, .{}) catch return null;
    defer file.close();
    const data = file.readToEndAlloc(std.heap.page_allocator, max_artwork_bytes) catch return null;
    const current = ArtworkRecord.of(data);
    if (current.crc32 == record.crc32 and current.size == record.size) return data;
    std.heap.page_allocator.free(data);
    return null;
}

fn artworkMatches(directory: std.fs.Dir, cover_name: []const u8, record: ArtworkRecord) bool {
    const data = readOwnedArtwork(directory, cover_name, record) orelse return false;
    std.heap.page_allocator.free(data);
    return true;
}

/// Creates a file that must not exist yet. If another writer creates the name after our
/// existence check, this fails with error.PathAlreadyExists instead of replacing their file.
/// Exclusive creation rather than a no-replace rename, which FUSE filesystems such as the
/// muOS catalogue's do not reliably support. A failed write removes only the file it created.
fn writeNew(directory: std.fs.Dir, name: []const u8, data: []const u8, mode: std.fs.File.Mode) !void {
    var file = try directory.createFile(name, .{ .exclusive = true });
    var complete = false;
    defer {
        file.close();
        if (!complete) directory.deleteFile(name) catch {};
    }
    try file.writeAll(data);
    // The port launcher runs under umask 077; frontends need to read the artwork.
    try file.chmod(mode);
    try file.sync();
    complete = true;
}

fn artworkExists(directory: std.fs.Dir, cover_name: []const u8) bool {
    directory.access(cover_name, .{}) catch |err| return err != error.FileNotFound;
    return true;
}

/// Test seam, compiled out of other builds: runs after add() writes artwork and before it
/// saves the script, so tests can see the state a failed save has to roll back.
var after_artwork_write_for_tests: ?*const fn () void = null;

/// Creates the shortcut, or rewrites it when it already exists for this title. The UI only
/// adds absent shortcuts (Select on an existing one removes it), but re-adding is handled
/// too: an image the shortcut owns is replaced, or kept with its record without a new cover.
pub fn add(
    ports: std.fs.Dir,
    artwork: ?std.fs.Dir,
    shortcut: Shortcut,
    name: []const u8,
    cover_png: ?[]const u8,
) !void {
    var script_buffer: [name_capacity + 8]u8 = undefined;
    const script_name = try std.fmt.bufPrint(&script_buffer, "{s}.sh", .{name});
    var existing_buffer: [script_read_capacity]u8 = undefined;
    const existing = inspect(ports, script_name, shortcut.product_id, &existing_buffer);
    if (existing.state == .foreign) return error.NameInUse;

    var cover_buffer: [name_capacity + 8]u8 = undefined;
    const cover_name = try std.fmt.bufPrint(&cover_buffer, "{s}.png", .{name});

    // Only an image this shortcut wrote, still unchanged on disk, counts as its own. Its
    // bytes are kept so it can be restored if saving the script fails.
    var previous: ?ArtworkRecord = null;
    var previous_bytes: ?[]u8 = null;
    defer if (previous_bytes) |bytes| std.heap.page_allocator.free(bytes);
    if (artwork) |directory| if (recordedArtwork(existing.content)) |record| {
        if (readOwnedArtwork(directory, cover_name, record)) |bytes| {
            previous = record;
            previous_bytes = bytes;
        }
    };

    const ArtworkPlan = enum { keep, create, replace };
    const plan: ArtworkPlan = plan: {
        const directory = artwork orelse break :plan .keep;
        if (cover_png == null) break :plan .keep;
        if (previous != null) break :plan .replace;
        if (!artworkExists(directory, cover_name)) break :plan .create;
        std.debug.print("Existing artwork kept: {s}\n", .{cover_name});
        break :plan .keep;
    };

    // Build and validate the script before touching any file.
    var content = std.ArrayList(u8).init(std.heap.page_allocator);
    defer content.deinit();
    try writeScript(content.writer(), shortcut, name, if (plan == .keep) previous else ArtworkRecord.of(cover_png.?));

    var written = plan;
    switch (plan) {
        .keep => {},
        .create => writeNew(artwork.?, cover_name, cover_png.?, 0o644) catch |err| {
            written = .keep;
            if (err == error.PathAlreadyExists)
                std.debug.print("Existing artwork kept: {s}\n", .{cover_name})
            else
                std.debug.print("Shortcut artwork could not be saved: {s}\n", .{@errorName(err)});
        },
        .replace => writeAtomic(artwork.?, cover_name, cover_png.?, 0o644) catch |err| {
            written = .keep;
            std.debug.print("Shortcut artwork could not be saved: {s}\n", .{@errorName(err)});
        },
    }
    if (builtin.is_test) if (after_artwork_write_for_tests) |hook| hook();
    // Never record an image that is not on disk: fall back to what the shortcut owned before.
    if (written != plan) {
        content.clearRetainingCapacity();
        try writeScript(content.writer(), shortcut, name, previous);
    }

    writeAtomic(ports, script_name, content.items, 0o755) catch |err| {
        // Roll the artwork back so the existing script and its record stay consistent.
        switch (written) {
            .keep => {},
            .create => artwork.?.deleteFile(cover_name) catch {},
            .replace => writeAtomic(artwork.?, cover_name, previous_bytes.?, 0o644) catch |restore_err|
                std.debug.print("Shortcut artwork could not be restored: {s}\n", .{@errorName(restore_err)}),
        }
        return err;
    };
}

pub fn remove(ports: std.fs.Dir, artwork: ?std.fs.Dir, name: []const u8, product_id: []const u8) !void {
    var script_buffer: [name_capacity + 8]u8 = undefined;
    const script_name = try std.fmt.bufPrint(&script_buffer, "{s}.sh", .{name});
    var existing_buffer: [script_read_capacity]u8 = undefined;
    const existing = inspect(ports, script_name, product_id, &existing_buffer);
    if (existing.state != .shortcut) return error.NotAShortcut;
    // Artwork first and best-effort, so the script is removed last and any error reported
    // matches what is still on disk. Only an image this shortcut wrote, unchanged since,
    // is removed; anything else in the shared artwork folder belongs to someone else.
    // Verifying and deleting are separate steps, as POSIX has no compare-and-delete. That
    // leaves a short window, but GreenOvercast runs in the foreground on these single-app
    // handhelds, so nothing else writes the catalogue while a shortcut is being removed.
    // If the owned artwork cannot be deleted, the script stays: it is the only record of
    // that image, and keeping it lets a later attempt clean up instead of leaving an image
    // nobody owns. A null `artwork` means this system has no artwork folder at all.
    if (artwork) |directory| if (recordedArtwork(existing.content)) |record| {
        var cover_buffer: [name_capacity + 8]u8 = undefined;
        const cover_name = try std.fmt.bufPrint(&cover_buffer, "{s}.png", .{name});
        if (artworkMatches(directory, cover_name, record)) {
            directory.deleteFile(cover_name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => {
                    std.debug.print("Shortcut artwork could not be removed: {s}\n", .{@errorName(err)});
                    return err;
                },
            };
        } else if (artworkExists(directory, cover_name)) {
            std.debug.print("Artwork changed since the shortcut saved it, kept: {s}\n", .{cover_name});
        }
    };
    try ports.deleteFile(script_name);
}

fn writeAtomic(directory: std.fs.Dir, name: []const u8, data: []const u8, mode: std.fs.File.Mode) !void {
    // AtomicFile creates a randomly named temporary exclusively, so nothing else in the
    // shared Ports folder can be overwritten before the final rename.
    var file = try directory.atomicFile(name, .{ .mode = mode });
    defer file.deinit();
    try file.file.writeAll(data);
    // The port launcher runs under umask 077; frontends need to read and run shortcuts.
    try file.file.chmod(mode);
    try file.file.sync();
    try file.finish();
}

test "port names keep readable titles and drop unsafe characters" {
    var buffer: [name_capacity]u8 = undefined;
    try std.testing.expectEqualStrings("CONTROL Resonant", portName(&buffer, "CONTROL Resonant"));
    try std.testing.expectEqualStrings(
        "Ori and the Will of the Wisps",
        portName(&buffer, "Ori and the Will of the Wisps\xe2\x84\xa2"),
    );
    try std.testing.expectEqualStrings("Fallout 4 GOTY", portName(&buffer, "Fallout 4: GOTY"));
    try std.testing.expectEqualStrings("Aerial Knight's Never Yield", portName(&buffer, "Aerial Knight's  Never Yield"));
    try std.testing.expectEqualStrings("AC DC", portName(&buffer, " ../AC/DC\"*?. "));
    try std.testing.expectEqualStrings("", portName(&buffer, "\xe5\x8e\x9f\xe7\xa5\x9e"));
    const long = portName(&buffer, "A" ** 100);
    try std.testing.expectEqual(@as(usize, name_capacity), long.len);
}

test "shortcut script relaunches the port launcher straight into the title" {
    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();
    try writeScript(output.writer(), .{
        .launcher = "/mnt/sdcard/ROMS/PORTS/GreenOvercast.sh",
        .service = .geforce_now,
        .product_id = "a1b2-C3",
    }, "CONTROL", null);
    try std.testing.expectEqualStrings(
        "#!/bin/bash\n" ++ marker ++ "\n# CONTROL\n" ++
            "export GREENOVERCAST_SERVICE=geforce-now\n" ++
            "export GREENOVERCAST_AUTOSTART=1\n" ++
            "exec /bin/bash '/mnt/sdcard/ROMS/PORTS/GreenOvercast.sh' 'a1b2-C3'\n",
        output.items,
    );
}

test "shortcut script records the artwork it owns" {
    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();
    const record = ArtworkRecord{ .crc32 = 0x0a1b2c3d, .size = 104952 };
    try writeScript(output.writer(), .{
        .launcher = "/mnt/sdcard/ROMS/PORTS/GreenOvercast.sh",
        .service = .xbox,
        .product_id = "9NBLGGH4R315",
    }, "Halo", record);
    try std.testing.expectEqualStrings(
        "#!/bin/bash\n" ++ marker ++ "\n# Halo\n" ++
            "export GREENOVERCAST_SERVICE=xbox\n" ++
            "export GREENOVERCAST_AUTOSTART=1\n" ++
            artwork_prefix ++ "crc32=0a1b2c3d size=104952\n" ++
            "exec /bin/bash '/mnt/sdcard/ROMS/PORTS/GreenOvercast.sh' '9NBLGGH4R315'\n",
        output.items,
    );
    try std.testing.expectEqual(record, recordedArtwork(output.items).?);
    try std.testing.expectEqual(@as(?ArtworkRecord, null), recordedArtwork("#!/bin/bash\n" ++ marker ++ "\n"));
    try std.testing.expectEqual(@as(?ArtworkRecord, null), recordedArtwork(artwork_prefix ++ "crc32=zz size=1\n"));
}

test "shortcut script rejects values that would break shell quoting" {
    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();
    const base = Shortcut{ .launcher = "/roms/ports/GreenOvercast.sh", .service = .xbox, .product_id = "9NBLGGH4R315" };
    var shortcut = base;
    shortcut.launcher = "/roms/ports/it's/GreenOvercast.sh";
    try std.testing.expectError(error.InvalidLauncher, writeScript(output.writer(), shortcut, "X", null));
    shortcut = base;
    shortcut.launcher = "ports/GreenOvercast.sh";
    try std.testing.expectError(error.InvalidLauncher, writeScript(output.writer(), shortcut, "X", null));
    shortcut = base;
    shortcut.product_id = "id' ; rm -rf /";
    try std.testing.expectError(error.InvalidProductId, writeScript(output.writer(), shortcut, "X", null));
}

test "shortcuts are added and removed without touching other ports" {
    var ports = std.testing.tmpDir(.{});
    defer ports.cleanup();
    var artwork = std.testing.tmpDir(.{});
    defer artwork.cleanup();
    const shortcut = Shortcut{
        .launcher = "/roms/ports/GreenOvercast.sh",
        .service = .xbox,
        .product_id = "9NBLGGH4R315",
    };

    const product = shortcut.product_id;

    try add(ports.dir, artwork.dir, shortcut, "Halo", "png-bytes");
    try std.testing.expectEqual(State.shortcut, state(ports.dir, "Halo.sh", product));
    const stat = try ports.dir.statFile("Halo.sh");
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o755), stat.mode & 0o777);
    var cover_buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("png-bytes", try artwork.dir.readFile("Halo.png", &cover_buffer));
    // Re-adding the same title replaces its own shortcut.
    try add(ports.dir, artwork.dir, shortcut, "Halo", "png-bytes");

    try ports.dir.writeFile(.{ .sub_path = "Celeste.sh", .data = "#!/bin/bash\n# PortMaster\n" });
    try ports.dir.writeFile(.{ .sub_path = "Celeste.sh.tmp", .data = "unrelated" });
    try std.testing.expectError(error.NameInUse, add(ports.dir, null, shortcut, "Celeste", null));
    try std.testing.expectError(error.NotAShortcut, remove(ports.dir, null, "Celeste", product));
    try std.testing.expectEqual(State.foreign, state(ports.dir, "Celeste.sh", product));
    var tmp_buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("unrelated", try ports.dir.readFile("Celeste.sh.tmp", &tmp_buffer));

    try remove(ports.dir, artwork.dir, "Halo", product);
    try std.testing.expectEqual(State.absent, state(ports.dir, "Halo.sh", product));
    try std.testing.expectError(error.FileNotFound, artwork.dir.access("Halo.png", .{}));
}

const celeste = Shortcut{ .launcher = "/roms/ports/GreenOvercast.sh", .service = .geforce_now, .product_id = "gfn-celeste" };

fn expectArtwork(directory: std.fs.Dir, expected: []const u8) !void {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try directory.readFile("Celeste.png", &buffer));
}

test "existing artwork survives a shortcut added without a cover" {
    // muOS shares one artwork catalogue between the Ports folders on both cards, so a
    // native Celeste port elsewhere can already own Celeste.png.
    var ports = std.testing.tmpDir(.{});
    defer ports.cleanup();
    var artwork = std.testing.tmpDir(.{});
    defer artwork.cleanup();
    try artwork.dir.writeFile(.{ .sub_path = "Celeste.png", .data = "native-port-art" });

    try add(ports.dir, artwork.dir, celeste, "Celeste", null);
    try expectArtwork(artwork.dir, "native-port-art");
    try remove(ports.dir, artwork.dir, "Celeste", celeste.product_id);
    try expectArtwork(artwork.dir, "native-port-art");
    try std.testing.expectEqual(State.absent, state(ports.dir, "Celeste.sh", celeste.product_id));
}

test "existing artwork is neither overwritten nor removed by a shortcut with a cover" {
    var ports = std.testing.tmpDir(.{});
    defer ports.cleanup();
    var artwork = std.testing.tmpDir(.{});
    defer artwork.cleanup();
    try artwork.dir.writeFile(.{ .sub_path = "Celeste.png", .data = "native-port-art" });

    try add(ports.dir, artwork.dir, celeste, "Celeste", "shortcut-art");
    try expectArtwork(artwork.dir, "native-port-art");
    var script_buffer: [script_read_capacity]u8 = undefined;
    try std.testing.expectEqual(
        @as(?ArtworkRecord, null),
        recordedArtwork(try ports.dir.readFile("Celeste.sh", &script_buffer)),
    );
    try remove(ports.dir, artwork.dir, "Celeste", celeste.product_id);
    try expectArtwork(artwork.dir, "native-port-art");
}

test "a shortcut replaces and removes only the artwork it wrote" {
    var ports = std.testing.tmpDir(.{});
    defer ports.cleanup();
    var artwork = std.testing.tmpDir(.{});
    defer artwork.cleanup();

    try add(ports.dir, artwork.dir, celeste, "Celeste", "shortcut-art-1");
    try expectArtwork(artwork.dir, "shortcut-art-1");
    var script_buffer: [script_read_capacity]u8 = undefined;
    try std.testing.expectEqual(
        ArtworkRecord.of("shortcut-art-1"),
        recordedArtwork(try ports.dir.readFile("Celeste.sh", &script_buffer)).?,
    );

    // Re-adding replaces the image it owns and records the new one.
    try add(ports.dir, artwork.dir, celeste, "Celeste", "shortcut-art-2");
    try expectArtwork(artwork.dir, "shortcut-art-2");
    // Re-adding without a cached cover keeps that image and its record.
    try add(ports.dir, artwork.dir, celeste, "Celeste", null);
    try expectArtwork(artwork.dir, "shortcut-art-2");
    try remove(ports.dir, artwork.dir, "Celeste", celeste.product_id);
    try std.testing.expectError(error.FileNotFound, artwork.dir.access("Celeste.png", .{}));
}

test "artwork replaced after the shortcut saved it is kept" {
    var ports = std.testing.tmpDir(.{});
    defer ports.cleanup();
    var artwork = std.testing.tmpDir(.{});
    defer artwork.cleanup();

    try add(ports.dir, artwork.dir, celeste, "Celeste", "shortcut-art");
    // For example, a native Celeste port installed later writes its own image.
    try artwork.dir.writeFile(.{ .sub_path = "Celeste.png", .data = "native-port-art" });
    try add(ports.dir, artwork.dir, celeste, "Celeste", "shortcut-art-2");
    try expectArtwork(artwork.dir, "native-port-art");
    try remove(ports.dir, artwork.dir, "Celeste", celeste.product_id);
    try expectArtwork(artwork.dir, "native-port-art");
}

fn setMode(directory: std.fs.Dir, mode: std.posix.mode_t) !void {
    const path = try directory.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    try std.posix.fchmodat(std.fs.cwd().fd, path, mode, 0);
}

/// Records Celeste.png as add() left it just before saving the script.
const ArtworkObserver = struct {
    var directory: std.fs.Dir = undefined;
    var buffer: [32]u8 = undefined;
    var length: usize = 0;

    fn start(artwork: std.fs.Dir) void {
        directory = artwork;
        length = 0;
        after_artwork_write_for_tests = observe;
    }

    fn stop() void {
        after_artwork_write_for_tests = null;
    }

    fn observe() void {
        const data = directory.readFile("Celeste.png", &buffer) catch "";
        length = data.len;
    }

    fn seen() []const u8 {
        return buffer[0..length];
    }
};

fn skipAsRoot() !void {
    // Root ignores directory permissions, so a read-only folder cannot fail a write. Host
    // tests also run on macOS, where only the libc call is valid.
    const uid = if (builtin.os.tag == .linux) std.os.linux.geteuid() else std.c.geteuid();
    if (uid == 0) return error.SkipZigTest;
}

test "invalid input changes no artwork" {
    var ports = std.testing.tmpDir(.{});
    defer ports.cleanup();
    var artwork = std.testing.tmpDir(.{});
    defer artwork.cleanup();
    try add(ports.dir, artwork.dir, celeste, "Celeste", "shortcut-art-1");

    var invalid = celeste;
    invalid.launcher = "relative/GreenOvercast.sh";
    try std.testing.expectError(error.InvalidLauncher, add(ports.dir, artwork.dir, invalid, "Celeste", "shortcut-art-2"));
    try expectArtwork(artwork.dir, "shortcut-art-1");
}

test "a failed script save restores the artwork the shortcut owned" {
    try skipAsRoot();
    var ports = std.testing.tmpDir(.{});
    defer ports.cleanup();
    var artwork = std.testing.tmpDir(.{});
    defer artwork.cleanup();
    try add(ports.dir, artwork.dir, celeste, "Celeste", "shortcut-art-1");

    ArtworkObserver.start(artwork.dir);
    defer ArtworkObserver.stop();
    try setMode(ports.dir, 0o555);
    const result = add(ports.dir, artwork.dir, celeste, "Celeste", "shortcut-art-2");
    try setMode(ports.dir, 0o755);
    try std.testing.expectError(error.AccessDenied, result);

    // The new image really was written before the save failed, and was then restored.
    try std.testing.expectEqualStrings("shortcut-art-2", ArtworkObserver.seen());
    // The previous script and its record still describe the artwork on disk.
    try expectArtwork(artwork.dir, "shortcut-art-1");
    var script_buffer: [script_read_capacity]u8 = undefined;
    try std.testing.expectEqual(
        ArtworkRecord.of("shortcut-art-1"),
        recordedArtwork(try ports.dir.readFile("Celeste.sh", &script_buffer)).?,
    );
    try remove(ports.dir, artwork.dir, "Celeste", celeste.product_id);
    try std.testing.expectError(error.FileNotFound, artwork.dir.access("Celeste.png", .{}));
}

test "a failed script save removes artwork it just created" {
    try skipAsRoot();
    var ports = std.testing.tmpDir(.{});
    defer ports.cleanup();
    var artwork = std.testing.tmpDir(.{});
    defer artwork.cleanup();

    ArtworkObserver.start(artwork.dir);
    defer ArtworkObserver.stop();
    try setMode(ports.dir, 0o555);
    const result = add(ports.dir, artwork.dir, celeste, "Celeste", "shortcut-art");
    try setMode(ports.dir, 0o755);
    try std.testing.expectError(error.AccessDenied, result);
    // The image really was created before the save failed, and was then deleted.
    try std.testing.expectEqualStrings("shortcut-art", ArtworkObserver.seen());
    try std.testing.expectError(error.FileNotFound, artwork.dir.access("Celeste.png", .{}));
    try std.testing.expectEqual(State.absent, state(ports.dir, "Celeste.sh", celeste.product_id));
}

test "the script is kept while its artwork cannot be removed" {
    try skipAsRoot();
    var ports = std.testing.tmpDir(.{});
    defer ports.cleanup();
    var artwork = std.testing.tmpDir(.{});
    defer artwork.cleanup();
    try add(ports.dir, artwork.dir, celeste, "Celeste", "shortcut-art");

    try setMode(artwork.dir, 0o555);
    const result = remove(ports.dir, artwork.dir, "Celeste", celeste.product_id);
    try setMode(artwork.dir, 0o755);
    try std.testing.expectError(error.AccessDenied, result);
    // The record survives, so a later attempt still removes the image.
    try std.testing.expectEqual(State.shortcut, state(ports.dir, "Celeste.sh", celeste.product_id));
    try expectArtwork(artwork.dir, "shortcut-art");

    try remove(ports.dir, artwork.dir, "Celeste", celeste.product_id);
    try std.testing.expectError(error.FileNotFound, artwork.dir.access("Celeste.png", .{}));
    try std.testing.expectEqual(State.absent, state(ports.dir, "Celeste.sh", celeste.product_id));
}

test "port names that could imitate the artwork record are rejected" {
    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();
    const imitation = "GreenOvercast artwork: crc32=00000000 size=1";
    try std.testing.expectError(error.InvalidName, writeScript(output.writer(), celeste, imitation, null));
    try std.testing.expectError(error.InvalidName, writeScript(output.writer(), celeste, "N" ** (name_capacity + 1), null));
    try writeScript(output.writer(), celeste, "N" ** name_capacity, null);
}

test "new artwork never replaces a file created after the existence check" {
    var artwork = std.testing.tmpDir(.{});
    defer artwork.cleanup();
    // Another writer created the name between artworkExists() and the write.
    try artwork.dir.writeFile(.{ .sub_path = "Celeste.png", .data = "native-port-art" });
    try std.testing.expectError(error.PathAlreadyExists, writeNew(artwork.dir, "Celeste.png", "shortcut-art", 0o644));
    try expectArtwork(artwork.dir, "native-port-art");

    try writeNew(artwork.dir, "Fresh.png", "shortcut-art", 0o644);
    const stat = try artwork.dir.statFile("Fresh.png");
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o644), stat.mode & 0o777);
}

test "a shortcut for another title with the same port name is left alone" {
    var ports = std.testing.tmpDir(.{});
    defer ports.cleanup();
    const first = Shortcut{ .launcher = "/roms/ports/GreenOvercast.sh", .service = .geforce_now, .product_id = "title-a" };
    var second = first;
    second.product_id = "title-b";

    // "A/B" and "A:B" both become "A B".
    try add(ports.dir, null, first, "A B", null);
    try std.testing.expectEqual(State.foreign, state(ports.dir, "A B.sh", second.product_id));
    try std.testing.expectError(error.NameInUse, add(ports.dir, null, second, "A B", null));
    try std.testing.expectError(error.NotAShortcut, remove(ports.dir, null, "A B", second.product_id));
    try std.testing.expectEqual(State.shortcut, state(ports.dir, "A B.sh", first.product_id));
}

test "the longest accepted shortcut can still be recognised and removed" {
    var ports = std.testing.tmpDir(.{});
    defer ports.cleanup();
    var artwork = std.testing.tmpDir(.{});
    defer artwork.cleanup();
    const launcher = "/" ++ "p" ** (max_launcher_length - 1);
    const product_id = "x" ** (settings.product_id_capacity - 1);
    const name = "N" ** name_capacity;
    const longest = Shortcut{ .launcher = launcher, .service = .geforce_now, .product_id = product_id };

    // With artwork, so the ownership line is part of the longest script.
    try add(ports.dir, artwork.dir, longest, name, "png");
    try std.testing.expectEqual(State.shortcut, state(ports.dir, name ++ ".sh", product_id));
    try remove(ports.dir, artwork.dir, name, product_id);
    try std.testing.expectEqual(State.absent, state(ports.dir, name ++ ".sh", product_id));
    try std.testing.expectError(error.FileNotFound, artwork.dir.access(name ++ ".png", .{}));

    var too_long = longest;
    too_long.launcher = launcher ++ "p";
    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.InvalidLauncher, writeScript(output.writer(), too_long, "N", null));
}
