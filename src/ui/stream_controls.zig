const controls = @import("control_icons.zig");
const settings = @import("persistent_settings.zig");
const style = @import("view_style.zig");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

pub fn draw(renderer_pointer: *anyopaque, face_buttons: settings.FaceButtonMode, mouse_mode: bool, x: f32, y: f32, source_width: c_int, source_height: c_int, show_hint: bool) void {
    const renderer: *c.SDL_Renderer = @ptrCast(@alignCast(renderer_pointer));
    var width: c_int = 0;
    var height: c_int = 0;
    if (c.SDL_GetRendererOutputSize(renderer, &width, &height) != 0 or width <= 0 or height <= 0) return;
    var old_x: f32 = 1;
    var old_y: f32 = 1;
    c.SDL_RenderGetScale(renderer, &old_x, &old_y);
    defer _ = c.SDL_RenderSetScale(renderer, old_x, old_y);
    _ = c.SDL_RenderSetScale(renderer, @as(f32, @floatFromInt(width)) / 640, @as(f32, @floatFromInt(height)) / 480);
    if (mouse_mode or show_hint) {
        var band = c.SDL_Rect{ .x = 0, .y = 0, .w = 640, .h = 28 };
        style.setColor(renderer, style.panel());
        _ = c.SDL_RenderFillRect(renderer, &band);
        controls.drawCenteredRow(renderer, 4, &.{controls.Prompt.two(.select, controls.face(face_buttons, .y), if (mouse_mode) "GAMEPAD MODE" else "MOUSE MODE")}, style.bright());
    }
    if (!mouse_mode) return;
    var band = c.SDL_Rect{ .x = 0, .y = 452, .w = 640, .h = 28 };
    style.setColor(renderer, style.panel());
    _ = c.SDL_RenderFillRect(renderer, &band);
    controls.drawCenteredRow(renderer, 456, &.{
        controls.Prompt.one(.left_stick, "MOVE"),
        controls.Prompt.one(controls.face(face_buttons, .a), "CLICK"),
        controls.Prompt.one(controls.face(face_buttons, .b), "RIGHT"),
        controls.Prompt.two(.left_bumper, .right_bumper, "SCROLL"),
    }, style.bright());
    if (source_width <= 0 or source_height <= 0) return;
    var w: f32 = 640;
    var h: f32 = 480;
    if (@as(i64, width) * source_height > @as(i64, height) * source_width)
        w = 640 * (@as(f32, @floatFromInt(height)) * @as(f32, @floatFromInt(source_width))) / (@as(f32, @floatFromInt(width)) * @as(f32, @floatFromInt(source_height)))
    else
        h = 480 * (@as(f32, @floatFromInt(width)) * @as(f32, @floatFromInt(source_height))) / (@as(f32, @floatFromInt(height)) * @as(f32, @floatFromInt(source_width)));
    const px: c_int = @intFromFloat((640 - w) / 2 + x * (w - 1));
    const py: c_int = @intFromFloat((480 - h) / 2 + y * (h - 1));
    style.setColor(renderer, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    for (0..14) |row| {
        var line = c.SDL_Rect{ .x = px, .y = py + @as(c_int, @intCast(row)), .w = @intCast(@min(row + 1, 9)), .h = 1 };
        _ = c.SDL_RenderFillRect(renderer, &line);
    }
    style.setColor(renderer, style.bright());
    for (2..12) |row| {
        var line = c.SDL_Rect{ .x = px + 1, .y = py + @as(c_int, @intCast(row)), .w = @intCast(@min(row - 1, 6)), .h = 1 };
        _ = c.SDL_RenderFillRect(renderer, &line);
    }
}
