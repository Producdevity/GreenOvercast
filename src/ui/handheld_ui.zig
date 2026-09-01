const std = @import("std");
const artwork = @import("artwork_loader.zig");
const controls = @import("control_icons.zig");
const keyboard = @import("keyboard.zig");
const library = @import("library_view.zig");
const navigation = @import("navigation_repeat.zig");
const persistent = @import("persistent_settings.zig");
const font = @import("pixel_font.zig");
const settings_view = @import("settings_view.zig");
const stream_dimensions = @import("stream_dimensions.zig");
const style = @import("view_style.zig");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("catalog_parser.h");
    @cInclude("controller.h");
    @cInclude("handheld_ui.h");
});

const StopRequested = ?*const fn (?*anyopaque) callconv(.c) c_int;

const Ui = struct {
    renderer: *c.SDL_Renderer,
    controller: *c.GoControllerInput,
    stop_requested: StopRequested,
    stop_context: ?*anyopaque,
    settings: persistent.Store,
    artwork: artwork.Loader = .{},
    cancelled: bool = false,
    stream_width: u32,
    stream_height: u32,
};

const ArtworkSelection = struct {
    title_index: ?usize = null,
    requested_index: ?usize = null,
    changed_at: c.Uint32 = 0,
    enabled: bool = false,
};

fn pointerString(pointer: [*c]const u8) ?[]const u8 {
    if (pointer == null) return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(pointer)));
}

fn bufferString(buffer: []const u8) []const u8 {
    return buffer[0 .. std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len];
}

fn shouldStop(ui: *const Ui) bool {
    const callback = ui.stop_requested orelse return false;
    return callback(ui.stop_context) != 0;
}

fn preferredStreamDimensions(renderer: *c.SDL_Renderer) stream_dimensions.Dimensions {
    var width: c_int = style.display_width;
    var height: c_int = style.display_height;
    if (c.SDL_GetRendererOutputSize(renderer, &width, &height) != 0 or width <= 0 or height <= 0)
        return stream_dimensions.forDisplay(style.display_width, style.display_height);
    return stream_dimensions.forDisplay(@intCast(width), @intCast(height));
}

fn semanticButton(ui: *const Ui, physical_button: c.Uint8) c.SDL_GameControllerButton {
    return c.go_controller_input_map_button(ui.controller, physical_button);
}

fn activeControllerEvent(ui: *const Ui, event: *const c.SDL_Event) bool {
    return c.go_controller_input_event_is_active(ui.controller, event) != 0;
}

fn cancelRequested(ui: *Ui) bool {
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event) != 0) {
        c.go_controller_input_handle_event(ui.controller, &event);
        if (event.type == c.SDL_QUIT or
            (event.type == c.SDL_KEYDOWN and event.key.keysym.sym == c.SDLK_ESCAPE) or
            (event.type == c.SDL_CONTROLLERBUTTONDOWN and activeControllerEvent(ui, &event) and
                semanticButton(ui, event.cbutton.button) == c.SDL_CONTROLLER_BUTTON_B))
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

fn drawLoading(ui: *Ui, heading: [*c]const u8, detail: [*c]const u8, action: c.GoHandheldUiAction) void {
    if (heading == null or detail == null) return;
    style.setColor(ui.renderer, style.background());
    _ = c.SDL_RenderClear(ui.renderer);
    style.setColor(ui.renderer, style.panel());
    var band = c.SDL_Rect{ .x = 0, .y = 152, .w = style.display_width, .h = 176 };
    _ = c.SDL_RenderFillRect(ui.renderer, &band);
    const heading_width = font.textWidth(heading, 4);
    font.text(ui.renderer, @divTrunc(style.display_width - heading_width, 2), 198, 4, heading, style.bright());
    const detail_width = font.textWidth(detail, 2);
    font.text(ui.renderer, @divTrunc(style.display_width - detail_width, 2), 270, 2, detail, style.accent());
    drawLoadingAction(ui, action);
    c.SDL_RenderPresent(ui.renderer);
}

fn drawLoadingAction(ui: *Ui, action: c.GoHandheldUiAction) void {
    const mode = ui.settings.face_buttons;
    if (action == c.GO_HANDHELD_UI_ACTION_BACK) {
        const prompts = [_]controls.Prompt{
            controls.Prompt.one(controls.face(mode, .b), "BACK"),
        };
        controls.drawCenteredRow(ui.renderer, 439, &prompts, style.bright());
    } else if (action == c.GO_HANDHELD_UI_ACTION_CANCEL) {
        const prompts = [_]controls.Prompt{
            controls.Prompt.one(controls.face(mode, .b), "CANCEL"),
        };
        controls.drawCenteredRow(ui.renderer, 439, &prompts, style.bright());
    } else if (action == c.GO_HANDHELD_UI_ACTION_RETRY_BACK) {
        const prompts = [_]controls.Prompt{
            controls.Prompt.one(controls.face(mode, .a), "RETRY"),
            controls.Prompt.one(controls.face(mode, .b), "BACK"),
        };
        controls.drawCenteredRow(ui.renderer, 439, &prompts, style.bright());
    }
}

fn signInAction(ui: *Ui) c_int {
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event) != 0) {
        c.go_controller_input_handle_event(ui.controller, &event);
        if (event.type == c.SDL_QUIT or
            (event.type == c.SDL_KEYDOWN and event.key.keysym.sym == c.SDLK_ESCAPE) or
            (event.type == c.SDL_CONTROLLERBUTTONDOWN and activeControllerEvent(ui, &event) and
                semanticButton(ui, event.cbutton.button) == c.SDL_CONTROLLER_BUTTON_B))
        {
            ui.cancelled = true;
            return -1;
        }
        if (event.type == c.SDL_CONTROLLERBUTTONDOWN and activeControllerEvent(ui, &event) and
            semanticButton(ui, event.cbutton.button) == c.SDL_CONTROLLER_BUTTON_A) return 1;
    }
    if (shouldStop(ui)) {
        ui.cancelled = true;
        return -1;
    }
    return 0;
}

fn drawKey(
    renderer: *c.SDL_Renderer,
    x: c_int,
    y: c_int,
    width: c_int,
    key: keyboard.Key,
    selected: bool,
) void {
    style.setColor(renderer, if (selected) style.selection() else style.panel());
    var background = c.SDL_Rect{ .x = x, .y = y, .w = width, .h = 36 };
    _ = c.SDL_RenderFillRect(renderer, &background);
    if (selected) {
        style.setColor(renderer, style.accent());
        var bar = c.SDL_Rect{ .x = x, .y = y, .w = 4, .h = 36 };
        _ = c.SDL_RenderFillRect(renderer, &bar);
    }
    var label_buffer: [8]u8 = [_]u8{0} ** 8;
    @memcpy(label_buffer[0..key.label.len], key.label);
    const scale: c_int = if (key.label.len > 1) 2 else 3;
    const label_width = font.textWidth(@ptrCast(&label_buffer), scale);
    font.text(
        renderer,
        x + @divTrunc(width - label_width, 2),
        y + if (scale == 3) @as(c_int, 8) else 11,
        scale,
        @ptrCast(&label_buffer),
        if (selected) style.bright() else style.muted(),
    );
}

fn keyboardRowWidth(keys: []const keyboard.Key) c_int {
    var width: c_int = 0;
    for (keys, 0..) |key, index| {
        width += @as(c_int, key.width_units) * keyboard.unit_width;
        if (index + 1 < keys.len) width += keyboard.gap_width;
    }
    return width;
}

fn drawKeyboard(
    ui: *Ui,
    view: *const library.View,
    query: *const [library.query_capacity]u8,
    selection: keyboard.Selection,
) void {
    style.setColor(ui.renderer, style.background());
    _ = c.SDL_RenderClear(ui.renderer);
    style.setColor(ui.renderer, style.panel());
    var header = c.SDL_Rect{ .x = 0, .y = 0, .w = style.display_width, .h = 68 };
    var query_panel = c.SDL_Rect{ .x = 18, .y = 78, .w = style.display_width - 36, .h = 46 };
    var footer = c.SDL_Rect{ .x = 0, .y = 398, .w = style.display_width, .h = style.display_height - 398 };
    _ = c.SDL_RenderFillRect(ui.renderer, &header);
    _ = c.SDL_RenderFillRect(ui.renderer, &query_panel);
    _ = c.SDL_RenderFillRect(ui.renderer, &footer);
    font.text(ui.renderer, 18, 14, 4, "SEARCH LIBRARY", style.bright());
    if (query[0] != 0)
        font.textEllipsized(ui.renderer, 30, 88, 3, @ptrCast(query), style.display_width - 60, style.bright())
    else
        font.text(ui.renderer, 30, 92, 2, "TYPE A GAME NAME", style.muted());

    const match_count = library.matchingCount(view.titles, &ui.settings, view.collection, @ptrCast(query));
    var match_buffer: [48]u8 = undefined;
    const match_text = std.fmt.bufPrintZ(
        &match_buffer,
        "{d} {s} IN {s}",
        .{ match_count, if (match_count == 1) "MATCH" else "MATCHES", if (view.collection == .all) "ALL" else "FAVORITES" },
    ) catch return;
    font.text(ui.renderer, 20, 138, 2, match_text.ptr, if (match_count > 0) style.accent() else style.warning());

    for (keyboard.rows, 0..) |keys, row| {
        const row_width = keyboardRowWidth(keys);
        var x = @divTrunc(style.display_width - row_width, 2);
        const y: c_int = @intCast(174 + row * 52);
        for (keys, 0..) |key, column| {
            const width = @as(c_int, key.width_units) * keyboard.unit_width;
            drawKey(ui.renderer, x, y, width, key, row == selection.row and column == selection.column);
            x += width + keyboard.gap_width;
        }
    }
    const primary = [_]controls.Prompt{
        controls.Prompt.one(controls.face(ui.settings.face_buttons, .a), "TYPE"),
        controls.Prompt.one(controls.face(ui.settings.face_buttons, .x), "DELETE"),
        controls.Prompt.one(controls.face(ui.settings.face_buttons, .y), "CLEAR"),
        controls.Prompt.one(controls.face(ui.settings.face_buttons, .b), "CANCEL"),
    };
    const secondary = [_]controls.Prompt{
        controls.Prompt.one(.dpad, "MOVE"),
        controls.Prompt.one(.start, "APPLY"),
    };
    controls.drawRow(ui.renderer, 16, 405, &primary, style.bright());
    controls.drawRow(ui.renderer, 16, 437, &secondary, style.accent());
    c.SDL_RenderPresent(ui.renderer);
}

fn heldDirection(ui: *Ui, horizontal: *navigation.AxisLatch, vertical: *navigation.AxisLatch) navigation.Direction {
    if (c.go_controller_input_button_pressed(ui.controller, c.SDL_CONTROLLER_BUTTON_DPAD_UP) != 0) return .up;
    if (c.go_controller_input_button_pressed(ui.controller, c.SDL_CONTROLLER_BUTTON_DPAD_DOWN) != 0) return .down;
    if (c.go_controller_input_button_pressed(ui.controller, c.SDL_CONTROLLER_BUTTON_DPAD_LEFT) != 0) return .left;
    if (c.go_controller_input_button_pressed(ui.controller, c.SDL_CONTROLLER_BUTTON_DPAD_RIGHT) != 0) return .right;
    const vertical_direction = vertical.update(c.go_controller_input_axis(ui.controller, c.SDL_CONTROLLER_AXIS_LEFTY));
    if (vertical_direction < 0) return .up;
    if (vertical_direction > 0) return .down;
    const horizontal_direction = horizontal.update(c.go_controller_input_axis(ui.controller, c.SDL_CONTROLLER_AXIS_LEFTX));
    if (horizontal_direction < 0) return .left;
    if (horizontal_direction > 0) return .right;
    return .none;
}

fn runSearchKeyboard(ui: *Ui, view: *library.View) c_int {
    var draft = view.query;
    var selection = keyboard.Selection{};
    var repeat = navigation.Repeater{};
    var horizontal_latch = navigation.AxisLatch{};
    var vertical_latch = navigation.AxisLatch{};
    var dirty = true;
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
                c.SDLK_BACKSPACE => keyboard.erase(&draft),
                c.SDLK_DELETE => keyboard.clear(&draft),
                c.SDLK_LEFT => selection.moveHorizontal(-1),
                c.SDLK_RIGHT => selection.moveHorizontal(1),
                c.SDLK_UP => selection.moveVertical(-1),
                c.SDLK_DOWN => selection.moveVertical(1),
                c.SDLK_RETURN => keyboard.activate(selection, &draft),
                c.SDLK_SPACE => appendCharacter(&draft, ' '),
                else => {},
            };
            if (event.type == c.SDL_KEYDOWN) dirty = true;
            if (event.type == c.SDL_CONTROLLERBUTTONDOWN and activeControllerEvent(ui, &event)) {
                switch (semanticButton(ui, event.cbutton.button)) {
                    c.SDL_CONTROLLER_BUTTON_B => return 0,
                    c.SDL_CONTROLLER_BUTTON_X => keyboard.erase(&draft),
                    c.SDL_CONTROLLER_BUTTON_Y => keyboard.clear(&draft),
                    c.SDL_CONTROLLER_BUTTON_A => keyboard.activate(selection, &draft),
                    c.SDL_CONTROLLER_BUTTON_DPAD_LEFT => {
                        selection.moveHorizontal(-1);
                        repeat.begin(.left, c.SDL_GetTicks());
                    },
                    c.SDL_CONTROLLER_BUTTON_DPAD_RIGHT => {
                        selection.moveHorizontal(1);
                        repeat.begin(.right, c.SDL_GetTicks());
                    },
                    c.SDL_CONTROLLER_BUTTON_DPAD_UP => {
                        selection.moveVertical(-1);
                        repeat.begin(.up, c.SDL_GetTicks());
                    },
                    c.SDL_CONTROLLER_BUTTON_DPAD_DOWN => {
                        selection.moveVertical(1);
                        repeat.begin(.down, c.SDL_GetTicks());
                    },
                    c.SDL_CONTROLLER_BUTTON_START => {
                        if (c.go_controller_input_button_pressed(ui.controller, c.SDL_CONTROLLER_BUTTON_BACK) != 0)
                            continue;
                        if (library.matchingCount(view.titles, &ui.settings, view.collection, @ptrCast(&draft)) > 0) {
                            view.query = draft;
                            return 1;
                        }
                    },
                    else => {},
                }
                dirty = true;
            }
        }
        if (shouldStop(ui) or c.go_controller_input_exit_held(ui.controller, 1000) != 0) {
            ui.cancelled = true;
            return -1;
        }
        const direction = heldDirection(ui, &horizontal_latch, &vertical_latch);
        if (repeat.update(direction, c.SDL_GetTicks())) switch (direction) {
            .left => {
                selection.moveHorizontal(-1);
                dirty = true;
            },
            .right => {
                selection.moveHorizontal(1);
                dirty = true;
            },
            .up => {
                selection.moveVertical(-1);
                dirty = true;
            },
            .down => {
                selection.moveVertical(1);
                dirty = true;
            },
            .none => {},
        };
        if (dirty) {
            drawKeyboard(ui, view, &draft, selection);
            dirty = false;
        }
        c.SDL_Delay(16);
    }
}

fn appendCharacter(query: []u8, character: u8) void {
    const length = std.mem.indexOfScalar(u8, query, 0) orelse query.len;
    if (length + 1 >= query.len) return;
    query[length] = character;
    query[length + 1] = 0;
}

fn updateArtwork(ui: *Ui, view: *const library.View, state: *ArtworkSelection) ?*anyopaque {
    const title_index = view.selectedTitleIndex();
    if (!ui.settings.artwork_enabled or title_index == null) {
        if (state.enabled or state.title_index != title_index) ui.artwork.clear();
        state.* = .{ .title_index = title_index, .enabled = false };
        return null;
    }

    if (!state.enabled or state.title_index != title_index) {
        ui.artwork.clear();
        state.* = .{
            .title_index = title_index,
            .changed_at = c.SDL_GetTicks(),
            .enabled = true,
        };
    }

    const title = &view.titles[title_index.?];
    const product_id = library.productId(title);
    const url = library.artworkUrl(title);
    if (product_id.len == 0 or url.len == 0) return null;
    const now = c.SDL_GetTicks();
    if (state.requested_index == null and now -% state.changed_at >= 225) {
        ui.artwork.request(product_id, url);
        state.requested_index = title_index;
    }
    return ui.artwork.textureFor(ui.renderer, product_id);
}

fn pickTitle(ui: *Ui, titles: []const library.Title, requested: []const u8) c_int {
    if (titles.len == 0) return c.GO_HANDHELD_UI_PICK_CANCELLED;
    ui.cancelled = false;
    const indices = std.heap.c_allocator.alloc(usize, titles.len) catch return c.GO_HANDHELD_UI_PICK_CANCELLED;
    defer std.heap.c_allocator.free(indices);
    var view = library.View{ .titles = titles, .indices = indices };
    view.rebuild(&ui.settings, library.requestedTitle(titles, requested));
    var repeat = navigation.Repeater{};
    var horizontal_latch = navigation.AxisLatch{};
    var vertical_latch = navigation.AxisLatch{};
    var left_trigger_latched = false;
    var right_trigger_latched = false;
    var artwork_selection = ArtworkSelection{};
    var artwork_texture: ?*anyopaque = null;
    var dirty = true;

    while (true) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            c.go_controller_input_handle_event(ui.controller, &event);
            if (event.type == c.SDL_QUIT) {
                std.debug.print("Catalog closed by SDL quit\n", .{});
                ui.cancelled = true;
                return c.GO_HANDHELD_UI_PICK_CANCELLED;
            }
            if (event.type == c.SDL_KEYDOWN and event.key.keysym.sym == c.SDLK_ESCAPE) {
                std.debug.print("Catalog closed by keyboard escape\n", .{});
                ui.cancelled = true;
                return c.GO_HANDHELD_UI_PICK_CANCELLED;
            }
            if (event.type == c.SDL_CONTROLLERBUTTONDOWN and activeControllerEvent(ui, &event)) switch (semanticButton(ui, event.cbutton.button)) {
                c.SDL_CONTROLLER_BUTTON_A => if (view.selectedTitleIndex()) |title_index| {
                    return @intCast(title_index);
                },
                c.SDL_CONTROLLER_BUTTON_B => {
                    std.debug.print("Catalog closed by controller back\n", .{});
                    ui.cancelled = true;
                    return c.GO_HANDHELD_UI_PICK_CANCELLED;
                },
                c.SDL_CONTROLLER_BUTTON_X => {
                    const preserve = view.selectedTitleIndex();
                    const result = runSearchKeyboard(ui, &view);
                    if (result < 0) return c.GO_HANDHELD_UI_PICK_CANCELLED;
                    if (result > 0) {
                        view.rebuild(&ui.settings, preserve);
                    }
                    dirty = true;
                },
                c.SDL_CONTROLLER_BUTTON_Y => if (view.selectedTitleIndex()) |title_index| {
                    const product_id = library.productId(&titles[title_index]);
                    if (ui.settings.game(product_id)) |game| {
                        game.favorite = !game.favorite;
                        ui.settings.save() catch std.debug.print("Settings could not be saved\n", .{});
                        const old_selected = view.selected;
                        view.rebuild(&ui.settings, title_index);
                        if (view.count > 0 and view.selectedTitleIndex() != title_index)
                            view.selected = @min(old_selected, view.count - 1);
                        dirty = true;
                    }
                },
                c.SDL_CONTROLLER_BUTTON_DPAD_UP => {
                    view.move(-1);
                    repeat.begin(.up, c.SDL_GetTicks());
                    dirty = true;
                },
                c.SDL_CONTROLLER_BUTTON_DPAD_DOWN => {
                    view.move(1);
                    repeat.begin(.down, c.SDL_GetTicks());
                    dirty = true;
                },
                c.SDL_CONTROLLER_BUTTON_START => {
                    if (c.go_controller_input_button_pressed(ui.controller, c.SDL_CONTROLLER_BUTTON_BACK) != 0)
                        continue;
                    const result = settings_view.run(
                        ui.renderer,
                        ui.controller,
                        &ui.settings,
                        ui.stop_requested,
                        ui.stop_context,
                    );
                    if (result == .cancelled) {
                        ui.cancelled = true;
                        return c.GO_HANDHELD_UI_PICK_CANCELLED;
                    }
                    if (result == .sign_out) return c.GO_HANDHELD_UI_PICK_SIGN_OUT;
                    view.rebuild(&ui.settings, view.selectedTitleIndex());
                    dirty = true;
                },
                c.SDL_CONTROLLER_BUTTON_LEFTSHOULDER => {
                    view.switchCollection(&ui.settings, -1);
                    dirty = true;
                },
                c.SDL_CONTROLLER_BUTTON_RIGHTSHOULDER => {
                    view.switchCollection(&ui.settings, 1);
                    dirty = true;
                },
                else => {},
            };
            if (event.type == c.SDL_CONTROLLERAXISMOTION and activeControllerEvent(ui, &event)) {
                if (event.caxis.axis == c.SDL_CONTROLLER_AXIS_TRIGGERLEFT) {
                    if (event.caxis.value > 16000 and !left_trigger_latched) {
                        view.jumpInitial(-1);
                        left_trigger_latched = true;
                        dirty = true;
                    } else if (event.caxis.value < 8000) left_trigger_latched = false;
                } else if (event.caxis.axis == c.SDL_CONTROLLER_AXIS_TRIGGERRIGHT) {
                    if (event.caxis.value > 16000 and !right_trigger_latched) {
                        view.jumpInitial(1);
                        right_trigger_latched = true;
                        dirty = true;
                    } else if (event.caxis.value < 8000) right_trigger_latched = false;
                }
            }
        }
        if (shouldStop(ui)) {
            std.debug.print("Catalog closed by stop request\n", .{});
            ui.cancelled = true;
            return c.GO_HANDHELD_UI_PICK_CANCELLED;
        }
        if (c.go_controller_input_exit_held(ui.controller, 1000) != 0) {
            std.debug.print("Catalog closed by Select + Start\n", .{});
            ui.cancelled = true;
            return c.GO_HANDHELD_UI_PICK_CANCELLED;
        }
        const direction = heldDirection(ui, &horizontal_latch, &vertical_latch);
        if (repeat.update(direction, c.SDL_GetTicks())) {
            if (direction == .up) {
                view.move(-1);
                dirty = true;
            }
            if (direction == .down) {
                view.move(1);
                dirty = true;
            }
        }
        const next_artwork_texture = updateArtwork(ui, &view, &artwork_selection);
        if (next_artwork_texture != artwork_texture) {
            artwork_texture = next_artwork_texture;
            dirty = true;
        }
        if (dirty) {
            library.draw(ui.renderer, &view, &ui.settings, artwork_texture);
            dirty = false;
        }
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
    const settings_path = std.posix.getenv("GREENOVERCAST_SETTINGS_FILE");
    const stored = persistent.Store.init(if (settings_path) |path| path else null) catch {
        std.debug.print("Settings could not be loaded\n", .{});
        return null;
    };
    const ui = std.heap.c_allocator.create(Ui) catch return null;
    const preferred_dimensions = preferredStreamDimensions(renderer_handle);
    ui.* = .{
        .renderer = renderer_handle,
        .controller = controller_handle,
        .stop_requested = stop_requested,
        .stop_context = stop_context,
        .settings = stored,
        .stream_width = preferred_dimensions.width,
        .stream_height = preferred_dimensions.height,
    };
    const artwork_cache_path = std.posix.getenv("GREENOVERCAST_ARTWORK_CACHE_DIR");
    ui.artwork.start(if (artwork_cache_path) |path| path else null) catch |err|
        std.debug.print("Artwork loading disabled: {s}\n", .{@errorName(err)});
    c.go_controller_input_set_face_button_mode(
        controller_handle,
        if (stored.face_buttons == .system) c.GO_FACE_BUTTON_MODE_SYSTEM else c.GO_FACE_BUTTON_MODE_SWAPPED,
    );
    return ui;
}

pub export fn go_handheld_ui_destroy(ui: ?*Ui) void {
    const handle = ui orelse return;
    handle.artwork.stop();
    std.heap.c_allocator.destroy(handle);
}

pub export fn go_handheld_ui_draw_loading(ui: ?*Ui, heading: [*c]const u8, detail: [*c]const u8, action: c.GoHandheldUiAction) void {
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
    style.setColor(handle.renderer, style.background());
    _ = c.SDL_RenderClear(handle.renderer);
    style.setColor(handle.renderer, style.panel());
    var header = c.SDL_Rect{ .x = 0, .y = 0, .w = style.display_width, .h = 68 };
    var code_band = c.SDL_Rect{ .x = 0, .y = 228, .w = style.display_width, .h = 126 };
    var footer = c.SDL_Rect{ .x = 0, .y = 424, .w = style.display_width, .h = 56 };
    _ = c.SDL_RenderFillRect(handle.renderer, &header);
    _ = c.SDL_RenderFillRect(handle.renderer, &code_band);
    _ = c.SDL_RenderFillRect(handle.renderer, &footer);
    style.drawMark(handle.renderer);
    font.text(handle.renderer, 78, 12, 4, "GREENOVERCAST", style.bright());
    font.text(handle.renderer, 80, 46, 2, "XBOX SIGN IN", style.accent());
    const heading = "SIGN IN ON ANOTHER DEVICE";
    font.text(handle.renderer, @divTrunc(style.display_width - font.textWidth(heading, 3), 2), 96, 3, heading, style.bright());
    const instruction = "OPEN THIS ADDRESS ON YOUR PHONE";
    font.text(handle.renderer, @divTrunc(style.display_width - font.textWidth(instruction, 2), 2), 148, 2, instruction, style.muted());
    const address = "MICROSOFT.COM/LINK";
    font.text(handle.renderer, @divTrunc(style.display_width - font.textWidth(address, 3), 2), 180, 3, address, style.accent());
    const code_label = "ENTER THIS CODE";
    font.text(handle.renderer, @divTrunc(style.display_width - font.textWidth(code_label, 2), 2), 244, 2, code_label, style.muted());
    font.text(handle.renderer, @divTrunc(style.display_width - font.textWidth(user_code, 5), 2), 282, 5, user_code, style.bright());
    var state_buffer: [96]u8 = undefined;
    const state = std.fmt.bufPrintZ(&state_buffer, "{s}  {d}:{d:0>2}", .{
        pointerString(status).?, seconds_remaining / 60, seconds_remaining % 60,
    }) catch return;
    font.text(handle.renderer, @divTrunc(style.display_width - font.textWidth(state.ptr, 2), 2), 378, 2, state.ptr, style.accent());
    const prompts = [_]controls.Prompt{
        controls.Prompt.one(controls.face(handle.settings.face_buttons, .b), "CANCEL"),
    };
    controls.drawCenteredRow(handle.renderer, 439, &prompts, style.bright());
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

pub export fn go_handheld_ui_wait_for_retry(ui: ?*Ui, heading: [*c]const u8, detail: [*c]const u8) c_int {
    const handle = ui orelse return 0;
    drawLoading(handle, heading, detail, c.GO_HANDHELD_UI_ACTION_RETRY_BACK);
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
    if (titles == null or count <= 0) return c.GO_HANDHELD_UI_PICK_CANCELLED;
    const parsed_titles: [*]const library.Title = @ptrCast(@alignCast(titles));
    return pickTitle(ui orelse return c.GO_HANDHELD_UI_PICK_CANCELLED, parsed_titles[0..@intCast(count)], pointerString(requested) orelse "");
}

pub export fn go_handheld_ui_cancelled(ui: ?*const Ui) c_int {
    return @intFromBool(if (ui) |handle| handle.cancelled else false);
}

pub export fn go_handheld_ui_stream_width(ui: ?*const Ui) c_uint {
    return (ui orelse return 640).stream_width;
}

pub export fn go_handheld_ui_stream_height(ui: ?*const Ui) c_uint {
    return (ui orelse return 480).stream_height;
}
