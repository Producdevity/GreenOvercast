const controls = @import("control_icons.zig");
const font = @import("pixel_font.zig");
const settings = @import("persistent_settings.zig");
const style = @import("view_style.zig");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("controller.h");
});

pub const Result = enum(c_int) {
    cancelled = -1,
    xbox = 0,
    geforce_now = 1,
};

const StopRequested = ?*const fn (?*anyopaque) callconv(.c) c_int;

pub fn run(
    renderer_pointer: *anyopaque,
    controller_pointer: *anyopaque,
    face_buttons: settings.FaceButtonMode,
    stop_requested: StopRequested,
    stop_context: ?*anyopaque,
) Result {
    const renderer: *c.SDL_Renderer = @ptrCast(@alignCast(renderer_pointer));
    const controller: *c.GoControllerInput = @ptrCast(@alignCast(controller_pointer));
    var selection = Result.xbox;
    var dirty = true;
    var input_armed = false;
    const settle_started = c.SDL_GetTicks();
    while (true) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            c.go_controller_input_handle_event(controller, &event);
            if (event.type == c.SDL_QUIT) return .cancelled;
            if (!input_armed) continue;
            if (event.type == c.SDL_KEYDOWN) switch (event.key.keysym.sym) {
                c.SDLK_ESCAPE => return .cancelled,
                c.SDLK_UP, c.SDLK_DOWN => selection = toggle(selection),
                c.SDLK_RETURN => return selection,
                else => {},
            };
            if (event.type == c.SDL_KEYDOWN) dirty = true;
            if (event.type == c.SDL_CONTROLLERBUTTONDOWN and
                c.go_controller_input_event_is_active(controller, &event) != 0)
            {
                const button = c.go_controller_input_map_button(controller, event.cbutton.button);
                switch (button) {
                    c.SDL_CONTROLLER_BUTTON_B => return .cancelled,
                    c.SDL_CONTROLLER_BUTTON_A => return selection,
                    c.SDL_CONTROLLER_BUTTON_DPAD_UP, c.SDL_CONTROLLER_BUTTON_DPAD_DOWN => {
                        selection = toggle(selection);
                        dirty = true;
                    },
                    else => {},
                }
            }
        }
        if (!input_armed and c.SDL_GetTicks() -% settle_started >= 500 and
            inputNeutral(controller)) input_armed = true;
        if (shouldStop(stop_requested, stop_context) or
            c.go_controller_input_exit_held(controller, 1000) != 0) return .cancelled;
        if (dirty) {
            draw(renderer, face_buttons, selection);
            dirty = false;
        }
        c.SDL_Delay(16);
    }
}

fn inputNeutral(controller: *c.GoControllerInput) bool {
    const buttons = [_]c.SDL_GameControllerButton{
        c.SDL_CONTROLLER_BUTTON_A,
        c.SDL_CONTROLLER_BUTTON_B,
        c.SDL_CONTROLLER_BUTTON_DPAD_UP,
        c.SDL_CONTROLLER_BUTTON_DPAD_DOWN,
    };
    for (buttons) |button| {
        if (c.go_controller_input_button_pressed(controller, button) != 0) return false;
    }
    const keys = c.SDL_GetKeyboardState(null);
    if (keys[c.SDL_SCANCODE_RETURN] != 0 or
        keys[c.SDL_SCANCODE_ESCAPE] != 0 or
        keys[c.SDL_SCANCODE_UP] != 0 or
        keys[c.SDL_SCANCODE_DOWN] != 0) return false;
    return true;
}

fn toggle(current: Result) Result {
    return if (current == .xbox) .geforce_now else .xbox;
}

fn draw(
    renderer: *c.SDL_Renderer,
    face_buttons: settings.FaceButtonMode,
    selection: Result,
) void {
    style.setColor(renderer, style.background());
    _ = c.SDL_RenderClear(renderer);
    style.setColor(renderer, style.panel());
    var header = c.SDL_Rect{ .x = 0, .y = 0, .w = style.display_width, .h = 74 };
    var footer = c.SDL_Rect{ .x = 0, .y = 424, .w = style.display_width, .h = 56 };
    _ = c.SDL_RenderFillRect(renderer, &header);
    _ = c.SDL_RenderFillRect(renderer, &footer);
    style.drawMark(renderer);
    font.text(renderer, 78, 12, 4, "GREENOVERCAST", style.bright());
    font.text(renderer, 78, 50, 2, "CHOOSE A STREAMING SERVICE", style.accent());

    drawChoice(renderer, 118, "XBOX CLOUD GAMING", "GAME PASS LIBRARY", selection == .xbox);
    drawChoice(renderer, 242, "GEFORCE NOW", "PC GAME STREAMING", selection == .geforce_now);

    const prompts = [_]controls.Prompt{
        controls.Prompt.one(controls.face(face_buttons, .a), "SELECT"),
        controls.Prompt.one(.dpad, "MOVE"),
        controls.Prompt.one(controls.face(face_buttons, .b), "EXIT"),
    };
    controls.drawCenteredRow(renderer, 439, &prompts, style.bright());
    c.SDL_RenderPresent(renderer);
}

fn drawChoice(
    renderer: *c.SDL_Renderer,
    y: c_int,
    title: [*:0]const u8,
    detail: [*:0]const u8,
    selected: bool,
) void {
    style.setColor(renderer, if (selected) style.selection() else style.panel());
    var panel = c.SDL_Rect{ .x = 54, .y = y, .w = 532, .h = 96 };
    _ = c.SDL_RenderFillRect(renderer, &panel);
    if (selected) {
        style.setColor(renderer, style.accent());
        var bar = c.SDL_Rect{ .x = 54, .y = y, .w = 6, .h = 96 };
        _ = c.SDL_RenderFillRect(renderer, &bar);
    }
    font.text(renderer, 84, y + 18, 3, title, if (selected) style.bright() else style.muted());
    font.text(renderer, 84, y + 58, 2, detail, if (selected) style.accent() else style.muted());
}

fn shouldStop(callback: StopRequested, context: ?*anyopaque) bool {
    return if (callback) |stop| stop(context) != 0 else false;
}
