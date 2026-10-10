const std = @import("std");
const session = @import("session_client.zig");
pub const protocol = @import("ad_protocol.zig");
const vast = @import("vast.zig");
pub const network = @import("ad_network.zig");
const clip = @import("clip_player");
const policy = @import("ad_policy.zig");
const c = @cImport({
    @cInclude("handheld_ui.h");
    @cInclude("artwork_decoder.h");
});

const Metadata = struct {
    impressions: []const []const u8 = &.{},
    errors: []const []const u8 = &.{},
    tracks: []const vast.Track = &.{},
    icons: []const vast.Icon = &.{},
};
const Resolved = struct { creative: vast.Creative, metadata: Metadata };
const Parent = struct { metadata: Metadata, follow_wrappers: bool, allow_multiple: bool };
const IconTexture = struct { image: *c.SDL_Texture, fallback: *c.SDL_Texture, icon: vast.Icon, viewed: bool = false };

pub const Playback = struct {
    renderer: *c.SDL_Renderer,
    device: c.SDL_AudioDeviceID,
    ui: *c.GoHandheldUi,
    allocator: std.mem.Allocator = std.heap.c_allocator,
    client: *session.Client = undefined,
    opportunity: protocol.Opportunity = undefined,
    provider: u8 = 0,
    app_id: []const u8 = "",
    watched_ms: u64 = 0,
    paused_ms: u64 = 0,
    duration_ms: u64 = 0,

    pub fn handle(context: *anyopaque, client: *session.Client, opportunity: protocol.Opportunity, provider: u8) !void {
        const self: *Playback = @ptrCast(@alignCast(context));
        self.client = client;
        self.opportunity = opportunity;
        self.provider = provider;
        self.app_id = client.app_id orelse "";
        self.watched_ms = 0;
        self.paused_ms = 0;
        self.duration_ms = 0;
        var worker = network.Worker{ .allocator = self.allocator, .reporter = .{ .context = self, .send = report } };
        client.ad_stop = &worker.abort;
        defer client.ad_stop = null;
        try worker.start();
        defer worker.deinit();
        try self.execute(&worker);
    }

    pub fn execute(self: *Playback, worker: *network.Worker) !void {
        self.run(worker) catch |err| {
            worker.abort.store(true, .release);
            worker.deinit();
            worker.abort.store(false, .release);
            const no_fill = err == error.VastEmptyResponse or err == error.VastNoAdsAfterWrapper;
            const reason = if (err == error.VastEmptyResponse) "VAST_EMPTY_RESPONSE" else if (err == error.VastNoAdsAfterWrapper)
                "VAST_NO_ADS_AFTER_WRAPPER"
            else if (err == error.Cancelled) "USER_CANCELLED" else @errorName(err);
            try worker.reporter.send(worker.reporter.context, .{ .action = .cancel, .reason = reason, .watched_ms = self.watched_ms, .paused_ms = self.paused_ms, .duration_ms = self.duration_ms });
            std.debug.print("GeForce NOW ad: {s}, watched {d}ms\n", .{ reason, self.watched_ms });
            if (!no_fill) return err;
        };
    }

    fn report(context: *anyopaque, update: protocol.Update) !void {
        const self: *Playback = @ptrCast(@alignCast(context));
        try self.client.reportAd(self.opportunity.id, update);
    }

    fn fetch(self: *Playback, worker: *network.Worker, url: []const u8, limit: usize) ![]u8 {
        var task = network.Fetch{};
        try worker.fetch(url, limit, &task);
        var was_cancelled = false;
        while (!task.done.load(.acquire)) {
            if (c.go_handheld_ui_cancel_requested(self.ui) != 0) {
                worker.abort.store(true, .release);
                was_cancelled = true;
            }
            c.SDL_Delay(16);
        }
        if (was_cancelled) {
            if (task.result) |bytes| self.allocator.free(bytes);
            return error.Cancelled;
        }
        if (task.failure) |failure| return failure;
        return task.result orelse error.AdDownloadFailed;
    }

    fn drain(self: *Playback, worker: *network.Worker) !void {
        const started = c.SDL_GetTicks64();
        while (!try worker.idle()) {
            if (c.go_handheld_ui_cancel_requested(self.ui) != 0) return error.Cancelled;
            const elapsed = c.SDL_GetTicks64() - started;
            if (elapsed >= 10000 and try worker.reportsIdle()) {
                return;
            }
            if (elapsed >= 30000) return error.AdReportTimeout;
            c.SDL_Delay(16);
        }
    }

    fn run(self: *Playback, worker: *network.Worker) !void {
        c.go_handheld_ui_draw_loading(self.ui, "GEFORCE NOW", "LOADING ADVERTISEMENT", c.GO_HANDHELD_UI_ACTION_CANCEL);
        if (self.provider > 1) return error.UnsupportedAdProvider;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const storage = arena.allocator();
        var documents = std.ArrayList(vast.Manifest).init(self.allocator);
        defer {
            for (documents.items) |*document| document.deinit();
            documents.deinit();
        }
        var pod = std.ArrayList(Resolved).init(storage);
        if (self.provider == 1) {
            const target = try policy.tagUrl(storage, self.opportunity.url, self.app_id);
            try self.load(worker, &documents, &pod, storage, target, null, 0);
        } else {
            try vast.validateUrl(self.opportunity.url);
            try pod.append(.{ .metadata = .{}, .creative = .{ .duration_ms = self.opportunity.duration_ms, .media = try storage.dupe(vast.Media, &.{.{ .url = self.opportunity.url, .width = 640, .height = 360, .bitrate = 0 }}), .tracks = &.{}, .icons = &.{} } });
        }
        var length: u64 = 0;
        for (pod.items) |ad| length += ad.creative.duration_ms;
        if (length > 120000) return error.AdPodTooLong;
        self.duration_ms = length;
        for (pod.items, 0..) |ad, index| self.play(worker, ad, index == 0) catch |err| {
            if (err != error.Cancelled) for (ad.metadata.errors) |address| {
                try beacon(worker, storage, address, self.watched_ms, policy.errorCode(err));
            };
            try self.drain(worker);
            return err;
        };
        try self.event(worker, "ALL_ADS_COMPLETED");
        try worker.report(.{ .action = .finish, .watched_ms = self.watched_ms, .paused_ms = self.paused_ms, .duration_ms = self.duration_ms });
        try self.drain(worker);
        std.debug.print("GeForce NOW ad completed: watched {d}ms\n", .{self.watched_ms});
    }

    fn load(self: *Playback, worker: *network.Worker, documents: *std.ArrayList(vast.Manifest), pod: *std.ArrayList(Resolved), storage: std.mem.Allocator, url: []const u8, parent: ?Parent, depth: usize) !void {
        if (depth > 5 or documents.items.len == 32) {
            if (parent) |previous| for (previous.metadata.errors) |address| try beacon(worker, storage, address, 0, 302);
            try self.drain(worker);
            return error.VastWrapperLimit;
        }
        const bytes = self.fetch(worker, url, 1024 * 1024) catch |err| {
            if (err != error.Cancelled) try self.wrapperError(worker, storage, parent, policy.errorCode(err));
            return err;
        };
        defer self.allocator.free(bytes);
        var document = vast.parse(self.allocator, bytes) catch |err| {
            try self.wrapperError(worker, storage, parent, policy.errorCode(err));
            return err;
        };
        documents.append(document) catch |err| {
            document.deinit();
            return err;
        };
        if (document.ads.len == 0) {
            for (document.errors) |address| try beacon(worker, storage, address, 0, 303);
            if (parent) |previous| for (previous.metadata.errors) |address| try beacon(worker, storage, address, 0, 303);
            try self.drain(worker);
            return if (depth == 0) error.VastEmptyResponse else error.VastNoAdsAfterWrapper;
        }
        const count_before = pod.items.len;
        const candidates = try policy.selectAds(storage, document.ads, if (parent) |previous| previous.allow_multiple else true, if (parent) |previous| previous.follow_wrappers else true);
        var used_fallbacks = [_]bool{false} ** 16;
        for (candidates) |ad| {
            for (ad.verification_errors) |address| try worker.beacon(try policy.expand(storage, address, 0, 0, 2));
            const seed = if (parent) |previous| previous.metadata else Metadata{};
            const metadata = Metadata{ .impressions = try policy.merge([]const u8, storage, seed.impressions, ad.impressions), .errors = try policy.merge([]const u8, storage, seed.errors, ad.errors), .tracks = try policy.merge(vast.Track, storage, seed.tracks, ad.tracks), .icons = try policy.merge(vast.Icon, storage, seed.icons, ad.icons) };
            switch (ad.body) {
                .wrapper => |wrapper| self.load(worker, documents, pod, storage, wrapper.url, .{ .metadata = metadata, .follow_wrappers = wrapper.follow_wrappers, .allow_multiple = wrapper.allow_multiple }, depth + 1) catch |err| {
                    if (err != error.VastNoAdsAfterWrapper) return err;
                    if (wrapper.fallback_on_no_ad) {
                        for (document.ads, 0..) |fallback, index| {
                            if (used_fallbacks[index] or fallback.sequence != null or fallback.body != .inline_ad) continue;
                            for (fallback.verification_errors) |address| try worker.beacon(try policy.expand(storage, address, 0, 0, 2));
                            if (pod.items.len == 16) return error.AdPodTooLarge;
                            try pod.append(try resolveInline(storage, seed, fallback));
                            used_fallbacks[index] = true;
                            break;
                        }
                    }
                },
                .inline_ad => {
                    if (pod.items.len == 16) return error.AdPodTooLarge;
                    try pod.append(try resolveInline(storage, seed, ad));
                },
            }
        }
        if (pod.items.len == count_before) return error.VastNoAdsAfterWrapper;
    }

    fn wrapperError(self: *Playback, worker: *network.Worker, storage: std.mem.Allocator, parent: ?Parent, code: u16) !void {
        if (parent) |previous| {
            for (previous.metadata.errors) |address| try beacon(worker, storage, address, 0, code);
            try self.drain(worker);
        }
    }

    fn play(self: *Playback, worker: *network.Worker, ad: Resolved, first: bool) !void {
        var icons = std.ArrayList(IconTexture).init(self.allocator);
        defer {
            for (icons.items) |icon| {
                c.SDL_DestroyTexture(icon.image);
                c.SDL_DestroyTexture(icon.fallback);
            }
            icons.deinit();
        }
        for (ad.metadata.icons) |icon| {
            const fallback_url = icon.fallback orelse return error.UnsupportedAdChoices;
            const image = try self.loadTexture(worker, icon.image);
            errdefer c.SDL_DestroyTexture(image);
            const fallback = try self.loadTexture(worker, fallback_url);
            errdefer c.SDL_DestroyTexture(fallback);
            try icons.append(.{ .image = image, .fallback = fallback, .icon = icon });
        }
        const media = policy.selectMedia(ad.creative.media) orelse return error.UnsupportedMedia;
        const bytes = try self.fetch(worker, media.url, 96 * 1024 * 1024);
        defer self.allocator.free(bytes);
        var player = clip.Player{ .bytes = bytes, .device = self.device, .renderer = @ptrCast(self.renderer) };
        defer player.deinit();
        try player.start();
        try self.event(worker, "LOADED");
        const fired = try self.allocator.alloc(bool, ad.metadata.tracks.len);
        defer self.allocator.free(fired);
        @memset(fired, false);
        const prior = self.watched_ms;
        const prior_paused = self.paused_ms;
        var started = false;
        var modal = false;
        var selected: usize = 0;
        var last_progress = c.SDL_GetTicks64();
        var last_position: u64 = 0;
        var quartiles = [_]bool{false} ** 3;
        const started_at = last_progress;
        while (true) {
            const action = c.go_handheld_ui_ad_action(self.ui);
            if (action < 0 or (action == 2 and !modal)) return error.Cancelled;
            if (action == 2 and modal) {
                modal = false;
                player.pause(false);
                last_progress = c.SDL_GetTicks64();
                self.paused_ms = prior_paused + player.paused_ms;
                for (ad.metadata.tracks) |track| if (std.mem.eql(u8, track.event, "resume"))
                    try beacon(worker, self.allocator, track.url, last_position, 0);
                try worker.report(.{ .action = .resume_playback, .watched_ms = self.watched_ms, .paused_ms = self.paused_ms, .duration_ms = self.duration_ms });
            }
            const progress = try player.tick();
            self.watched_ms = prior + progress.played_ms;
            self.paused_ms = prior_paused + player.paused_ms + if (player.paused_at) |paused| c.SDL_GetTicks64() - paused else 0;
            if (progress.finished and progress.played_ms + 250 < ad.creative.duration_ms) return error.AdMediaTruncated;
            if (progress.played_ms > last_position) {
                last_progress = c.SDL_GetTicks64();
                last_position = progress.played_ms;
            }
            if ((!modal and c.SDL_GetTicks64() - last_progress > 10000) or c.SDL_GetTicks64() - started_at > 180000)
                return error.AdPlaybackStalled;
            if (progress.rendered_frames > 0) {
                try player.draw();
                const size = try clip.canvasSize(@ptrCast(self.renderer));
                if (icons.items.len > 0) {
                    if (action == 3 and !modal) selected = (selected + icons.items.len - 1) % icons.items.len;
                    if (action == 4 and !modal) selected = (selected + 1) % icons.items.len;
                }
                for (icons.items, 0..) |*icon, index| {
                    if (!policy.iconVisible(icon.icon, progress.played_ms)) continue;
                    const rect = c.SDL_Rect{ .x = policy.iconPosition(icon.icon.x, size.width, icon.icon.width), .y = policy.iconPosition(icon.icon.y, size.height, icon.icon.height), .w = icon.icon.width, .h = icon.icon.height };
                    if (c.SDL_RenderCopy(self.renderer, icon.image, null, &rect) != 0) return error.AdIconRenderFailed;
                    if (index == selected and icons.items.len > 1 and !modal) {
                        const outline = c.SDL_Rect{ .x = rect.x - 1, .y = rect.y - 1, .w = rect.w + 2, .h = rect.h + 2 };
                        _ = c.SDL_SetRenderDrawColor(self.renderer, 255, 255, 255, 255);
                        if (c.SDL_RenderDrawRect(self.renderer, &outline) != 0) return error.AdIconRenderFailed;
                    }
                    if (action == 1 and index == selected and !modal and started) {
                        modal = true;
                        player.pause(true);
                        for (ad.metadata.tracks) |track| if (std.mem.eql(u8, track.event, "pause"))
                            try beacon(worker, self.allocator, track.url, progress.played_ms, 0);
                        for (icon.icon.clicks) |url| try beacon(worker, self.allocator, url, progress.played_ms, 0);
                        try worker.report(.{ .action = .pause, .watched_ms = self.watched_ms, .paused_ms = self.paused_ms, .duration_ms = self.duration_ms });
                    }
                }
                if (icons.items.len > 0) {
                    if (modal) {
                        _ = c.SDL_SetRenderDrawColor(self.renderer, 0, 0, 0, 255);
                        _ = c.SDL_RenderClear(self.renderer);
                        const icon = icons.items[selected];
                        const rect = c.SDL_Rect{ .x = @divTrunc(size.width - @as(c_int, icon.icon.fallback_width), 2), .y = @divTrunc(size.height - 40 - @as(c_int, icon.icon.fallback_height), 2), .w = icon.icon.fallback_width, .h = icon.icon.fallback_height };
                        if (c.SDL_RenderCopy(self.renderer, icon.fallback, null, &rect) != 0) return error.AdIconRenderFailed;
                    }
                    var hint_unobscured = player.texture_height * 640 <= player.texture_width * 400;
                    for (icons.items) |icon| {
                        const y = policy.iconPosition(icon.icon.y, size.height, icon.icon.height);
                        if (policy.iconVisible(icon.icon, progress.played_ms) and y < 465 and y + icon.icon.height > 435)
                            hint_unobscured = false;
                    }
                    if (modal or hint_unobscured) c.go_handheld_ui_draw_ad_hint(self.ui, @intFromBool(modal));
                }
                c.SDL_RenderPresent(self.renderer);
                if (!modal) {
                    if (!started) {
                        started = true;
                        if (first) try worker.report(.{ .action = .start, .duration_ms = self.duration_ms });
                        for (ad.metadata.impressions) |url| try beacon(worker, self.allocator, url, progress.played_ms, 0);
                        try self.event(worker, "STARTED");
                        try self.event(worker, "IMPRESSION");
                    }
                    for (icons.items) |*icon| {
                        if (!icon.viewed and policy.iconVisible(icon.icon, progress.played_ms)) {
                            for (icon.icon.views) |url| try beacon(worker, self.allocator, url, progress.played_ms, 0);
                            icon.viewed = true;
                        }
                    }
                    for (ad.metadata.tracks, fired) |track, *sent| {
                        if (sent.* or !policy.due(track, progress.played_ms, ad.creative.duration_ms, progress.finished)) continue;
                        try beacon(worker, self.allocator, track.url, progress.played_ms, 0);
                        sent.* = true;
                    }
                    for (&quartiles, 0..) |*sent, index| {
                        if (sent.* or ad.creative.duration_ms == 0 or progress.played_ms < ad.creative.duration_ms * (index + 1) / 4) continue;
                        try self.event(worker, ([_][]const u8{ "FIRST_QUARTILE", "MIDPOINT", "THIRD_QUARTILE" })[index]);
                        sent.* = true;
                    }
                }
            }
            if (progress.finished and !modal) break;
            _ = try worker.idle();
            c.SDL_Delay(4);
        }
        try self.event(worker, "COMPLETE");
    }

    fn event(self: *Playback, worker: *network.Worker, name: []const u8) !void {
        if (self.provider == 1) try worker.report(.{ .action = .event, .event = name, .watched_ms = self.watched_ms, .paused_ms = self.paused_ms, .duration_ms = self.duration_ms });
    }
    fn loadTexture(self: *Playback, worker: *network.Worker, url: []const u8) !*c.SDL_Texture {
        const bytes = try self.fetch(worker, url, 4 * 1024 * 1024);
        defer self.allocator.free(bytes);
        var image = std.mem.zeroes(c.GoArtworkImage);
        if (c.go_artwork_decode_rgba(bytes.ptr, bytes.len, 640, 480, &image) != 0) return error.InvalidAdIcon;
        defer c.go_artwork_image_destroy(&image);
        const texture = c.SDL_CreateTexture(self.renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, image.width, image.height) orelse return error.AdIconTextureUnavailable;
        errdefer c.SDL_DestroyTexture(texture);
        if (c.SDL_UpdateTexture(texture, null, image.pixels, image.stride) != 0 or
            c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_BLEND) != 0) return error.AdIconTextureUnavailable;
        return texture;
    }
};

fn resolveInline(storage: std.mem.Allocator, seed: Metadata, ad: vast.Ad) !Resolved {
    const creative = ad.body.inline_ad;
    const metadata = Metadata{
        .impressions = try policy.merge([]const u8, storage, seed.impressions, ad.impressions),
        .errors = try policy.merge([]const u8, storage, seed.errors, ad.errors),
        .tracks = try policy.merge(vast.Track, storage, seed.tracks, creative.tracks),
        .icons = try policy.merge(vast.Icon, storage, seed.icons, creative.icons),
    };
    if (metadata.icons.len > 8 or metadata.impressions.len > 128) return error.VastLimitExceeded;
    return .{ .creative = creative, .metadata = metadata };
}

fn beacon(worker: *network.Worker, allocator: std.mem.Allocator, url: []const u8, played: u64, error_code: u16) !void {
    const address = try policy.expand(allocator, url, played, error_code, 0);
    defer allocator.free(address);
    try worker.beacon(address);
}
