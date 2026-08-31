const std = @import("std");
const guide_chord = @import("guide_chord.zig");
const wire = @import("wire_encoder.zig");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("controller.h");
});

const Input = struct {
    controller: ?*c.SDL_GameController = null,
    sequence: u32 = 0,
    exit_held_since: c.Uint32 = 0,
    face_button_mode: c.GoFaceButtonMode = c.GO_FACE_BUTTON_MODE_SYSTEM,
    guide_chord: guide_chord.State = .{},
    pressed_buttons: u32 = 0,
};

fn debug(comptime format: []const u8, args: anytype) void {
    if (std.posix.getenv("GREENOVERCAST_DEBUG") != null) std.debug.print(format, args);
}

fn activeControllerId(input: *const Input) c.SDL_JoystickID {
    const controller = input.controller orelse return -1;
    return c.SDL_JoystickInstanceID(c.SDL_GameControllerGetJoystick(controller));
}

fn controllerDeviceIndex(instance_id: c.SDL_JoystickID) ?c_int {
    var index: c_int = 0;
    while (index < c.SDL_NumJoysticks()) : (index += 1) {
        if (c.SDL_IsGameController(index) != 0 and
            c.SDL_JoystickGetDeviceInstanceID(index) == instance_id) return index;
    }
    return null;
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
    input.guide_chord.reset();
    input.pressed_buttons = 0;
    const name = c.SDL_GameControllerName(next);
    debug("Controller active: {s} ({d} btn, {d} axes)\n", .{
        if (name != null) std.mem.span(@as([*:0]const u8, @ptrCast(name))) else "unknown",
        c.SDL_JoystickNumButtons(joystick),
        c.SDL_JoystickNumAxes(joystick),
    });
}

fn button(input: *const Input, value: c.SDL_GameControllerButton) bool {
    const controller = input.controller orelse return false;
    const index: u5 = @intCast(value);
    return input.pressed_buttons & (@as(u32, 1) << index) != 0 or
        c.SDL_GameControllerGetButton(controller, value) != 0;
}

fn axis(input: *const Input, value: c.SDL_GameControllerAxis) i16 {
    const controller = input.controller orelse return 0;
    return c.SDL_GameControllerGetAxis(controller, value);
}

fn mappedButton(mode: c.GoFaceButtonMode, value: c.SDL_GameControllerButton) c.SDL_GameControllerButton {
    if (mode != c.GO_FACE_BUTTON_MODE_SWAPPED) return value;
    return switch (value) {
        c.SDL_CONTROLLER_BUTTON_A => c.SDL_CONTROLLER_BUTTON_B,
        c.SDL_CONTROLLER_BUTTON_B => c.SDL_CONTROLLER_BUTTON_A,
        c.SDL_CONTROLLER_BUTTON_X => c.SDL_CONTROLLER_BUTTON_Y,
        c.SDL_CONTROLLER_BUTTON_Y => c.SDL_CONTROLLER_BUTTON_X,
        else => value,
    };
}

fn semanticButtonPressed(input: *const Input, semantic: c.SDL_GameControllerButton) bool {
    return button(input, mappedButton(input.face_button_mode, semantic));
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
    if (current_event.type == c.SDL_CONTROLLERBUTTONDOWN and
        current_event.cbutton.which != activeControllerId(handle))
    {
        if (controllerDeviceIndex(current_event.cbutton.which)) |index| openController(handle, index);
    }
    if (current_event.type == c.SDL_CONTROLLERBUTTONDOWN or
        current_event.type == c.SDL_CONTROLLERBUTTONUP)
    {
        if (current_event.cbutton.which != activeControllerId(handle)) return;
        const index: u5 = @intCast(current_event.cbutton.button);
        const mask = @as(u32, 1) << index;
        if (current_event.type == c.SDL_CONTROLLERBUTTONDOWN)
            handle.pressed_buttons |= mask
        else
            handle.pressed_buttons &= ~mask;
        return;
    }
    if (current_event.type == c.SDL_CONTROLLERDEVICEADDED) {
        openController(handle, current_event.cdevice.which);
        return;
    }
    if (current_event.type != c.SDL_CONTROLLERDEVICEREMOVED or
        current_event.cdevice.which != activeControllerId(handle)) return;

    if (handle.controller) |controller| c.SDL_GameControllerClose(controller);
    handle.controller = null;
    handle.exit_held_since = 0;
    handle.guide_chord.reset();
    handle.pressed_buttons = 0;
    var index: c_int = 0;
    while (index < c.SDL_NumJoysticks()) : (index += 1) {
        if (c.SDL_IsGameController(index) != 0) {
            openController(handle, index);
            break;
        }
    }
}

pub export fn go_controller_input_event_is_active(
    input: ?*const Input,
    event: ?*const c.SDL_Event,
) c_int {
    const handle = input orelse return 0;
    const current_event = event orelse return 0;
    const instance_id = switch (current_event.type) {
        c.SDL_CONTROLLERBUTTONDOWN, c.SDL_CONTROLLERBUTTONUP => current_event.cbutton.which,
        c.SDL_CONTROLLERAXISMOTION => current_event.caxis.which,
        else => return 1,
    };
    return @intFromBool(instance_id == activeControllerId(handle));
}

pub export fn go_controller_input_set_face_button_mode(
    input: ?*Input,
    mode: c.GoFaceButtonMode,
) void {
    const handle = input orelse return;
    if (mode == c.GO_FACE_BUTTON_MODE_SYSTEM or mode == c.GO_FACE_BUTTON_MODE_SWAPPED)
        handle.face_button_mode = mode;
}

pub export fn go_controller_input_map_button(
    input: ?*const Input,
    physical_button: c.Uint8,
) c.SDL_GameControllerButton {
    const handle = input orelse return @intCast(physical_button);
    return mappedButton(handle.face_button_mode, @intCast(physical_button));
}

test "face button override preserves or swaps SDL semantics" {
    try std.testing.expectEqual(
        c.SDL_CONTROLLER_BUTTON_A,
        mappedButton(c.GO_FACE_BUTTON_MODE_SYSTEM, c.SDL_CONTROLLER_BUTTON_A),
    );
    try std.testing.expectEqual(
        c.SDL_CONTROLLER_BUTTON_B,
        mappedButton(c.GO_FACE_BUTTON_MODE_SWAPPED, c.SDL_CONTROLLER_BUTTON_A),
    );
    try std.testing.expectEqual(
        c.SDL_CONTROLLER_BUTTON_X,
        mappedButton(c.GO_FACE_BUTTON_MODE_SWAPPED, c.SDL_CONTROLLER_BUTTON_Y),
    );
    try std.testing.expectEqual(
        c.SDL_CONTROLLER_BUTTON_START,
        mappedButton(c.GO_FACE_BUTTON_MODE_SWAPPED, c.SDL_CONTROLLER_BUTTON_START),
    );
}

pub export fn go_controller_input_button_pressed(
    input: ?*const Input,
    semantic_button: c.SDL_GameControllerButton,
) c_int {
    return @intFromBool(semanticButtonPressed(input orelse return 0, semantic_button));
}

pub export fn go_controller_input_axis(
    input: ?*const Input,
    controller_axis: c.SDL_GameControllerAxis,
) c.Sint16 {
    return axis(input orelse return 0, controller_axis);
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
    if (semanticButtonPressed(handle, c.SDL_CONTROLLER_BUTTON_A)) source_buttons |= wire.SourceButton.a;
    if (semanticButtonPressed(handle, c.SDL_CONTROLLER_BUTTON_B)) source_buttons |= wire.SourceButton.b;
    if (semanticButtonPressed(handle, c.SDL_CONTROLLER_BUTTON_X)) source_buttons |= wire.SourceButton.x;
    if (semanticButtonPressed(handle, c.SDL_CONTROLLER_BUTTON_Y)) source_buttons |= wire.SourceButton.y;
    if (button(handle, c.SDL_CONTROLLER_BUTTON_LEFTSHOULDER)) source_buttons |= wire.SourceButton.left_shoulder;
    if (button(handle, c.SDL_CONTROLLER_BUTTON_RIGHTSHOULDER)) source_buttons |= wire.SourceButton.right_shoulder;
    if (button(handle, c.SDL_CONTROLLER_BUTTON_BACK)) source_buttons |= wire.SourceButton.back;
    if (button(handle, c.SDL_CONTROLLER_BUTTON_START)) source_buttons |= wire.SourceButton.start;
    if (button(handle, c.SDL_CONTROLLER_BUTTON_DPAD_UP)) source_buttons |= wire.SourceButton.dpad_up;
    if (button(handle, c.SDL_CONTROLLER_BUTTON_DPAD_DOWN)) source_buttons |= wire.SourceButton.dpad_down;
    if (button(handle, c.SDL_CONTROLLER_BUTTON_DPAD_LEFT)) source_buttons |= wire.SourceButton.dpad_left;
    if (button(handle, c.SDL_CONTROLLER_BUTTON_DPAD_RIGHT)) source_buttons |= wire.SourceButton.dpad_right;
    const left_stick = button(handle, c.SDL_CONTROLLER_BUTTON_LEFTSTICK);
    const right_stick = button(handle, c.SDL_CONTROLLER_BUTTON_RIGHTSTICK);
    const stick_buttons = handle.guide_chord.update(left_stick, right_stick);
    if (stick_buttons.left) source_buttons |= wire.SourceButton.left_stick;
    if (stick_buttons.right) source_buttons |= wire.SourceButton.right_stick;

    const raw_left_y = axis(handle, c.SDL_CONTROLLER_AXIS_LEFTY);
    const raw_right_y = axis(handle, c.SDL_CONTROLLER_AXIS_RIGHTY);
    const left_y = if (raw_left_y == std.math.minInt(i16)) std.math.maxInt(i16) else -raw_left_y;
    const right_y = if (raw_right_y == std.math.minInt(i16)) std.math.maxInt(i16) else -raw_right_y;
    wire.encodeGamepadRaw(
        bytes[0..wire.PACKET_SIZE],
        handle.sequence,
        0.0,
        wire.buttonMask(source_buttons),
        axis(handle, c.SDL_CONTROLLER_AXIS_LEFTX),
        left_y,
        axis(handle, c.SDL_CONTROLLER_AXIS_RIGHTX),
        right_y,
        trigger(handle, c.SDL_CONTROLLER_AXIS_TRIGGERLEFT),
        trigger(handle, c.SDL_CONTROLLER_AXIS_TRIGGERRIGHT),
    );
    handle.sequence +%= 1;
    return wire.PACKET_SIZE;
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
