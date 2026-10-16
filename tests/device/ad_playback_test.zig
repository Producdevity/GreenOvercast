const std = @import("std");
const ads = @import("gfn_ads");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
});
const allocator = std.heap.c_allocator;

const inline_manifest =
    "<VAST><Ad><InLine><Impression>https://example.invalid/impression</Impression>" ++
    "<Error>https://example.invalid/error/[ERRORCODE]?at=[ADPLAYHEAD]</Error><Creatives><Creative><Linear>" ++
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
const media_url = "https://example.invalid/media";
const media_offset = std.mem.indexOf(u8, inline_manifest, media_url).?;
const pod_manifest = "<VAST><Ad sequence=\"2\">" ++
    inline_manifest[10..media_offset] ++ media_url ++ "-2" ++ inline_manifest[media_offset + media_url.len .. inline_manifest.len - 12] ++
    "</Ad><Ad sequence=\"1\">" ++
    inline_manifest[10..media_offset] ++ media_url ++ "-1" ++ inline_manifest[media_offset + media_url.len .. inline_manifest.len - 12] ++ "</Ad></VAST>";

const Mode = enum { play, pause, large_fallback, slow_pause, audio_running, macros, tracker_failure, cancel, broken, error_tracker_failure, error_report_failure, cancel_report_failure, empty, empty_report_failure, truncated, video_tail, pod, pod_truncated, pod_download_failure, wrapper_empty, wrapper_loop, wrapper_invalid };
const Recorded = struct { update: ads.protocol.Update, time_ms: u64 };
const Context = struct {
    media: []const u8,
    image: []const u8,
    fallback_image: []const u8 = "",
    short_media: []const u8,
    mode: Mode,
    start: u64,
    timeout_ms: u64 = 20000,
    paused: bool = false,
    resumed: bool = false,
    playback_started_at: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pause_accepted_at: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    media_reads: usize = 0,
    media_order: [2]u8 = .{ 0, 0 },
    error_beacon_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: std.Thread.Mutex = .{},
    updates: std.ArrayList(Recorded),
    beacons: std.ArrayList([]u8),

    fn read(pointer: *anyopaque, storage: std.mem.Allocator, address: []const u8, _: usize, abort: *std.atomic.Value(bool)) ![]u8 {
        const self: *Context = @ptrCast(@alignCast(pointer));
        if (abort.load(.acquire)) return error.Cancelled;
        if (std.mem.indexOf(u8, address, "/tag?") != null) return storage.dupe(u8, if (self.mode == .empty or self.mode == .empty_report_failure) "<VAST/>" else if (self.mode == .pod or self.mode == .pod_truncated or self.mode == .pod_download_failure) pod_manifest else wrapper_manifest);
        if (std.mem.endsWith(u8, address, "/inline")) {
            if (self.mode == .macros) return std.mem.replaceOwned(u8, storage, inline_manifest, "/impression", "/impression?asset=[ASSETURI]&amp;custom=[VENDOR_TOKEN]");
            if (self.mode == .large_fallback) return std.mem.replaceOwned(u8, storage, inline_manifest, "<IconClickFallbackImage width=\"400\" height=\"150\"><StaticResource creativeType=\"image/png\">https://example.invalid/icon", "<IconClickFallbackImage width=\"1920\" height=\"1080\"><StaticResource creativeType=\"image/png\">https://example.invalid/panel");
            if (self.mode == .error_tracker_failure) {
                var oversized: [8192]u8 = @splat('x');
                const prefix = "https://example.invalid/";
                @memcpy(oversized[0..prefix.len], prefix);
                const macro = "[ADPLAYHEAD]";
                @memcpy(oversized[oversized.len - macro.len ..], macro);
                const error_at = std.mem.indexOf(u8, inline_manifest, "<Error>").?;
                return std.fmt.allocPrint(storage, "{s}<Error>{s}</Error>{s}", .{ inline_manifest[0..error_at], oversized, inline_manifest[error_at..] });
            }
            return storage.dupe(u8, if (self.mode == .wrapper_empty) "<VAST/>" else if (self.mode == .wrapper_loop) wrapper_manifest else if (self.mode == .wrapper_invalid) "<VAST><Ad>" else inline_manifest);
        }
        if (std.mem.endsWith(u8, address, "/media") or std.mem.endsWith(u8, address, "/media-1") or std.mem.endsWith(u8, address, "/media-2")) {
            if (self.media_reads < self.media_order.len) self.media_order[self.media_reads] = if (std.mem.endsWith(u8, address, "-1")) 1 else if (std.mem.endsWith(u8, address, "-2")) 2 else 0;
            self.media_reads += 1;
            if (self.mode == .slow_pause) c.SDL_Delay(1600);
            if (self.mode == .pod_download_failure and self.media_reads == 2) return error.AdDownloadFailed;
            return storage.dupe(u8, if (self.mode == .broken or self.mode == .error_tracker_failure or self.mode == .error_report_failure or self.mode == .cancel_report_failure) "not an MP4" else if (self.mode == .pod_truncated and self.media_reads == 2) self.short_media else self.media);
        }
        if (std.mem.endsWith(u8, address, "/icon")) return storage.dupe(u8, self.image);
        if (std.mem.endsWith(u8, address, "/panel")) return storage.dupe(u8, self.fallback_image);
        if (self.mode == .error_report_failure) self.error_beacon_started.store(true, .release);
        self.mutex.lock();
        defer self.mutex.unlock();
        const owned = try storage.dupe(u8, address);
        self.beacons.append(owned) catch |err| {
            storage.free(owned);
            return err;
        };
        if (self.mode == .tracker_failure) return error.AdDownloadFailed;
        return storage.alloc(u8, 0);
    }

    fn report(pointer: *anyopaque, update: ads.protocol.Update) !void {
        const self: *Context = @ptrCast(@alignCast(pointer));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.updates.append(.{ .update = update, .time_ms = c.SDL_GetTicks64() - self.start });
        if (update.action == .start) self.playback_started_at.store(c.SDL_GetTicks64(), .release);
        if (update.action == .pause) self.pause_accepted_at.store(c.SDL_GetTicks64(), .release);
        if (self.mode == .error_report_failure and update.action == .event) {
            const until = c.SDL_GetTicks64() + 2000;
            while (!self.error_beacon_started.load(.acquire) and c.SDL_GetTicks64() < until) c.SDL_Delay(1);
            return error.AdReportRejected;
        }
        if ((self.mode == .cancel_report_failure or self.mode == .empty_report_failure) and update.action == .cancel) return error.AdReportRejected;
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
    if (elapsed > context.timeout_ms or (context.mode == .cancel and elapsed > 1000)) return -1;
    if (context.mode == .pause or context.mode == .large_fallback or context.mode == .slow_pause) {
        const started = context.playback_started_at.load(.acquire);
        const accepted = context.pause_accepted_at.load(.acquire);
        if (started != 0 and c.SDL_GetTicks64() - started > 500 and !context.paused) {
            context.paused = true;
            return 1;
        }
        if (accepted != 0 and c.SDL_GetTicks64() - accepted > 700 and !context.resumed) {
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

fn run(renderer: *c.SDL_Renderer, device: c.SDL_AudioDeviceID, media: []const u8, short: []const u8, image: []const u8, fallback_image: []const u8, mode: Mode) !void {
    c.SDL_PauseAudioDevice(device, @intFromBool(mode != .audio_running));
    const previous_audio_status = c.SDL_GetAudioDeviceStatus(device);
    var context = Context{ .media = media, .short_media = short, .image = image, .fallback_image = fallback_image, .mode = mode, .start = c.SDL_GetTicks64(), .updates = std.ArrayList(Recorded).init(allocator), .beacons = std.ArrayList([]u8).init(allocator) };
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
    try require(c.SDL_GetAudioDeviceStatus(device) == previous_audio_status);
    const success = mode == .play or mode == .pause or mode == .large_fallback or mode == .slow_pause or mode == .audio_running or mode == .macros or mode == .tracker_failure or mode == .video_tail or mode == .pod;
    const no_fill = mode == .empty or mode == .wrapper_empty;
    try require(if (success or no_fill) failure == null else failure != null);
    if (mode == .truncated) try require(failure.? == error.AdMediaTruncated);
    if (mode == .broken or mode == .error_tracker_failure or mode == .error_report_failure or mode == .cancel_report_failure) try require(failure.? == error.InvalidMp4);
    if (mode == .empty_report_failure) try require(failure.? == error.AdReportRejected);
    if (mode == .error_tracker_failure) try require(context.count("/error/405?at=00%3A00%3A00.000") == 1);
    if (mode == .pod or mode == .pod_truncated or mode == .pod_download_failure) try require(std.mem.eql(u8, &context.media_order, &.{ 1, 2 }));
    if (mode == .pod_truncated) {
        var first_end: ?u64 = null;
        for (context.updates.items) |record| {
            if (record.update.action == .event and std.mem.eql(u8, record.update.event.?, "COMPLETE")) {
                first_end = record.update.watched_ms;
                break;
            }
        }
        try require(failure.? == error.AdMediaTruncated and first_end != null);
        const local = playback.watched_ms - first_end.?;
        try require(local >= 3098 and local <= 3100);
        var buffer: [64]u8 = undefined;
        const suffix = try std.fmt.bufPrint(&buffer, "/error/405?at=00%3A00%3A03.{d:0>3}", .{local % 1000});
        try require(context.count(suffix) == 1);
    }
    if (mode == .pod_download_failure) {
        try require(failure.? == error.AdDownloadFailed and playback.watched_ms >= 4998 and playback.watched_ms <= 5000);
        try require(context.count("/error/401?at=00%3A00%3A00.000") == 1);
    }
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
            if (mode == .pause or mode == .large_fallback or mode == .slow_pause) try require(record.update.paused_ms >= 700 and record.time_ms >= 5700);
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
        for ([_][]const u8{ "/impression", "/start", "/quarter", "/half", "/three-quarter", "/complete", "/icon-view" }) |suffix| {
            const expected = if (mode == .macros and std.mem.eql(u8, suffix, "/impression")) "/impression?asset=-1&custom=[VENDOR_TOKEN]" else suffix;
            try require(context.count(expected) == ads_played);
        }
        try require(context.count("/wrapper-view") == @intFromBool(mode != .pod));
        if (mode == .pause or mode == .large_fallback or mode == .slow_pause) for ([_][]const u8{ "/pause", "/resume", "/icon-click" }) |suffix| try require(context.count(suffix) == 1);
    } else try require(context.count("/complete") == @intFromBool(mode == .pod_truncated or mode == .pod_download_failure));
    std.debug.print("PASS ad playback: {s}, watched={d}ms paused={d}ms reports={d} beacons={d}\n", .{ @tagName(mode), playback.watched_ms, playback.paused_ms, context.updates.items.len, context.beacons.items.len });
}

pub fn main() !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const live = args.len == 3 and std.mem.eql(u8, args[1], "--live-ad");
    if (!live and args.len != 6) return error.ExpectedMp4PngShortVideoTailAndFallbackFixtures;
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
    if (live) return runLive(renderer, device, args[2]);
    const media = try readFixture(args[1], 96 * 1024 * 1024);
    defer allocator.free(media);
    const image = try readFixture(args[2], 4 * 1024 * 1024);
    defer allocator.free(image);
    const short = try readFixture(args[3], 96 * 1024 * 1024);
    defer allocator.free(short);
    const tail = try readFixture(args[4], 96 * 1024 * 1024);
    defer allocator.free(tail);
    const fallback_image = try readFixture(args[5], 4 * 1024 * 1024);
    defer allocator.free(fallback_image);
    for (std.enums.values(Mode)) |mode|
        try run(renderer, device, if (mode == .truncated) short else if (mode == .video_tail) tail else media, short, image, fallback_image, mode);
}

fn runLive(renderer: *c.SDL_Renderer, device: c.SDL_AudioDeviceID, address: []const u8) !void {
    var context = Context{ .media = "", .short_media = "", .image = "", .mode = .pause, .start = c.SDL_GetTicks64(), .timeout_ms = 180000, .updates = std.ArrayList(Recorded).init(allocator), .beacons = std.ArrayList([]u8).init(allocator) };
    defer context.updates.deinit();
    defer context.beacons.deinit();
    var worker = ads.network.Worker{ .allocator = allocator, .reporter = .{ .context = &context, .send = Context.report } };
    try worker.start();
    defer worker.deinit();
    var playback = ads.Playback{ .renderer = @ptrCast(renderer), .device = device, .ui = @ptrCast(&context), .provider = 1, .app_id = "1", .opportunity = .{ .id = "live-component-test", .url = address, .state = 1, .duration_ms = 0 } };
    std.debug.print("Live ad component test: real network/media/tracking; no NVIDIA account attached\n", .{});
    try playback.execute(&worker);
    const until = c.SDL_GetTicks64() + 30000;
    while (!try worker.idle() and c.SDL_GetTicks64() < until) c.SDL_Delay(16);
    try require(try worker.idle());
    try require(worker.beacon_failures == 0 and playback.watched_ms > 0);
    var starts: usize = 0;
    var finishes: usize = 0;
    for (context.updates.items) |record| {
        if (record.update.action == .start) starts += 1;
        if (record.update.action == .finish) finishes += 1;
        try require(record.update.action != .cancel);
    }
    try require(starts == 1 and finishes == 1);
    if (context.pause_accepted_at.load(.acquire) != 0) try require(context.resumed and playback.paused_ms >= 700);
    std.debug.print("PASS live ad: watched={d}ms paused={d}ms reports={d}, no failed tracking requests\n", .{ playback.watched_ms, playback.paused_ms, context.updates.items.len });
}
