const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

pub const display_width = 640;
pub const display_height = 480;

pub const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub fn background() Color {
    return .{ .r = 7, .g = 23, .b = 18, .a = 255 };
}

pub fn panel() Color {
    return .{ .r = 16, .g = 38, .b = 30, .a = 255 };
}

pub fn selection() Color {
    return .{ .r = 45, .g = 105, .b = 71, .a = 255 };
}

pub fn bright() Color {
    return .{ .r = 230, .g = 239, .b = 232, .a = 255 };
}

pub fn muted() Color {
    return .{ .r = 148, .g = 169, .b = 158, .a = 255 };
}

pub fn accent() Color {
    return .{ .r = 121, .g = 175, .b = 198, .a = 255 };
}

pub fn warning() Color {
    return .{ .r = 224, .g = 137, .b = 105, .a = 255 };
}

pub fn setColor(renderer_pointer: *anyopaque, color: Color) void {
    const renderer: *c.SDL_Renderer = @ptrCast(@alignCast(renderer_pointer));
    _ = c.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a);
}

pub fn drawMark(renderer_pointer: *anyopaque) void {
    const renderer: *c.SDL_Renderer = @ptrCast(@alignCast(renderer_pointer));
    setColor(renderer, accent());
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
