const std = @import("std");
const navigation = @import("navigation_repeat.zig");
const font = @import("pixel_font.zig");
const settings = @import("persistent_settings.zig");
const style = @import("view_style.zig");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("controller.h");
});

pub const Result = enum {
    back,
    sign_out,
    cancelled,
};

const StopRequested = ?*const fn (?*anyopaque) callconv(.c) c_int;

const Row = enum {
    face_buttons,
    artwork,
    sign_out,
};

pub fn run(
    renderer_pointer: *anyopaque,
    controller_pointer: *anyopaque,
    store: *settings.Store,
    stop_requested: StopRequested,
    stop_context: ?*anyopaque,
) Result {
    const renderer: *c.SDL_Renderer = @ptrCast(@alignCast(renderer_pointer));
    const controller: *c.GoControllerInput = @ptrCast(@alignCast(controller_pointer));
    var selected = Row.face_buttons;
    var repeat = navigation.Repeater{};
    var axis_latch = navigation.AxisLatch{};
    var dirty = true;
    while (true) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            c.go_controller_input_handle_event(controller, &event);
            if (event.type == c.SDL_QUIT) return .cancelled;
            if (event.type == c.SDL_KEYDOWN) switch (event.key.keysym.sym) {
                c.SDLK_ESCAPE => return .back,
                c.SDLK_UP => selected = previousRow(selected),
                c.SDLK_DOWN => selected = nextRow(selected),
                c.SDLK_RETURN => if (activate(selected, controller, store)) {
                    const confirmation = confirmSignOut(renderer, controller, stop_requested, stop_context);
                    if (confirmation != .back) return confirmation;
                    dirty = true;
                },
                else => {},
            };
            if (event.type == c.SDL_KEYDOWN) dirty = true;
            if (event.type == c.SDL_CONTROLLERBUTTONDOWN and
                c.go_controller_input_event_is_active(controller, &event) != 0)
            {
                const button = c.go_controller_input_map_button(controller, event.cbutton.button);
                switch (button) {
                    c.SDL_CONTROLLER_BUTTON_B => return .back,
                    c.SDL_CONTROLLER_BUTTON_A => if (activate(selected, controller, store)) {
                        const confirmation = confirmSignOut(renderer, controller, stop_requested, stop_context);
                        if (confirmation != .back) return confirmation;
                        dirty = true;
                    },
                    c.SDL_CONTROLLER_BUTTON_DPAD_UP => {
                        selected = previousRow(selected);
                        repeat.begin(.up, c.SDL_GetTicks());
                    },
                    c.SDL_CONTROLLER_BUTTON_DPAD_DOWN => {
                        selected = nextRow(selected);
                        repeat.begin(.down, c.SDL_GetTicks());
                    },
                    c.SDL_CONTROLLER_BUTTON_DPAD_LEFT, c.SDL_CONTROLLER_BUTTON_DPAD_RIGHT => {
                        if (selected != .sign_out) _ = activate(selected, controller, store);
                    },
                    else => {},
                }
                dirty = true;
            }
        }
        if (shouldStop(stop_requested, stop_context) or
            c.go_controller_input_exit_held(controller, 1000) != 0) return .cancelled;

        const direction = heldDirection(controller, &axis_latch);
        if (repeat.update(direction, c.SDL_GetTicks())) {
            if (direction == .up) {
                selected = previousRow(selected);
                dirty = true;
            }
            if (direction == .down) {
                selected = nextRow(selected);
                dirty = true;
            }
        }
        if (dirty) {
            draw(renderer, store, selected);
            dirty = false;
        }
        c.SDL_Delay(16);
    }
}

fn activate(
    row: Row,
    controller: *c.GoControllerInput,
    store: *settings.Store,
) bool {
    switch (row) {
        .face_buttons => {
            store.face_buttons = if (store.face_buttons == .system) .swapped else .system;
            c.go_controller_input_set_face_button_mode(
                controller,
                if (store.face_buttons == .system) c.GO_FACE_BUTTON_MODE_SYSTEM else c.GO_FACE_BUTTON_MODE_SWAPPED,
            );
        },
        .artwork => store.artwork_enabled = !store.artwork_enabled,
        .sign_out => return true,
    }
    store.save() catch std.debug.print("Settings could not be saved\n", .{});
    return false;
}

fn previousRow(row: Row) Row {
    return switch (row) {
        .face_buttons => .sign_out,
        .artwork => .face_buttons,
        .sign_out => .artwork,
    };
}

fn nextRow(row: Row) Row {
    return switch (row) {
        .face_buttons => .artwork,
        .artwork => .sign_out,
        .sign_out => .face_buttons,
    };
}

fn heldDirection(controller: *c.GoControllerInput, latch: *navigation.AxisLatch) navigation.Direction {
    if (c.go_controller_input_button_pressed(controller, c.SDL_CONTROLLER_BUTTON_DPAD_UP) != 0) return .up;
    if (c.go_controller_input_button_pressed(controller, c.SDL_CONTROLLER_BUTTON_DPAD_DOWN) != 0) return .down;
    return switch (latch.update(c.go_controller_input_axis(controller, c.SDL_CONTROLLER_AXIS_LEFTY))) {
        -1 => .up,
        1 => .down,
        else => .none,
    };
}

fn draw(
    renderer: *c.SDL_Renderer,
    store: *const settings.Store,
    selected: Row,
) void {
    style.setColor(renderer, style.background());
    _ = c.SDL_RenderClear(renderer);
    style.setColor(renderer, style.panel());
    var header = c.SDL_Rect{ .x = 0, .y = 0, .w = style.display_width, .h = 68 };
    var footer = c.SDL_Rect{ .x = 0, .y = 424, .w = style.display_width, .h = 56 };
    _ = c.SDL_RenderFillRect(renderer, &header);
    _ = c.SDL_RenderFillRect(renderer, &footer);
    font.text(renderer, 18, 14, 4, "SETTINGS", style.bright());

    drawRow(renderer, 92, "FACE BUTTONS", if (store.face_buttons == .system) "SYSTEM" else "SWAPPED", selected == .face_buttons);
    drawRow(renderer, 148, "GAME ARTWORK", if (store.artwork_enabled) "ON" else "OFF", selected == .artwork);
    drawRow(renderer, 204, "ACCOUNT", "SIGN OUT", selected == .sign_out);

    drawMappingExplanation(renderer, store.face_buttons);
    font.text(renderer, 18, 340, 2, "USE SWAPPED ONLY IF BUTTONS ARE REVERSED", style.muted());
    font.text(renderer, 16, 438, 2, "A CHANGE   DPAD MOVE   B BACK", style.bright());
    c.SDL_RenderPresent(renderer);
}

fn drawRow(renderer: *c.SDL_Renderer, y: c_int, label: [*:0]const u8, value: [*:0]const u8, selected: bool) void {
    if (selected) {
        style.setColor(renderer, style.selection());
        var rect = c.SDL_Rect{ .x = 18, .y = y, .w = 344, .h = 42 };
        _ = c.SDL_RenderFillRect(renderer, &rect);
        style.setColor(renderer, style.accent());
        var bar = c.SDL_Rect{ .x = 18, .y = y, .w = 5, .h = 42 };
        _ = c.SDL_RenderFillRect(renderer, &bar);
    }
    font.text(renderer, 34, y + 6, 2, label, selectedColor(selected));
    const value_width = font.textWidth(value, 2);
    font.text(renderer, 348 - value_width, y + 22, 2, value, if (selected) style.accent() else style.muted());
}

fn selectedColor(selected: bool) style.Color {
    return if (selected) style.bright() else style.muted();
}

fn drawMappingExplanation(renderer: *c.SDL_Renderer, mode: settings.FaceButtonMode) void {
    font.text(renderer, 390, 96, 2, "INPUT MAPPING", style.muted());
    if (mode == .system) {
        font.text(renderer, 390, 142, 2, "SYSTEM", style.bright());
        font.text(renderer, 390, 180, 2, "USE CFW", style.muted());
        font.text(renderer, 390, 208, 2, "BUTTON MAP", style.muted());
    } else {
        font.text(renderer, 390, 142, 2, "SWAPPED", style.bright());
        font.text(renderer, 390, 180, 2, "A <-> B", style.accent());
        font.text(renderer, 390, 208, 2, "X <-> Y", style.accent());
    }
}

fn confirmSignOut(
    renderer: *c.SDL_Renderer,
    controller: *c.GoControllerInput,
    stop_requested: StopRequested,
    stop_context: ?*anyopaque,
) Result {
    style.setColor(renderer, style.background());
    _ = c.SDL_RenderClear(renderer);
    font.text(renderer, 164, 174, 4, "SIGN OUT?", style.bright());
    font.text(renderer, 110, 242, 2, "YOU WILL NEED TO LINK XBOX AGAIN", style.muted());
    font.text(renderer, 192, 324, 2, "A YES    B NO", style.accent());
    c.SDL_RenderPresent(renderer);
    while (true) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            c.go_controller_input_handle_event(controller, &event);
            if (event.type == c.SDL_QUIT) return .cancelled;
            if (event.type == c.SDL_KEYDOWN) switch (event.key.keysym.sym) {
                c.SDLK_RETURN => return .sign_out,
                c.SDLK_ESCAPE => return .back,
                else => {},
            };
            if (event.type == c.SDL_CONTROLLERBUTTONDOWN and
                c.go_controller_input_event_is_active(controller, &event) != 0)
            {
                const button = c.go_controller_input_map_button(controller, event.cbutton.button);
                if (button == c.SDL_CONTROLLER_BUTTON_A) return .sign_out;
                if (button == c.SDL_CONTROLLER_BUTTON_B) return .back;
            }
        }
        if (shouldStop(stop_requested, stop_context) or
            c.go_controller_input_exit_held(controller, 1000) != 0) return .cancelled;
        c.SDL_Delay(16);
    }
}

fn shouldStop(callback: StopRequested, context: ?*anyopaque) bool {
    return if (callback) |stop| stop(context) != 0 else false;
}
