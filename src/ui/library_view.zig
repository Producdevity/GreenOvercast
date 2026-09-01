const std = @import("std");
const controls = @import("control_icons.zig");
const search = @import("catalog_search");
const font = @import("pixel_font.zig");
const settings = @import("persistent_settings.zig");
const style = @import("view_style.zig");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("catalog_parser.h");
});

pub const query_capacity = 32;

pub const Title = c.GoCatalogTitle;

pub const Collection = enum {
    all,
    favorites,
};

pub const View = struct {
    titles: []const Title,
    indices: []usize,
    count: usize = 0,
    selected: usize = 0,
    collection: Collection = .all,
    query: [query_capacity]u8 = [_]u8{0} ** query_capacity,

    pub fn rebuild(self: *View, store: *const settings.Store, preserve_title_index: ?usize) void {
        self.count = 0;
        self.selected = 0;
        for (self.titles, 0..) |*title, index| {
            if (self.collection == .favorites and !isFavorite(store, title)) continue;
            if (!search.matches(titleName(title), std.mem.sliceTo(&self.query, 0))) continue;
            if (preserve_title_index != null and index == preserve_title_index.?)
                self.selected = self.count;
            self.indices[self.count] = index;
            self.count += 1;
        }
        if (self.count > 0) self.selected = @min(self.selected, self.count - 1);
    }

    pub fn selectedTitleIndex(self: *const View) ?usize {
        if (self.count == 0) return null;
        return self.indices[self.selected];
    }

    pub fn selectedTitle(self: *const View) ?*const Title {
        return if (self.selectedTitleIndex()) |index| &self.titles[index] else null;
    }

    pub fn move(self: *View, direction: i8) void {
        if (self.count == 0) return;
        if (direction < 0)
            self.selected = if (self.selected == 0) self.count - 1 else self.selected - 1
        else
            self.selected = if (self.selected + 1 == self.count) 0 else self.selected + 1;
    }

    pub fn switchCollection(self: *View, store: *const settings.Store, direction: i8) void {
        const preserve = self.selectedTitleIndex();
        self.collection = if (direction < 0)
            (if (self.collection == .all) .favorites else .all)
        else
            (if (self.collection == .favorites) .all else .favorites);
        self.rebuild(store, preserve);
    }

    pub fn jumpInitial(self: *View, direction: i8) void {
        if (self.count == 0) return;
        const current = titleInitial(self.selectedTitle().?);
        if (direction > 0) {
            var index = self.selected + 1;
            while (index < self.count) : (index += 1) {
                if (titleInitial(&self.titles[self.indices[index]]) != current) {
                    self.selected = index;
                    return;
                }
            }
            self.selected = 0;
            return;
        }
        var start = self.selected;
        while (start > 0 and titleInitial(&self.titles[self.indices[start - 1]]) == current)
            start -= 1;
        var previous = if (start > 0) start - 1 else self.count - 1;
        const target = titleInitial(&self.titles[self.indices[previous]]);
        while (previous > 0 and titleInitial(&self.titles[self.indices[previous - 1]]) == target)
            previous -= 1;
        self.selected = previous;
    }
};

pub fn titleName(title: *const Title) []const u8 {
    const name = bufferString(&title.name);
    return if (name.len > 0) name else bufferString(&title.title_id);
}

pub fn titleNamePointer(title: *const Title) [*c]const u8 {
    return if (title.name[0] != 0) @ptrCast(&title.name) else @ptrCast(&title.title_id);
}

pub fn productId(title: *const Title) []const u8 {
    return bufferString(&title.product_id);
}

pub fn artworkUrl(title: *const Title) []const u8 {
    return bufferString(&title.artwork_url);
}

pub fn requestedTitle(titles: []const Title, requested: []const u8) usize {
    for (titles, 0..) |*title, index| {
        if (std.mem.eql(u8, bufferString(&title.title_id), requested) or
            std.mem.eql(u8, productId(title), requested)) return index;
    }
    return 0;
}

pub fn matchingCount(
    titles: []const Title,
    store: *const settings.Store,
    collection: Collection,
    query: [*:0]const u8,
) usize {
    var count: usize = 0;
    for (titles) |*title| {
        if (collection == .favorites and !isFavorite(store, title)) continue;
        if (search.matches(titleName(title), std.mem.span(query))) count += 1;
    }
    return count;
}

pub fn draw(
    renderer_pointer: *anyopaque,
    view: *const View,
    store: *const settings.Store,
    artwork_pointer: ?*anyopaque,
) void {
    const renderer: *c.SDL_Renderer = @ptrCast(@alignCast(renderer_pointer));
    const artwork: ?*c.SDL_Texture = if (artwork_pointer) |value| @ptrCast(@alignCast(value)) else null;
    style.setColor(renderer, style.background());
    _ = c.SDL_RenderClear(renderer);
    style.setColor(renderer, style.panel());
    var header = c.SDL_Rect{ .x = 0, .y = 0, .w = style.display_width, .h = 78 };
    var footer = c.SDL_Rect{ .x = 0, .y = 424, .w = style.display_width, .h = 56 };
    _ = c.SDL_RenderFillRect(renderer, &header);
    _ = c.SDL_RenderFillRect(renderer, &footer);
    style.drawMark(renderer);
    font.text(renderer, 78, 12, 4, "GREENOVERCAST", style.bright());

    drawTabs(renderer, view.collection);
    if (view.count == 0) {
        const empty = if (view.collection == .favorites) "NO FAVORITES YET" else "NO MATCHING GAMES";
        font.text(renderer, 28, 206, 3, empty, style.muted());
        const primary = [_]controls.Prompt{
            controls.Prompt.two(.left_bumper, .right_bumper, "TAB"),
            controls.Prompt.one(controls.face(store.face_buttons, .x), "SEARCH"),
            controls.Prompt.one(.start, "SETTINGS"),
        };
        const secondary = [_]controls.Prompt{
            controls.Prompt.one(controls.face(store.face_buttons, .b), "BACK"),
        };
        controls.drawRow(renderer, 16, 431, &primary, style.bright());
        controls.drawRow(renderer, 16, 455, &secondary, style.accent());
        c.SDL_RenderPresent(renderer);
        return;
    }

    const show_artwork = store.artwork_enabled and artworkUrl(view.selectedTitle().?).len > 0;
    const list_right: c_int = if (show_artwork) 386 else 626;
    const visible_rows: usize = 9;
    var start = view.selected -| visible_rows / 2;
    start = @min(start, view.count -| visible_rows);
    var row: usize = 0;
    while (row < visible_rows) : (row += 1) {
        const index = start + row;
        if (index >= view.count) break;
        const title = &view.titles[view.indices[index]];
        const y: c_int = @intCast(86 + row * 36);
        if (index == view.selected) {
            style.setColor(renderer, style.selection());
            var selection = c.SDL_Rect{ .x = 14, .y = y, .w = list_right - 14, .h = 32 };
            _ = c.SDL_RenderFillRect(renderer, &selection);
            style.setColor(renderer, style.accent());
            var rain_bar = c.SDL_Rect{ .x = 14, .y = y, .w = 5, .h = 32 };
            _ = c.SDL_RenderFillRect(renderer, &rain_bar);
        }
        const favorite = isFavorite(store, title);
        if (favorite) drawFavoriteMarker(renderer, 28, y + 10);
        font.textEllipsized(
            renderer,
            50,
            y + 5,
            3,
            titleNamePointer(title),
            list_right - 62,
            if (index == view.selected) style.bright() else style.muted(),
        );
    }

    if (show_artwork) {
        if (artwork) |texture|
            drawArtwork(renderer, texture)
        else
            font.text(renderer, 452, 218, 2, "LOADING ART", style.muted());
    }
    const primary = [_]controls.Prompt{
        controls.Prompt.one(controls.face(store.face_buttons, .a), "PLAY"),
        controls.Prompt.one(controls.face(store.face_buttons, .y), "FAVORITE"),
        controls.Prompt.one(controls.face(store.face_buttons, .x), "SEARCH"),
        controls.Prompt.one(controls.face(store.face_buttons, .b), "BACK"),
    };
    const secondary = [_]controls.Prompt{
        controls.Prompt.two(.left_bumper, .right_bumper, "TAB"),
        controls.Prompt.two(.left_trigger, .right_trigger, "LETTER"),
        controls.Prompt.one(.start, "SETTINGS"),
    };
    controls.drawRow(renderer, 16, 431, &primary, style.bright());
    controls.drawRow(renderer, 16, 455, &secondary, style.accent());
    c.SDL_RenderPresent(renderer);
}

fn drawTabs(renderer: *c.SDL_Renderer, active: Collection) void {
    const labels = [_]struct { Collection, [*:0]const u8, c_int }{
        .{ .all, "ALL", 210 },
        .{ .favorites, "FAVORITES", 300 },
    };
    for (labels) |entry| {
        if (entry[0] == active) {
            style.setColor(renderer, style.selection());
            var rect = c.SDL_Rect{ .x = entry[2] - 10, .y = 48, .w = font.textWidth(entry[1], 2) + 20, .h = 24 };
            _ = c.SDL_RenderFillRect(renderer, &rect);
        }
        font.text(renderer, entry[2], 52, 2, entry[1], if (entry[0] == active) style.bright() else style.muted());
    }
}

fn drawArtwork(renderer: *c.SDL_Renderer, artwork: *c.SDL_Texture) void {
    var width: c_int = 0;
    var height: c_int = 0;
    if (c.SDL_QueryTexture(artwork, null, null, &width, &height) != 0 or width <= 0 or height <= 0)
        return;
    const area = c.SDL_Rect{ .x = 400, .y = 86, .w = 226, .h = 286 };
    var target = area;
    if (@as(i64, area.w) * height > @as(i64, area.h) * width) {
        target.w = @intCast(@divTrunc(@as(i64, area.h) * width, height));
        target.x += @divTrunc(area.w - target.w, 2);
    } else {
        target.h = @intCast(@divTrunc(@as(i64, area.w) * height, width));
        target.y += @divTrunc(area.h - target.h, 2);
    }
    _ = c.SDL_RenderCopy(renderer, artwork, null, &target);
}

fn drawFavoriteMarker(renderer: *c.SDL_Renderer, x: c_int, y: c_int) void {
    const pixels = [_]struct { c_int, c_int }{
        .{ 2, 0 },
        .{ 0, 1 },
        .{ 1, 1 },
        .{ 2, 1 },
        .{ 3, 1 },
        .{ 4, 1 },
        .{ 1, 2 },
        .{ 2, 2 },
        .{ 3, 2 },
        .{ 1, 3 },
        .{ 3, 3 },
        .{ 0, 4 },
        .{ 4, 4 },
    };
    style.setColor(renderer, style.accent());
    for (pixels) |pixel| {
        var rect = c.SDL_Rect{
            .x = x + pixel[0] * 2,
            .y = y + pixel[1] * 2,
            .w = 2,
            .h = 2,
        };
        _ = c.SDL_RenderFillRect(renderer, &rect);
    }
}

fn isFavorite(store: *const settings.Store, title: *const Title) bool {
    const entry = store.findGame(productId(title)) orelse return false;
    return entry.favorite;
}

fn titleInitial(title: *const Title) u8 {
    for (titleName(title)) |byte| {
        if (std.ascii.isAlphanumeric(byte)) return std.ascii.toUpper(byte);
    }
    return '#';
}

fn bufferString(buffer: []const u8) []const u8 {
    return buffer[0 .. std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len];
}
