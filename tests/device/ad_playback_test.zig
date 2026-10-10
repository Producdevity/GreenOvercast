const std = @import("std");
const ads = @import("gfn_ads");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
});
const allocator = std.heap.c_allocator;

const inline_manifest =
    "<VAST><Ad><InLine><Impression>https://example.invalid/impression</Impression>" ++
    "<Error>https://example.invalid/error/[ERRORCODE]</Error><Creatives><Creative><Linear>" ++
    "<Duration>00:00:05</Duration><MediaFiles><MediaFile delivery=\"progressive\" type=\"video/mp4\" width=\"640\" height=\"360\">" ++
    "https://example.invalid/media</MediaFile></MediaFiles><TrackingEvents>" ++
    "<Tracking event=\"start\">https://example.invalid/start</Tracking>" ++
    "<Tracking event=\"firstQuartile\">https://example.invalid/quarter</Tracking>" ++
    "<Tracking event=\"midpoint\">https://example.invalid/half</Tracking>" ++
    "<Tracking event=\"thirdQuartile\">https://example.invalid/three-quarter</Tracking>" ++
    "<Tracking event=\"complete\">https://example.invalid/complete</Tracking>" ++
    "<Tracking event=\"pause\">https://example.invalid/pause</Tracking>" ++
    "<Tracking event=\"resume\">https://example.invalid/resume</Tracking>" ++
    "</TrackingEvents><Icons><Icon program=\"AdChoices\" width=\"30\" height=\"30\" xPosition=\"right\" yPosition=\"top\">" ++
    "<StaticResource creativeType=\"image/png\">https://example.invalid/icon</StaticResource>" ++
    "<IconViewTracking>https://example.invalid/icon-view</IconViewTracking><IconClicks>" ++
    "<IconClickTracking>https://example.invalid/icon-click</IconClickTracking><IconClickFallbackImages>" ++
    "<IconClickFallbackImage width=\"400\" height=\"150\"><StaticResource creativeType=\"image/png\">" ++
    "https://example.invalid/icon</StaticResource></IconClickFallbackImage></IconClickFallbackImages></IconClicks>" ++
    "</Icon></Icons></Linear></Creative></Creatives></InLine></Ad></VAST>";
const wrapper_manifest =
    "<VAST><Ad><Wrapper><Impression>https://example.invalid/wrapper-view</Impression>" ++
    "<Error>https://example.invalid/wrapper-error/[ERRORCODE]</Error>" ++
    "<VASTAdTagURI>https://example.invalid/inline</VASTAdTagURI></Wrapper></Ad></VAST>";
const pod_manifest = "<VAST>" ++
    "<Ad sequence=\"2\">" ++ inline_manifest[10 .. inline_manifest.len - 12] ++ "</Ad>" ++
    "<Ad sequence=\"1\">" ++ inline_manifest[10 .. inline_manifest.len - 12] ++ "</Ad></VAST>";

const Mode = enum { play, pause, cancel, broken, empty, truncated, video_tail, pod, wrapper_empty, wrapper_loop, wrapper_invalid };
const Recorded = struct { update: ads.protocol.Update, time_ms: u64 };
const Context = struct {
    media: []const u8,
    image: []const u8,
    mode: Mode,
    start: u64,
    paused: bool = false,
    resumed: bool = false,
    mutex: std.Thread.Mutex = .{},
    updates: std.ArrayList(Recorded),
    beacons: std.ArrayList([]u8),

    fn read(pointer: *anyopaque, storage: std.mem.Allocator, address: []const u8, _: usize, abort: *std.atomic.Value(bool)) ![]u8 {
        const self: *Context = @ptrCast(@alignCast(pointer));
        if (abort.load(.acquire)) return error.Cancelled;
        if (std.mem.indexOf(u8, address, "/tag?") != null) return storage.dupe(u8, if (self.mode == .empty) "<VAST/>" else if (self.mode == .pod) pod_manifest else wrapper_manifest);
        if (std.mem.endsWith(u8, address, "/inline")) return storage.dupe(u8, if (self.mode == .wrapper_empty) "<VAST/>" else if (self.mode == .wrapper_loop) wrapper_manifest else if (self.mode == .wrapper_invalid)
            "<VAST><Ad>"
        else
            inline_manifest);
        if (std.mem.endsWith(u8, address, "/media")) return storage.dupe(u8, if (self.mode == .broken) "not an MP4" else self.media);
        if (std.mem.endsWith(u8, address, "/icon")) return storage.dupe(u8, self.image);
        self.mutex.lock();
        defer self.mutex.unlock();
        const owned = try storage.dupe(u8, address);
        errdefer storage.free(owned);
        try self.beacons.append(owned);
        return storage.alloc(u8, 0);
    }

    fn report(pointer: *anyopaque, update: ads.protocol.Update) !void {
        const self: *Context = @ptrCast(@alignCast(pointer));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.updates.append(.{ .update = update, .time_ms = c.SDL_GetTicks64() - self.start });
    }

    fn count(self: *Context, suffix: []const u8) usize {
        var result: usize = 0;
        for (self.beacons.items) |address| if (std.mem.endsWith(u8, address, suffix)) {
            result += 1;
        };
        return result;
    }
};

export fn go_handheld_ui_cancel_requested(_: ?*anyopaque) c_int {
    return 0;
}
export fn go_handheld_ui_draw_loading(_: ?*anyopaque, _: [*:0]const u8, _: [*:0]const u8, _: c_int) void {}
export fn go_handheld_ui_draw_ad_hint(_: ?*anyopaque, _: c_int) void {}
export fn go_handheld_ui_ad_action(pointer: ?*anyopaque) c_int {
    const context: *Context = @ptrCast(@alignCast(pointer.?));
    const elapsed = c.SDL_GetTicks64() - context.start;
    if (elapsed > 20000 or (context.mode == .cancel and elapsed > 1000)) return -1;
    if (context.mode == .pause) {
        if (elapsed > 1400 and !context.paused) {
            context.paused = true;
            return 1;
        }
        if (elapsed > 2100 and !context.resumed) {
            context.resumed = true;
            return 2;
        }
    }
    return 0;
}

fn require(value: bool) !void {
    if (!value) return error.AssertionFailed;
}

fn readFixture(path: []const u8, limit: usize) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return file.reader().readAllAlloc(allocator, limit);
}

fn run(renderer: *c.SDL_Renderer, device: c.SDL_AudioDeviceID, media: []const u8, image: []const u8, mode: Mode) !void {
    var context = Context{ .media = media, .image = image, .mode = mode, .start = c.SDL_GetTicks64(), .updates = std.ArrayList(Recorded).init(allocator), .beacons = std.ArrayList([]u8).init(allocator) };
    defer {
        for (context.beacons.items) |address| allocator.free(address);
        context.beacons.deinit();
        context.updates.deinit();
    }
    var worker = ads.network.Worker{ .allocator = allocator, .reporter = .{ .context = &context, .send = Context.report }, .source = .{ .context = &context, .read = Context.read } };
    try worker.start();
    defer worker.deinit();
    var playback = ads.Playback{ .renderer = @ptrCast(renderer), .device = device, .ui = @ptrCast(&context), .provider = 1, .app_id = "1", .opportunity = .{ .id = "test-pod", .url = "https://example.invalid/tag", .state = 1, .duration_ms = 5000 } };
    const failure: ?anyerror = result: {
        playback.execute(&worker) catch |err| break :result err;
        break :result null;
    };
    worker.deinit();
    const success = mode == .play or mode == .pause or mode == .video_tail or mode == .pod;
    const no_fill = mode == .empty or mode == .wrapper_empty;
    try require(if (success or no_fill) failure == null else failure != null);
    if (mode == .truncated) try require(failure.? == error.AdMediaTruncated);
    if (mode == .wrapper_loop) try require(failure.? == error.VastWrapperLimit);
    if (mode == .wrapper_invalid) {
        try require(failure.? == error.InvalidXml);
        try require(context.count("/wrapper-error/100") == 1);
    }
    var starts: usize = 0;
    var finishes: usize = 0;
    var cancels: usize = 0;
    var milestones: usize = 0;
    for (context.updates.items) |record| switch (record.update.action) {
        .start => {
            starts += 1;
            try require(record.update.watched_ms == 0);
        },
        .finish => {
            finishes += 1;
            const duration: u64 = if (mode == .pod) 10000 else 5000;
            try require(record.time_ms >= duration - 100 and record.update.watched_ms >= duration - 100 and record.update.watched_ms <= duration + 100);
            if (mode == .pause) try require(record.update.paused_ms >= 500 and record.time_ms >= 5500);
        },
        .cancel => {
            cancels += 1;
            if (mode == .empty) try require(record.update.watched_ms == 0 and
                std.mem.eql(u8, record.update.reason.?, "VAST_EMPTY_RESPONSE"));
            if (mode == .wrapper_empty) try require(record.update.watched_ms == 0 and
                std.mem.eql(u8, record.update.reason.?, "VAST_NO_ADS_AFTER_WRAPPER"));
        },
        .event => {
            if (std.mem.eql(u8, record.update.event.?, "FIRST_QUARTILE") or
                std.mem.eql(u8, record.update.event.?, "MIDPOINT") or
                std.mem.eql(u8, record.update.event.?, "THIRD_QUARTILE")) milestones += 1;
        },
        else => {},
    };
    try require(finishes == @intFromBool(success) and cancels == @intFromBool(!success));
    if (success) {
        const ads_played: usize = if (mode == .pod) 2 else 1;
        try require(starts == 1 and milestones == 3 * ads_played);
        for ([_][]const u8{ "/impression", "/start", "/quarter", "/half", "/three-quarter", "/complete", "/icon-view" }) |suffix|
            try require(context.count(suffix) == ads_played);
        try require(context.count("/wrapper-view") == @intFromBool(mode != .pod));
        if (mode == .pause) for ([_][]const u8{ "/pause", "/resume", "/icon-click" }) |suffix| try require(context.count(suffix) == 1);
    } else try require(context.count("/complete") == 0);
    std.debug.print("PASS ad playback: {s}, watched={d}ms paused={d}ms reports={d} beacons={d}\n", .{ @tagName(mode), playback.watched_ms, playback.paused_ms, context.updates.items.len, context.beacons.items.len });
}

pub fn main() !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 5) return error.ExpectedMp4PngShortAndVideoTailFixtures;
    const media = try readFixture(args[1], 96 * 1024 * 1024);
    defer allocator.free(media);
    const image = try readFixture(args[2], 4 * 1024 * 1024);
    defer allocator.free(image);
    const short = try readFixture(args[3], 96 * 1024 * 1024);
    defer allocator.free(short);
    const tail = try readFixture(args[4], 96 * 1024 * 1024);
    defer allocator.free(tail);
    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO) != 0) return error.SdlUnavailable;
    defer c.SDL_Quit();
    const window = c.SDL_CreateWindow("Ad playback test", 0, 0, 640, 480, c.SDL_WINDOW_FULLSCREEN) orelse return error.WindowUnavailable;
    defer c.SDL_DestroyWindow(window);
    const renderer = c.SDL_CreateRenderer(window, -1, c.SDL_RENDERER_ACCELERATED) orelse
        c.SDL_CreateRenderer(window, -1, 0) orelse return error.RendererUnavailable;
    defer c.SDL_DestroyRenderer(renderer);
    _ = c.SDL_RenderSetLogicalSize(renderer, 640, 480);
    var spec = std.mem.zeroes(c.SDL_AudioSpec);
    spec.freq = 48000;
    spec.channels = 2;
    spec.format = c.AUDIO_S16SYS;
    spec.samples = 960;
    const device = c.SDL_OpenAudioDevice(null, 0, &spec, null, 0);
    if (device == 0) return error.AudioUnavailable;
    defer c.SDL_CloseAudioDevice(device);
    for ([_]Mode{ .play, .pause, .empty, .broken, .cancel, .truncated, .video_tail, .pod, .wrapper_empty, .wrapper_loop, .wrapper_invalid }) |mode|
        try run(renderer, device, if (mode == .truncated) short else if (mode == .video_tail) tail else media, image, mode);
}
