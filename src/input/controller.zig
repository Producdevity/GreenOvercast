const std = @import("std");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("wire_encoder.h");
});

const Input = struct {
    controller: ?*c.SDL_GameController = null,
    sequence: u32 = 0,
    exit_held_since: c.Uint32 = 0,
};

fn debug(comptime format: []const u8, args: anytype) void {
    if (std.posix.getenv("GREENOVERCAST_DEBUG") != null) std.debug.print(format, args);
}

fn activeControllerId(input: *const Input) c.SDL_JoystickID {
    const controller = input.controller orelse return -1;
    return c.SDL_JoystickInstanceID(c.SDL_GameControllerGetJoystick(controller));
}

fn openController(input: *Input, device_index: c_int) void {
    if (c.SDL_IsGameController(device_index) == 0) return;
    const next = c.SDL_GameControllerOpen(device_index) orelse return;
    const joystick = c.SDL_GameControllerGetJoystick(next);
    const next_id = c.SDL_JoystickInstanceID(joystick);
    if (next_id == activeControllerId(input)) {
        c.SDL_GameControllerClose(next);
        return;
    }
    if (input.controller) |controller| c.SDL_GameControllerClose(controller);
    input.controller = next;
    input.exit_held_since = 0;
    const name = c.SDL_GameControllerName(next);
    debug("Controller active: {s} ({d} btn, {d} axes)\n", .{
        if (name != null) std.mem.span(@as([*:0]const u8, @ptrCast(name))) else "unknown",
        c.SDL_JoystickNumButtons(joystick),
        c.SDL_JoystickNumAxes(joystick),
    });
}

fn button(input: *const Input, value: c.SDL_GameControllerButton) bool {
    const controller = input.controller orelse return false;
    return c.SDL_GameControllerGetButton(controller, value) != 0;
}

fn axis(input: *const Input, value: c.SDL_GameControllerAxis) i16 {
    const controller = input.controller orelse return 0;
    return c.SDL_GameControllerGetAxis(controller, value);
}

fn trigger(input: *const Input, value: c.SDL_GameControllerAxis) u16 {
    const position = axis(input, value);
    if (position <= 0) return 0;
    return @intCast(@as(u32, @intCast(position)) * std.math.maxInt(u16) / std.math.maxInt(i16));
}

pub export fn go_controller_input_create() ?*Input {
    const input = std.heap.c_allocator.create(Input) catch return null;
    input.* = .{};
    var index: c_int = 0;
    while (index < c.SDL_NumJoysticks()) : (index += 1) {
        if (c.SDL_IsGameController(index) != 0) {
            openController(input, index);
            break;
        }
    }
    if (input.controller == null) {
        if (c.SDL_NumJoysticks() > 0) {
            const name = c.SDL_JoystickNameForIndex(0);
            std.debug.print("Controller mapping unavailable: {s}\n", .{
                if (name != null) std.mem.span(@as([*:0]const u8, @ptrCast(name))) else "unknown",
            });
        } else {
            debug("No controller detected\n", .{});
        }
    }
    return input;
}

pub export fn go_controller_input_destroy(input: ?*Input) void {
    const handle = input orelse return;
    if (handle.controller) |controller| c.SDL_GameControllerClose(controller);
    std.heap.c_allocator.destroy(handle);
}

pub export fn go_controller_input_handle_event(input: ?*Input, event: ?*const c.SDL_Event) void {
    const handle = input orelse return;
    const current_event = event orelse return;
    if (current_event.type == c.SDL_CONTROLLERDEVICEADDED) {
        openController(handle, current_event.cdevice.which);
        return;
    }
    if (current_event.type != c.SDL_CONTROLLERDEVICEREMOVED or
        current_event.cdevice.which != activeControllerId(handle)) return;

    if (handle.controller) |controller| c.SDL_GameControllerClose(controller);
    handle.controller = null;
    handle.exit_held_since = 0;
    var index: c_int = 0;
    while (index < c.SDL_NumJoysticks()) : (index += 1) {
        if (c.SDL_IsGameController(index) != 0) {
            openController(handle, index);
            break;
        }
    }
}

pub export fn go_controller_input_encode_metadata(
    input: ?*Input,
    output: ?[*]u8,
    capacity: usize,
) usize {
    const handle = input orelse return 0;
    const bytes = output orelse return 0;
    if (capacity < 15) return 0;
    const sequence = handle.sequence;
    handle.sequence +%= 1;
    @memset(bytes[0..15], 0);
    bytes[0] = 0x08;
    std.mem.writeInt(u32, bytes[2..6], sequence, .little);
    return 15;
}

pub export fn go_controller_input_encode(
    input: ?*Input,
    output: ?[*]u8,
    capacity: usize,
) usize {
    const handle = input orelse return 0;
    if (handle.controller == null) return 0;
    const bytes = output orelse return 0;
    if (capacity < 38) return 0;

    var source_buttons: u32 = 0;
    if (button(handle, c.SDL_CONTROLLER_BUTTON_A)) source_buttons |= c.GO_CONTROLLER_A;
    if (button(handle, c.SDL_CONTROLLER_BUTTON_B)) source_buttons |= c.GO_CONTROLLER_B;
    if (button(handle, c.SDL_CONTROLLER_BUTTON_X)) source_buttons |= c.GO_CONTROLLER_X;
    if (button(handle, c.SDL_CONTROLLER_BUTTON_Y)) source_buttons |= c.GO_CONTROLLER_Y;
    if (button(handle, c.SDL_CONTROLLER_BUTTON_LEFTSHOULDER)) source_buttons |= c.GO_CONTROLLER_LEFT_SHOULDER;
    if (button(handle, c.SDL_CONTROLLER_BUTTON_RIGHTSHOULDER)) source_buttons |= c.GO_CONTROLLER_RIGHT_SHOULDER;
    if (button(handle, c.SDL_CONTROLLER_BUTTON_BACK)) source_buttons |= c.GO_CONTROLLER_BACK;
    if (button(handle, c.SDL_CONTROLLER_BUTTON_START)) source_buttons |= c.GO_CONTROLLER_START;
    if (button(handle, c.SDL_CONTROLLER_BUTTON_DPAD_UP)) source_buttons |= c.GO_CONTROLLER_DPAD_UP;
    if (button(handle, c.SDL_CONTROLLER_BUTTON_DPAD_DOWN)) source_buttons |= c.GO_CONTROLLER_DPAD_DOWN;
    if (button(handle, c.SDL_CONTROLLER_BUTTON_DPAD_LEFT)) source_buttons |= c.GO_CONTROLLER_DPAD_LEFT;
    if (button(handle, c.SDL_CONTROLLER_BUTTON_DPAD_RIGHT)) source_buttons |= c.GO_CONTROLLER_DPAD_RIGHT;
    if (button(handle, c.SDL_CONTROLLER_BUTTON_LEFTSTICK)) source_buttons |= c.GO_CONTROLLER_LEFT_STICK;
    if (button(handle, c.SDL_CONTROLLER_BUTTON_RIGHTSTICK)) source_buttons |= c.GO_CONTROLLER_RIGHT_STICK;

    const raw_left_y = axis(handle, c.SDL_CONTROLLER_AXIS_LEFTY);
    const raw_right_y = axis(handle, c.SDL_CONTROLLER_AXIS_RIGHTY);
    const left_y = if (raw_left_y == std.math.minInt(i16)) std.math.maxInt(i16) else -raw_left_y;
    const right_y = if (raw_right_y == std.math.minInt(i16)) std.math.maxInt(i16) else -raw_right_y;
    c.go_xcloud_encode_gamepad(
        bytes,
        handle.sequence,
        0.0,
        c.go_xcloud_button_mask(source_buttons),
        axis(handle, c.SDL_CONTROLLER_AXIS_LEFTX),
        left_y,
        axis(handle, c.SDL_CONTROLLER_AXIS_RIGHTX),
        right_y,
        trigger(handle, c.SDL_CONTROLLER_AXIS_TRIGGERLEFT),
        trigger(handle, c.SDL_CONTROLLER_AXIS_TRIGGERRIGHT),
    );
    handle.sequence +%= 1;
    return 38;
}

pub export fn go_controller_input_exit_held(
    input: ?*Input,
    minimum_milliseconds: u32,
) c_int {
    const handle = input orelse return 0;
    if (handle.controller == null or !button(handle, c.SDL_CONTROLLER_BUTTON_BACK) or
        !button(handle, c.SDL_CONTROLLER_BUTTON_START))
    {
        handle.exit_held_since = 0;
        return 0;
    }
    const now = c.SDL_GetTicks();
    if (handle.exit_held_since == 0) handle.exit_held_since = now;
    return @intFromBool(now -% handle.exit_held_since >= minimum_milliseconds);
}
