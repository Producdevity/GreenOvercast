const font = @import("pixel_font.zig");
const style = @import("view_style.zig");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

pub const Provider = enum {
    xbox,
    geforce_now,
};

// Bootstrap Icons, rasterized at 24x24; source revision in vendor/manifest.lock.
const xbox_mark = [24]u24{
    0x007e00, 0x01ff80, 0x003c00, 0x000000, 0x1c0038, 0x3f007c,
    0x7f00fe, 0x7f00fe, 0x7e007e, 0xfe003f, 0xfc183f, 0xf83c1f,
    0xf87e1f, 0xf0ff0f, 0xf1ff8f, 0x63ffc6, 0x67ffe6, 0x67ffe2,
    0x0ffff0, 0x0ffff0, 0x0ffff0, 0x07ffe0, 0x03ffc0, 0x007e00,
};

const nvidia_mark = [24]u24{
    0x000000, 0x000000, 0x000000, 0x007fff, 0x007fff, 0x007fff,
    0x0187ff, 0x0e71ff, 0x187cff, 0x73867f, 0xe6473f, 0xe4667f,
    0x667cef, 0x3379c7, 0x198787, 0x0c7e0f, 0x07707f, 0x0187ff,
    0x007fff, 0x007fff, 0x007fff, 0x000000, 0x000000, 0x000000,
};

pub fn draw(renderer_pointer: *anyopaque, provider: Provider) void {
    const renderer: *c.SDL_Renderer = @ptrCast(@alignCast(renderer_pointer));
    const label: [*:0]const u8 = if (provider == .xbox) "XBOX" else "GFN";
    const label_width = font.textWidth(label, 2);
    const width = 32 + label_width;
    const x = style.display_width - width - 16;

    drawMark(renderer, provider, x, 15);
    font.text(renderer, x + 32, 20, 2, label, style.bright());
}

fn drawMark(renderer: *c.SDL_Renderer, provider: Provider, x: c_int, y: c_int) void {
    const rows = if (provider == .xbox) &xbox_mark else &nvidia_mark;
    style.setColor(renderer, if (provider == .xbox) style.bright() else .{ .r = 118, .g = 185, .b = 0, .a = 255 });
    for (rows, 0..) |row, dy| {
        var column: u5 = 0;
        while (column < 24) {
            if (row & (@as(u24, 1) << (23 - column)) == 0) {
                column += 1;
                continue;
            }
            const start = column;
            while (column < 24 and row & (@as(u24, 1) << (23 - column)) != 0) : (column += 1) {}
            var rect = c.SDL_Rect{ .x = x + start, .y = y + @as(c_int, @intCast(dy)), .w = column - start, .h = 1 };
            _ = c.SDL_RenderFillRect(renderer, &rect);
        }
    }
}
