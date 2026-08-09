const std = @import("std");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("catalog_parser.h");
    @cInclude("catalog_search.h");
    @cInclude("controller.h");
    @cInclude("pixel_font.h");
});

const display_width = 640;
const display_height = 480;
const catalog_visible_rows = 9;
const query_capacity = 32;
const key_width = 52;
const key_height = 36;
const key_gap = 6;
const keyboard_rows = [_][]const u8{
    "QWERTYUIOP",
    "ASDFGHJKL",
    "ZXCVBNM",
    "1234567890",
};

const StopRequested = ?*const fn (?*anyopaque) callconv(.c) c_int;

const Ui = struct {
    renderer: *c.SDL_Renderer,
    controller: *c.GoControllerInput,
    stop_requested: StopRequested,
    stop_context: ?*anyopaque,
    cancelled: bool = false,
    aspect_4_3: bool = false,
};

const CatalogView = struct {
    titles: []const c.GoCatalogTitle,
    indices: []usize,
    count: usize = 0,
    selected: usize = 0,
    query: [query_capacity]u8 = [_]u8{0} ** query_capacity,
};

const MatchResult = struct {
    count: usize,
    first: ?usize,
};

fn pointerString(pointer: [*c]const u8) ?[]const u8 {
    if (pointer == null) return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(pointer)));
}

fn bufferString(buffer: []const u8) []const u8 {
    return buffer[0 .. std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len];
}

fn titleName(title: *const c.GoCatalogTitle) []const u8 {
    const name = bufferString(&title.name);
    return if (name.len > 0) name else bufferString(&title.title_id);
}

fn titleNamePointer(title: *const c.GoCatalogTitle) [*c]const u8 {
    return if (title.name[0] != 0) @ptrCast(&title.name) else @ptrCast(&title.title_id);
}

fn brightColor() c.SDL_Color {
    return .{ .r = 230, .g = 239, .b = 232, .a = 255 };
}

fn mutedColor() c.SDL_Color {
    return .{ .r = 148, .g = 169, .b = 158, .a = 255 };
}

fn weatherColor() c.SDL_Color {
    return .{ .r = 121, .g = 175, .b = 198, .a = 255 };
}

fn warningColor() c.SDL_Color {
    return .{ .r = 224, .g = 137, .b = 105, .a = 255 };
}

fn shouldStop(ui: *const Ui) bool {
    const callback = ui.stop_requested orelse return false;
    return callback(ui.stop_context) != 0;
}

fn streamWidth(ui: *const Ui) c_uint {
    return if (ui.aspect_4_3) 960 else 1280;
}

fn streamHeight(_: *const Ui) c_uint {
    return 720;
}

fn drawOvercastMark(renderer: *c.SDL_Renderer) void {
    _ = c.SDL_SetRenderDrawColor(renderer, 121, 175, 198, 255);
    var cloud = [_]c.SDL_Rect{
        .{ .x = 18, .y = 20, .w = 38, .h = 8 },
        .{ .x = 26, .y = 12, .w = 22, .h = 8 },
        .{ .x = 14, .y = 28, .w = 48, .h = 8 },
        .{ .x = 22, .y = 40, .w = 4, .h = 10 },
        .{ .x = 36, .y = 40, .w = 4, .h = 14 },
        .{ .x = 50, .y = 40, .w = 4, .h = 8 },
    };
    for (&cloud) |*rect| _ = c.SDL_RenderFillRect(renderer, rect);
}

fn cancelRequested(ui: *Ui) bool {
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event) != 0) {
        c.go_controller_input_handle_event(ui.controller, &event);
        if (event.type == c.SDL_QUIT or
            (event.type == c.SDL_KEYDOWN and event.key.keysym.sym == c.SDLK_ESCAPE) or
            (event.type == c.SDL_CONTROLLERBUTTONDOWN and
                event.cbutton.button == c.SDL_CONTROLLER_BUTTON_B))
        {
            ui.cancelled = true;
            return true;
        }
    }
    if (shouldStop(ui)) {
        ui.cancelled = true;
        return true;
    }
    return false;
}

fn drawLoading(ui: *Ui, heading: [*c]const u8, detail: [*c]const u8, action: [*c]const u8) void {
    if (heading == null or detail == null) return;
    _ = c.SDL_SetRenderDrawColor(ui.renderer, 7, 23, 18, 255);
    _ = c.SDL_RenderClear(ui.renderer);
    _ = c.SDL_SetRenderDrawColor(ui.renderer, 16, 38, 30, 255);
    var band = c.SDL_Rect{ .x = 0, .y = 152, .w = display_width, .h = 176 };
    _ = c.SDL_RenderFillRect(ui.renderer, &band);
    const heading_width = c.go_ui_text_width(heading, 4);
    c.go_ui_text(ui.renderer, @divTrunc(display_width - heading_width, 2), 198, 4, heading, brightColor());
    const detail_width = c.go_ui_text_width(detail, 2);
    c.go_ui_text(ui.renderer, @divTrunc(display_width - detail_width, 2), 270, 2, detail, weatherColor());
    if (action != null and action[0] != 0) {
        const action_width = c.go_ui_text_width(action, 2);
        c.go_ui_text(ui.renderer, @divTrunc(display_width - action_width, 2), 444, 2, action, brightColor());
    }
    c.SDL_RenderPresent(ui.renderer);
}

fn signInAction(ui: *Ui) c_int {
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event) != 0) {
        c.go_controller_input_handle_event(ui.controller, &event);
        if (event.type == c.SDL_QUIT or
            (event.type == c.SDL_KEYDOWN and event.key.keysym.sym == c.SDLK_ESCAPE) or
            (event.type == c.SDL_CONTROLLERBUTTONDOWN and
                event.cbutton.button == c.SDL_CONTROLLER_BUTTON_B))
        {
            ui.cancelled = true;
            return -1;
        }
        if (event.type == c.SDL_CONTROLLERBUTTONDOWN and
            event.cbutton.button == c.SDL_CONTROLLER_BUTTON_A) return 1;
    }
    if (shouldStop(ui)) {
        ui.cancelled = true;
        return -1;
    }
    return 0;
}

fn titleInitial(title: *const c.GoCatalogTitle) u8 {
    for (titleName(title)) |byte| {
        if (std.ascii.isAlphanumeric(byte)) return std.ascii.toUpper(byte);
    }
    return '#';
}

fn requestedTitle(titles: []const c.GoCatalogTitle, requested: []const u8) usize {
    for (titles, 0..) |*title, index| {
        if (std.mem.eql(u8, bufferString(&title.title_id), requested) or
            std.mem.eql(u8, bufferString(&title.product_id), requested)) return index;
    }
    return 0;
}

fn rebuildCatalogView(view: *CatalogView, preserve_title_index: usize) void {
    view.count = 0;
    view.selected = 0;
    for (view.titles, 0..) |*title, index| {
        if (c.go_catalog_search_matches(titleNamePointer(title), @ptrCast(&view.query)) == 0)
            continue;
        if (index == preserve_title_index) view.selected = view.count;
        view.indices[view.count] = index;
        view.count += 1;
    }
}

fn visibleTitle(view: *const CatalogView, index: usize) *const c.GoCatalogTitle {
    return &view.titles[view.indices[index]];
}

fn adjacentInitial(view: *const CatalogView, selected: usize, direction: i32) usize {
    const current = titleInitial(visibleTitle(view, selected));
    if (direction > 0) {
        var index = selected + 1;
        while (index < view.count) : (index += 1) {
            if (titleInitial(visibleTitle(view, index)) != current) return index;
        }
        return 0;
    }
    var start = selected;
    while (start > 0 and titleInitial(visibleTitle(view, start - 1)) == current) start -= 1;
    var previous = if (start > 0) start - 1 else view.count - 1;
    const target = titleInitial(visibleTitle(view, previous));
    while (previous > 0 and titleInitial(visibleTitle(view, previous - 1)) == target)
        previous -= 1;
    return previous;
}

fn drawCatalog(ui: *Ui, view: *const CatalogView) void {
    _ = c.SDL_SetRenderDrawColor(ui.renderer, 7, 23, 18, 255);
    _ = c.SDL_RenderClear(ui.renderer);
    _ = c.SDL_SetRenderDrawColor(ui.renderer, 16, 38, 30, 255);
    var header = c.SDL_Rect{ .x = 0, .y = 0, .w = display_width, .h = 68 };
    var footer = c.SDL_Rect{ .x = 0, .y = 424, .w = display_width, .h = 56 };
    _ = c.SDL_RenderFillRect(ui.renderer, &header);
    _ = c.SDL_RenderFillRect(ui.renderer, &footer);
    drawOvercastMark(ui.renderer);
    c.go_ui_text(ui.renderer, 78, 12, 4, "GREENOVERCAST", brightColor());

    var count_buffer: [32]u8 = undefined;
    const count_text = if (view.query[0] != 0)
        std.fmt.bufPrintZ(&count_buffer, "{d}/{d} OF {d}", .{
            view.selected + 1,
            view.count,
            view.titles.len,
        }) catch return
    else
        std.fmt.bufPrintZ(&count_buffer, "{d} / {d}", .{ view.selected + 1, view.count }) catch return;
    const count_x = display_width - c.go_ui_text_width(count_text.ptr, 2) - 16;
    c.go_ui_text(ui.renderer, count_x, 46, 2, count_text.ptr, mutedColor());
    if (view.query[0] != 0) {
        var search_buffer: [query_capacity + 9]u8 = undefined;
        const search_text = std.fmt.bufPrintZ(
            &search_buffer,
            "SEARCH: {s}",
            .{bufferString(&view.query)},
        ) catch return;
        c.go_ui_text_ellipsized(ui.renderer, 80, 46, 2, search_text.ptr, count_x - 92, weatherColor());
    } else {
        c.go_ui_text(ui.renderer, 80, 46, 2, "CLOUD LIBRARY", weatherColor());
    }

    var start = view.selected -| @as(usize, catalog_visible_rows / 2);
    const maximum_start = view.count -| @as(usize, catalog_visible_rows);
    start = @min(start, maximum_start);

    var initial = [2]u8{ titleInitial(visibleTitle(view, view.selected)), 0 };
    _ = c.SDL_SetRenderDrawColor(ui.renderer, 24, 58, 45, 255);
    var initial_panel = c.SDL_Rect{ .x = 14, .y = 86, .w = 48, .h = 48 };
    _ = c.SDL_RenderFillRect(ui.renderer, &initial_panel);
    const initial_width = c.go_ui_text_width(@ptrCast(&initial), 5);
    c.go_ui_text(ui.renderer, 38 - @divTrunc(initial_width, 2), 92, 5, @ptrCast(&initial), weatherColor());

    var row: usize = 0;
    while (row < catalog_visible_rows) : (row += 1) {
        const index = start + row;
        if (index >= view.count) break;
        const title = visibleTitle(view, index);
        const y: c_int = @intCast(82 + row * 36);
        if (index == view.selected) {
            _ = c.SDL_SetRenderDrawColor(ui.renderer, 45, 105, 71, 255);
            var selection = c.SDL_Rect{ .x = 72, .y = y, .w = 554, .h = 32 };
            _ = c.SDL_RenderFillRect(ui.renderer, &selection);
            _ = c.SDL_SetRenderDrawColor(ui.renderer, 121, 175, 198, 255);
            var rain_bar = c.SDL_Rect{ .x = 72, .y = y, .w = 5, .h = 32 };
            _ = c.SDL_RenderFillRect(ui.renderer, &rain_bar);
            c.go_ui_text_ellipsized(ui.renderer, 88, y + 5, 3, titleNamePointer(title), 520, brightColor());
        } else {
            c.go_ui_text_ellipsized(ui.renderer, 88, y + 5, 3, titleNamePointer(title), 520, mutedColor());
        }
    }
    var controls_buffer: [48]u8 = undefined;
    const controls = std.fmt.bufPrintZ(
        &controls_buffer,
        "A PLAY  X SEARCH  Y {s}  B BACK",
        .{if (ui.aspect_4_3) "4:3" else "16:9"},
    ) catch return;
    c.go_ui_text(ui.renderer, 16, 434, 2, controls.ptr, brightColor());
    if (view.query[0] != 0)
        c.go_ui_text(ui.renderer, 16, 458, 2, "Y CLEAR  LB/RB PAGE  LT/RT LETTER", weatherColor())
    else
        c.go_ui_text(ui.renderer, 16, 458, 2, "LB/RB PAGE   LT/RT LETTER", weatherColor());
    c.SDL_RenderPresent(ui.renderer);
}

fn matchingTitles(titles: []const c.GoCatalogTitle, query: [*:0]const u8) MatchResult {
    var result = MatchResult{ .count = 0, .first = null };
    for (titles, 0..) |*title, index| {
        if (c.go_catalog_search_matches(titleNamePointer(title), query) == 0) continue;
        if (result.first == null) result.first = index;
        result.count += 1;
    }
    return result;
}

fn drawKey(renderer: *c.SDL_Renderer, x: c_int, y: c_int, character: u8, selected: bool) void {
    if (selected) {
        _ = c.SDL_SetRenderDrawColor(renderer, 45, 105, 71, 255);
        var background = c.SDL_Rect{ .x = x, .y = y, .w = key_width, .h = key_height };
        _ = c.SDL_RenderFillRect(renderer, &background);
        _ = c.SDL_SetRenderDrawColor(renderer, 121, 175, 198, 255);
        var rain_bar = c.SDL_Rect{ .x = x, .y = y, .w = 4, .h = key_height };
        _ = c.SDL_RenderFillRect(renderer, &rain_bar);
    } else {
        _ = c.SDL_SetRenderDrawColor(renderer, 16, 38, 30, 255);
        var background = c.SDL_Rect{ .x = x, .y = y, .w = key_width, .h = key_height };
        _ = c.SDL_RenderFillRect(renderer, &background);
    }
    var label = [2]u8{ character, 0 };
    const width = c.go_ui_text_width(@ptrCast(&label), 3);
    c.go_ui_text(
        renderer,
        x + @divTrunc(key_width - width, 2),
        y + 8,
        3,
        @ptrCast(&label),
        if (selected) brightColor() else mutedColor(),
    );
}

fn drawKeyboard(
    ui: *Ui,
    titles: []const c.GoCatalogTitle,
    query: *const [query_capacity]u8,
    selected_row: usize,
    selected_column: usize,
) void {
    _ = c.SDL_SetRenderDrawColor(ui.renderer, 7, 23, 18, 255);
    _ = c.SDL_RenderClear(ui.renderer);
    _ = c.SDL_SetRenderDrawColor(ui.renderer, 16, 38, 30, 255);
    var header = c.SDL_Rect{ .x = 0, .y = 0, .w = display_width, .h = 68 };
    var query_panel = c.SDL_Rect{ .x = 18, .y = 82, .w = display_width - 36, .h = 48 };
    var footer = c.SDL_Rect{ .x = 0, .y = 398, .w = display_width, .h = display_height - 398 };
    _ = c.SDL_RenderFillRect(ui.renderer, &header);
    _ = c.SDL_RenderFillRect(ui.renderer, &query_panel);
    _ = c.SDL_RenderFillRect(ui.renderer, &footer);
    c.go_ui_text(ui.renderer, 18, 14, 4, "SEARCH LIBRARY", brightColor());
    if (query[0] != 0)
        c.go_ui_text_ellipsized(ui.renderer, 30, 92, 3, @ptrCast(query), display_width - 60, brightColor())
    else
        c.go_ui_text(ui.renderer, 30, 98, 2, "TYPE A GAME NAME", mutedColor());

    const matches = matchingTitles(titles, @ptrCast(query));
    var match_buffer: [48]u8 = undefined;
    const match_text = std.fmt.bufPrintZ(
        &match_buffer,
        "{d} {s}",
        .{ matches.count, if (matches.count == 1) "MATCH" else "MATCHES" },
    ) catch return;
    c.go_ui_text(
        ui.renderer,
        20,
        144,
        2,
        match_text.ptr,
        if (matches.count > 0) weatherColor() else warningColor(),
    );
    if (matches.first) |first| {
        c.go_ui_text_ellipsized(
            ui.renderer,
            170,
            144,
            2,
            titleNamePointer(&titles[first]),
            display_width - 190,
            mutedColor(),
        );
    }

    for (keyboard_rows, 0..) |keys, row| {
        const row_width: c_int = @intCast(keys.len * key_width + (keys.len - 1) * key_gap);
        const start_x = @divTrunc(display_width - row_width, 2);
        const y: c_int = @intCast(184 + row * (key_height + 8));
        for (keys, 0..) |character, column| {
            const x = start_x + @as(c_int, @intCast(column * (key_width + key_gap)));
            drawKey(ui.renderer, x, y, character, row == selected_row and column == selected_column);
        }
    }
    c.go_ui_text(ui.renderer, 16, 408, 2, "A TYPE   X DELETE   Y CLEAR", brightColor());
    c.go_ui_text(ui.renderer, 16, 436, 2, "DPAD MOVE", weatherColor());
    c.go_ui_text(ui.renderer, 274, 436, 2, "START APPLY   B CANCEL", brightColor());
    if (matches.count == 0)
        c.go_ui_text(ui.renderer, 16, 462, 1, "ADD OR DELETE LETTERS TO CONTINUE", warningColor());
    c.SDL_RenderPresent(ui.renderer);
}

fn moveVertical(row: *usize, column: *usize, direction: i32) void {
    if (direction < 0)
        row.* = if (row.* == 0) keyboard_rows.len - 1 else row.* - 1
    else
        row.* = (row.* + 1) % keyboard_rows.len;
    column.* = @min(column.*, keyboard_rows[row.*].len - 1);
}

fn appendSelectedCharacter(
    draft: *[query_capacity]u8,
    row: usize,
    column: usize,
) void {
    const length = bufferString(draft).len;
    if (length + 1 >= draft.len) return;
    draft[length] = keyboard_rows[row][column];
    draft[length + 1] = 0;
}

fn applySearch(
    titles: []const c.GoCatalogTitle,
    draft: *const [query_capacity]u8,
    query: *[query_capacity]u8,
) bool {
    if (matchingTitles(titles, @ptrCast(draft)).count == 0) return false;
    query.* = draft.*;
    return true;
}

fn axisStep(value: i16, latch: *i8) ?i8 {
    const direction: i8 = if (value < -16000)
        -1
    else if (value > 16000)
        1
    else if (value > -8000 and value < 8000)
        0
    else
        latch.*;
    if (direction == 0) {
        latch.* = 0;
        return null;
    }
    if (direction == latch.*) return null;
    latch.* = direction;
    return direction;
}

fn runSearchKeyboard(
    ui: *Ui,
    titles: []const c.GoCatalogTitle,
    query: *[query_capacity]u8,
) c_int {
    var draft = query.*;
    var selected_row: usize = 0;
    var selected_column: usize = 0;
    var horizontal_latch: i8 = 0;
    var vertical_latch: i8 = 0;
    while (true) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            c.go_controller_input_handle_event(ui.controller, &event);
            if (event.type == c.SDL_QUIT) {
                ui.cancelled = true;
                return -1;
            }
            if (event.type == c.SDL_KEYDOWN) switch (event.key.keysym.sym) {
                c.SDLK_ESCAPE => return 0,
                c.SDLK_BACKSPACE => {
                    const length = bufferString(&draft).len;
                    if (length > 0) draft[length - 1] = 0;
                },
                c.SDLK_DELETE => draft[0] = 0,
                c.SDLK_LEFT => selected_column = if (selected_column == 0)
                    keyboard_rows[selected_row].len - 1
                else
                    selected_column - 1,
                c.SDLK_RIGHT => selected_column = (selected_column + 1) % keyboard_rows[selected_row].len,
                c.SDLK_UP => moveVertical(&selected_row, &selected_column, -1),
                c.SDLK_DOWN => moveVertical(&selected_row, &selected_column, 1),
                c.SDLK_RETURN => appendSelectedCharacter(&draft, selected_row, selected_column),
                c.SDLK_SPACE => if (applySearch(titles, &draft, query)) return 1,
                else => {},
            };
            if (event.type == c.SDL_CONTROLLERBUTTONDOWN) {
                switch (event.cbutton.button) {
                    c.SDL_CONTROLLER_BUTTON_B => return 0,
                    c.SDL_CONTROLLER_BUTTON_X => {
                        const length = bufferString(&draft).len;
                        if (length > 0) draft[length - 1] = 0;
                    },
                    c.SDL_CONTROLLER_BUTTON_Y => draft[0] = 0,
                    c.SDL_CONTROLLER_BUTTON_DPAD_LEFT => selected_column = if (selected_column == 0)
                        keyboard_rows[selected_row].len - 1
                    else
                        selected_column - 1,
                    c.SDL_CONTROLLER_BUTTON_DPAD_RIGHT => selected_column = (selected_column + 1) % keyboard_rows[selected_row].len,
                    c.SDL_CONTROLLER_BUTTON_DPAD_UP => moveVertical(&selected_row, &selected_column, -1),
                    c.SDL_CONTROLLER_BUTTON_DPAD_DOWN => moveVertical(&selected_row, &selected_column, 1),
                    c.SDL_CONTROLLER_BUTTON_A => appendSelectedCharacter(&draft, selected_row, selected_column),
                    c.SDL_CONTROLLER_BUTTON_START => if (applySearch(titles, &draft, query)) return 1,
                    else => {},
                }
            } else if (event.type == c.SDL_CONTROLLERAXISMOTION) {
                if (event.caxis.axis == c.SDL_CONTROLLER_AXIS_LEFTX) {
                    if (axisStep(event.caxis.value, &horizontal_latch)) |direction| {
                        selected_column = if (direction < 0)
                            if (selected_column == 0)
                                keyboard_rows[selected_row].len - 1
                            else
                                selected_column - 1
                        else
                            (selected_column + 1) % keyboard_rows[selected_row].len;
                    }
                } else if (event.caxis.axis == c.SDL_CONTROLLER_AXIS_LEFTY) {
                    if (axisStep(event.caxis.value, &vertical_latch)) |direction|
                        moveVertical(&selected_row, &selected_column, direction);
                }
            }
        }
        if (shouldStop(ui)) {
            ui.cancelled = true;
            return -1;
        }
        drawKeyboard(ui, titles, &draft, selected_row, selected_column);
        c.SDL_Delay(16);
    }
}

fn pickTitle(ui: *Ui, titles: []const c.GoCatalogTitle, requested: []const u8) c_int {
    if (titles.len == 0) return -1;
    ui.cancelled = false;
    const indices = std.heap.c_allocator.alloc(usize, titles.len) catch return -1;
    defer std.heap.c_allocator.free(indices);
    var view = CatalogView{ .titles = titles, .indices = indices };
    rebuildCatalogView(&view, requestedTitle(titles, requested));
    if (view.count == 0) return -1;
    var left_trigger_latched = false;
    var right_trigger_latched = false;
    var vertical_latch: i8 = 0;
    while (true) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            c.go_controller_input_handle_event(ui.controller, &event);
            if (event.type == c.SDL_QUIT or
                (event.type == c.SDL_KEYDOWN and event.key.keysym.sym == c.SDLK_ESCAPE))
            {
                ui.cancelled = true;
                return -1;
            }
            if (event.type == c.SDL_CONTROLLERBUTTONDOWN) switch (event.cbutton.button) {
                c.SDL_CONTROLLER_BUTTON_A => return @intCast(view.indices[view.selected]),
                c.SDL_CONTROLLER_BUTTON_B => {
                    ui.cancelled = true;
                    return -1;
                },
                c.SDL_CONTROLLER_BUTTON_X => {
                    const preserve = view.indices[view.selected];
                    const search_result = runSearchKeyboard(ui, titles, &view.query);
                    if (search_result < 0) return -1;
                    if (search_result > 0) rebuildCatalogView(&view, preserve);
                    if (view.count == 0) return -1;
                    left_trigger_latched = false;
                    right_trigger_latched = false;
                },
                c.SDL_CONTROLLER_BUTTON_Y => {
                    if (view.query[0] != 0) {
                        const preserve = view.indices[view.selected];
                        @memset(&view.query, 0);
                        rebuildCatalogView(&view, preserve);
                    } else {
                        ui.aspect_4_3 = !ui.aspect_4_3;
                    }
                },
                c.SDL_CONTROLLER_BUTTON_DPAD_UP => view.selected = if (view.selected > 0) view.selected - 1 else view.count - 1,
                c.SDL_CONTROLLER_BUTTON_DPAD_DOWN => view.selected = if (view.selected + 1 < view.count) view.selected + 1 else 0,
                c.SDL_CONTROLLER_BUTTON_LEFTSHOULDER => view.selected -|= @as(usize, catalog_visible_rows),
                c.SDL_CONTROLLER_BUTTON_RIGHTSHOULDER => view.selected = @min(view.selected + catalog_visible_rows, view.count - 1),
                else => {},
            };
            if (event.type == c.SDL_CONTROLLERAXISMOTION) {
                if (event.caxis.axis == c.SDL_CONTROLLER_AXIS_LEFTY) {
                    if (axisStep(event.caxis.value, &vertical_latch)) |direction| {
                        if (direction < 0)
                            view.selected = if (view.selected > 0) view.selected - 1 else view.count - 1
                        else
                            view.selected = if (view.selected + 1 < view.count) view.selected + 1 else 0;
                    }
                } else if (event.caxis.axis == c.SDL_CONTROLLER_AXIS_TRIGGERLEFT) {
                    if (event.caxis.value > 16000 and !left_trigger_latched) {
                        view.selected = adjacentInitial(&view, view.selected, -1);
                        left_trigger_latched = true;
                    } else if (event.caxis.value < 8000) {
                        left_trigger_latched = false;
                    }
                } else if (event.caxis.axis == c.SDL_CONTROLLER_AXIS_TRIGGERRIGHT) {
                    if (event.caxis.value > 16000 and !right_trigger_latched) {
                        view.selected = adjacentInitial(&view, view.selected, 1);
                        right_trigger_latched = true;
                    } else if (event.caxis.value < 8000) {
                        right_trigger_latched = false;
                    }
                }
            }
        }
        if (shouldStop(ui)) {
            ui.cancelled = true;
            return -1;
        }
        if (c.go_controller_input_exit_held(ui.controller, 1000) != 0) {
            ui.cancelled = true;
            return -1;
        }
        drawCatalog(ui, &view);
        c.SDL_Delay(16);
    }
}

pub export fn go_handheld_ui_create(
    renderer: ?*c.SDL_Renderer,
    controller: ?*c.GoControllerInput,
    stop_requested: StopRequested,
    stop_context: ?*anyopaque,
) ?*Ui {
    const renderer_handle = renderer orelse return null;
    const controller_handle = controller orelse return null;
    const ui = std.heap.c_allocator.create(Ui) catch return null;
    ui.* = .{
        .renderer = renderer_handle,
        .controller = controller_handle,
        .stop_requested = stop_requested,
        .stop_context = stop_context,
    };
    return ui;
}

pub export fn go_handheld_ui_destroy(ui: ?*Ui) void {
    std.heap.c_allocator.destroy(ui orelse return);
}

pub export fn go_handheld_ui_draw_loading(
    ui: ?*Ui,
    heading: [*c]const u8,
    detail: [*c]const u8,
    action: [*c]const u8,
) void {
    drawLoading(ui orelse return, heading, detail, action);
}

pub export fn go_handheld_ui_draw_device_code(
    ui: ?*Ui,
    user_code: [*c]const u8,
    status: [*c]const u8,
    seconds_remaining: c_uint,
) void {
    const handle = ui orelse return;
    if (user_code == null or status == null) return;
    _ = c.SDL_SetRenderDrawColor(handle.renderer, 7, 23, 18, 255);
    _ = c.SDL_RenderClear(handle.renderer);
    _ = c.SDL_SetRenderDrawColor(handle.renderer, 16, 38, 30, 255);
    var header = c.SDL_Rect{ .x = 0, .y = 0, .w = display_width, .h = 68 };
    var code_band = c.SDL_Rect{ .x = 0, .y = 228, .w = display_width, .h = 126 };
    var footer = c.SDL_Rect{ .x = 0, .y = 424, .w = display_width, .h = 56 };
    _ = c.SDL_RenderFillRect(handle.renderer, &header);
    _ = c.SDL_RenderFillRect(handle.renderer, &code_band);
    _ = c.SDL_RenderFillRect(handle.renderer, &footer);
    drawOvercastMark(handle.renderer);
    c.go_ui_text(handle.renderer, 78, 12, 4, "GREENOVERCAST", brightColor());
    c.go_ui_text(handle.renderer, 80, 46, 2, "XBOX SIGN IN", weatherColor());
    const heading = "SIGN IN ON ANOTHER DEVICE";
    c.go_ui_text(handle.renderer, @divTrunc(display_width - c.go_ui_text_width(heading, 3), 2), 96, 3, heading, brightColor());
    const instruction = "OPEN THIS ADDRESS ON YOUR PHONE";
    c.go_ui_text(handle.renderer, @divTrunc(display_width - c.go_ui_text_width(instruction, 2), 2), 148, 2, instruction, mutedColor());
    const address = "MICROSOFT.COM/LINK";
    c.go_ui_text(handle.renderer, @divTrunc(display_width - c.go_ui_text_width(address, 3), 2), 180, 3, address, weatherColor());
    const code_label = "ENTER THIS CODE";
    c.go_ui_text(handle.renderer, @divTrunc(display_width - c.go_ui_text_width(code_label, 2), 2), 244, 2, code_label, mutedColor());
    c.go_ui_text(handle.renderer, @divTrunc(display_width - c.go_ui_text_width(user_code, 5), 2), 282, 5, user_code, brightColor());
    var state_buffer: [96]u8 = undefined;
    const state = std.fmt.bufPrintZ(
        &state_buffer,
        "{s}  {d}:{d:0>2}",
        .{ pointerString(status).?, seconds_remaining / 60, seconds_remaining % 60 },
    ) catch return;
    c.go_ui_text(handle.renderer, @divTrunc(display_width - c.go_ui_text_width(state.ptr, 2), 2), 378, 2, state.ptr, weatherColor());
    c.go_ui_text(handle.renderer, 16, 444, 2, "B CANCEL", brightColor());
    c.SDL_RenderPresent(handle.renderer);
}

pub export fn go_handheld_ui_wait(ui: ?*Ui, milliseconds: c.Uint32) c_int {
    const handle = ui orelse return -1;
    const started = c.SDL_GetTicks();
    while (c.SDL_GetTicks() -% started < milliseconds) {
        if (cancelRequested(handle)) return -1;
        c.SDL_Delay(16);
    }
    return 0;
}

pub export fn go_handheld_ui_cancel_requested(ui: ?*Ui) c_int {
    return @intFromBool(cancelRequested(ui orelse return 1));
}

pub export fn go_handheld_ui_sign_in_action(ui: ?*Ui) c_int {
    return signInAction(ui orelse return -1);
}

pub export fn go_handheld_ui_wait_for_retry(
    ui: ?*Ui,
    heading: [*c]const u8,
    detail: [*c]const u8,
) c_int {
    const handle = ui orelse return 0;
    drawLoading(handle, heading, detail, "A RETRY   B BACK");
    while (true) {
        const action = signInAction(handle);
        if (action != 0) return @intFromBool(action > 0);
        c.SDL_Delay(16);
    }
}

pub export fn go_handheld_ui_pick_title(
    ui: ?*Ui,
    titles: [*c]const c.GoCatalogTitle,
    count: c_int,
    requested: [*c]const u8,
) c_int {
    if (titles == null or count <= 0) return -1;
    return pickTitle(
        ui orelse return -1,
        titles[0..@intCast(count)],
        pointerString(requested) orelse "",
    );
}

pub export fn go_handheld_ui_cancelled(ui: ?*const Ui) c_int {
    return @intFromBool(if (ui) |handle| handle.cancelled else false);
}

pub export fn go_handheld_ui_stream_width(ui: ?*const Ui) c_uint {
    return streamWidth(ui orelse return 1280);
}

pub export fn go_handheld_ui_stream_height(ui: ?*const Ui) c_uint {
    return streamHeight(ui orelse return 720);
}
