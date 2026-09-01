const font = @import("pixel_font.zig");
const settings = @import("persistent_settings.zig");
const style = @import("view_style.zig");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

pub const Face = enum {
    a,
    b,
    x,
    y,
};

pub const Icon = enum {
    a,
    b,
    x,
    y,
    dpad,
    left_stick,
    right_stick,
    left_bumper,
    right_bumper,
    left_trigger,
    right_trigger,
    start,
    select,
    guide,
};

pub const Prompt = struct {
    icons: [2]Icon,
    icon_count: u8,
    label: [*:0]const u8,

    pub fn one(icon: Icon, label: [*:0]const u8) Prompt {
        return .{ .icons = .{ icon, icon }, .icon_count = 1, .label = label };
    }

    pub fn two(first: Icon, second: Icon, label: [*:0]const u8) Prompt {
        return .{ .icons = .{ first, second }, .icon_count = 2, .label = label };
    }
};

const label_scale = 2;
const icon_gap = 3;
const label_gap = 5;
const prompt_gap = 12;

pub fn face(mode: settings.FaceButtonMode, semantic: Face) Icon {
    return switch (mode) {
        .system => switch (semantic) {
            .a => .a,
            .b => .b,
            .x => .x,
            .y => .y,
        },
        .swapped => switch (semantic) {
            .a => .b,
            .b => .a,
            .x => .y,
            .y => .x,
        },
    };
}

pub fn rowWidth(prompts: []const Prompt) c_int {
    var width: c_int = 0;
    for (prompts, 0..) |prompt, index| {
        width += promptWidth(prompt);
        if (index + 1 < prompts.len) width += prompt_gap;
    }
    return width;
}

pub fn drawRow(
    renderer_pointer: *anyopaque,
    initial_x: c_int,
    y: c_int,
    prompts: []const Prompt,
    color: style.Color,
) void {
    var x = initial_x;
    for (prompts, 0..) |prompt, index| {
        drawPrompt(renderer_pointer, x, y, prompt, color);
        x += promptWidth(prompt);
        if (index + 1 < prompts.len) x += prompt_gap;
    }
}

pub fn drawCenteredRow(
    renderer_pointer: *anyopaque,
    y: c_int,
    prompts: []const Prompt,
    color: style.Color,
) void {
    drawRow(
        renderer_pointer,
        @divTrunc(style.display_width - rowWidth(prompts), 2),
        y,
        prompts,
        color,
    );
}

pub fn drawIcon(
    renderer_pointer: *anyopaque,
    x: c_int,
    y: c_int,
    icon: Icon,
    color: style.Color,
) void {
    const renderer: *c.SDL_Renderer = @ptrCast(@alignCast(renderer_pointer));
    style.setColor(renderer, color);
    switch (icon) {
        .a, .b, .x, .y => drawFace(renderer, x, y, icon, color),
        .dpad => drawDpad(renderer, x, y),
        .left_stick, .right_stick => drawStick(renderer, x, y, icon, color),
        .guide => drawGuide(renderer, x, y),
        else => drawPill(renderer, x, y, icon, color),
    }
}

pub fn drawSwapPair(
    renderer_pointer: *anyopaque,
    x: c_int,
    y: c_int,
    first: Icon,
    second: Icon,
    color: style.Color,
) void {
    const renderer: *c.SDL_Renderer = @ptrCast(@alignCast(renderer_pointer));
    drawIcon(renderer, x, y, first, color);
    drawIcon(renderer, x + 56, y, second, color);
    style.setColor(renderer, color);
    fill(renderer, x + 25, y + 8, 24, 2);
    fill(renderer, x + 25, y + 6, 2, 6);
    fill(renderer, x + 47, y + 6, 2, 6);
    fill(renderer, x + 27, y + 4, 2, 2);
    fill(renderer, x + 27, y + 12, 2, 2);
    fill(renderer, x + 45, y + 4, 2, 2);
    fill(renderer, x + 45, y + 12, 2, 2);
}

fn promptWidth(prompt: Prompt) c_int {
    var width: c_int = 0;
    for (0..prompt.icon_count) |index| {
        width += iconWidth(prompt.icons[index]);
        if (index + 1 < prompt.icon_count) width += icon_gap;
    }
    if (prompt.label[0] != 0) width += label_gap + font.textWidth(prompt.label, label_scale);
    return width;
}

fn drawPrompt(
    renderer_pointer: *anyopaque,
    initial_x: c_int,
    y: c_int,
    prompt: Prompt,
    color: style.Color,
) void {
    var x = initial_x;
    for (0..prompt.icon_count) |index| {
        const icon = prompt.icons[index];
        drawIcon(renderer_pointer, x, y, icon, color);
        x += iconWidth(icon);
        if (index + 1 < prompt.icon_count) x += icon_gap;
    }
    if (prompt.label[0] == 0) return;
    font.text(renderer_pointer, x + label_gap, y + 2, label_scale, prompt.label, color);
}

fn iconWidth(icon: Icon) c_int {
    return switch (icon) {
        .a, .b, .x, .y, .dpad, .left_stick, .right_stick, .guide => 18,
        .left_bumper, .right_bumper, .left_trigger, .right_trigger => 24,
        .start => 37,
        .select => 43,
    };
}

fn drawFace(
    renderer: *c.SDL_Renderer,
    x: c_int,
    y: c_int,
    icon: Icon,
    color: style.Color,
) void {
    drawCircle(renderer, x, y);
    font.text(renderer, x + 6, y + 5, 1, iconLabel(icon), color);
}

fn drawCircle(renderer: *c.SDL_Renderer, x: c_int, y: c_int) void {
    fill(renderer, x + 5, y, 8, 2);
    fill(renderer, x + 2, y + 2, 3, 3);
    fill(renderer, x + 13, y + 2, 3, 3);
    fill(renderer, x, y + 5, 2, 8);
    fill(renderer, x + 16, y + 5, 2, 8);
    fill(renderer, x + 2, y + 13, 3, 3);
    fill(renderer, x + 13, y + 13, 3, 3);
    fill(renderer, x + 5, y + 16, 8, 2);
}

fn drawDpad(renderer: *c.SDL_Renderer, x: c_int, y: c_int) void {
    fill(renderer, x + 6, y, 6, 6);
    fill(renderer, x, y + 6, 18, 6);
    fill(renderer, x + 6, y + 12, 6, 6);
}

fn drawStick(
    renderer: *c.SDL_Renderer,
    x: c_int,
    y: c_int,
    icon: Icon,
    color: style.Color,
) void {
    drawCircle(renderer, x, y);
    font.text(renderer, x + 4, y + 5, 1, iconLabel(icon), color);
}

fn drawGuide(renderer: *c.SDL_Renderer, x: c_int, y: c_int) void {
    drawCircle(renderer, x, y);
    fill(renderer, x + 5, y + 5, 3, 3);
    fill(renderer, x + 10, y + 5, 3, 3);
    fill(renderer, x + 7, y + 8, 4, 3);
    fill(renderer, x + 5, y + 11, 3, 3);
    fill(renderer, x + 10, y + 11, 3, 3);
}

fn drawPill(
    renderer: *c.SDL_Renderer,
    x: c_int,
    y: c_int,
    icon: Icon,
    color: style.Color,
) void {
    const width = iconWidth(icon);
    fill(renderer, x + 2, y, width - 4, 2);
    fill(renderer, x, y + 2, 2, 14);
    fill(renderer, x + width - 2, y + 2, 2, 14);
    fill(renderer, x + 2, y + 16, width - 4, 2);
    const label = iconLabel(icon);
    const width_label = font.textWidth(label, 1);
    font.text(renderer, x + @divTrunc(width - width_label, 2), y + 5, 1, label, color);
}

fn iconLabel(icon: Icon) [*:0]const u8 {
    return switch (icon) {
        .a => "A",
        .b => "B",
        .x => "X",
        .y => "Y",
        .left_stick => "L3",
        .right_stick => "R3",
        .left_bumper => "LB",
        .right_bumper => "RB",
        .left_trigger => "LT",
        .right_trigger => "RT",
        .start => "START",
        .select => "SELECT",
        .dpad, .guide => "",
    };
}

fn fill(renderer: *c.SDL_Renderer, x: c_int, y: c_int, width: c_int, height: c_int) void {
    var rect = c.SDL_Rect{ .x = x, .y = y, .w = width, .h = height };
    _ = c.SDL_RenderFillRect(renderer, &rect);
}

test "swapped face buttons describe the physical button" {
    try @import("std").testing.expectEqual(Icon.a, face(.system, .a));
    try @import("std").testing.expectEqual(Icon.b, face(.swapped, .a));
    try @import("std").testing.expectEqual(Icon.a, face(.swapped, .b));
    try @import("std").testing.expectEqual(Icon.y, face(.swapped, .x));
    try @import("std").testing.expectEqual(Icon.x, face(.swapped, .y));
}

test "library prompts fit the display" {
    const primary = [_]Prompt{
        Prompt.one(.a, "PLAY"),
        Prompt.one(.y, "FAVORITE"),
        Prompt.one(.x, "SEARCH"),
        Prompt.one(.b, "BACK"),
    };
    const secondary = [_]Prompt{
        Prompt.two(.left_bumper, .right_bumper, "TAB"),
        Prompt.two(.left_trigger, .right_trigger, "LETTER"),
        Prompt.one(.start, "SETTINGS"),
    };
    try @import("std").testing.expect(rowWidth(&primary) <= style.display_width - 32);
    try @import("std").testing.expect(rowWidth(&secondary) <= style.display_width - 32);
}
