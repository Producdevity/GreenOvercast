const std = @import("std");

pub const Action = union(enum) {
    character: u8,
    space,
};

pub const Key = struct {
    label: []const u8,
    action: Action,
    width_units: u8 = 1,
};

pub const unit_width = 48;
pub const gap_width = 5;

const row_letters_1 = [_]Key{
    .{ .label = "Q", .action = .{ .character = 'Q' } },
    .{ .label = "W", .action = .{ .character = 'W' } },
    .{ .label = "E", .action = .{ .character = 'E' } },
    .{ .label = "R", .action = .{ .character = 'R' } },
    .{ .label = "T", .action = .{ .character = 'T' } },
    .{ .label = "Y", .action = .{ .character = 'Y' } },
    .{ .label = "U", .action = .{ .character = 'U' } },
    .{ .label = "I", .action = .{ .character = 'I' } },
    .{ .label = "O", .action = .{ .character = 'O' } },
    .{ .label = "P", .action = .{ .character = 'P' } },
};

const row_letters_2 = [_]Key{
    .{ .label = "A", .action = .{ .character = 'A' } },
    .{ .label = "S", .action = .{ .character = 'S' } },
    .{ .label = "D", .action = .{ .character = 'D' } },
    .{ .label = "F", .action = .{ .character = 'F' } },
    .{ .label = "G", .action = .{ .character = 'G' } },
    .{ .label = "H", .action = .{ .character = 'H' } },
    .{ .label = "J", .action = .{ .character = 'J' } },
    .{ .label = "K", .action = .{ .character = 'K' } },
    .{ .label = "L", .action = .{ .character = 'L' } },
};

const row_letters_3 = [_]Key{
    .{ .label = "Z", .action = .{ .character = 'Z' } },
    .{ .label = "X", .action = .{ .character = 'X' } },
    .{ .label = "C", .action = .{ .character = 'C' } },
    .{ .label = "V", .action = .{ .character = 'V' } },
    .{ .label = "B", .action = .{ .character = 'B' } },
    .{ .label = "N", .action = .{ .character = 'N' } },
    .{ .label = "M", .action = .{ .character = 'M' } },
    .{ .label = "SPACE", .action = .space, .width_units = 3 },
};

const row_numbers = [_]Key{
    .{ .label = "1", .action = .{ .character = '1' } },
    .{ .label = "2", .action = .{ .character = '2' } },
    .{ .label = "3", .action = .{ .character = '3' } },
    .{ .label = "4", .action = .{ .character = '4' } },
    .{ .label = "5", .action = .{ .character = '5' } },
    .{ .label = "6", .action = .{ .character = '6' } },
    .{ .label = "7", .action = .{ .character = '7' } },
    .{ .label = "8", .action = .{ .character = '8' } },
    .{ .label = "9", .action = .{ .character = '9' } },
    .{ .label = "0", .action = .{ .character = '0' } },
};

pub const rows = [_][]const Key{
    &row_letters_1,
    &row_letters_2,
    &row_letters_3,
    &row_numbers,
};

pub const Selection = struct {
    row: usize = 0,
    column: usize = 0,

    pub fn moveHorizontal(self: *Selection, direction: i8) void {
        const count = rows[self.row].len;
        if (direction < 0)
            self.column = if (self.column == 0) count - 1 else self.column - 1
        else
            self.column = (self.column + 1) % count;
    }

    pub fn moveVertical(self: *Selection, direction: i8) void {
        const current_center = keyCenter(self.row, self.column);
        if (direction < 0)
            self.row = if (self.row == 0) rows.len - 1 else self.row - 1
        else
            self.row = (self.row + 1) % rows.len;
        self.column = nearestColumn(self.row, current_center);
    }

    pub fn key(self: Selection) Key {
        return rows[self.row][self.column];
    }
};

fn rowWidth(row: usize) i32 {
    var width: i32 = 0;
    for (rows[row], 0..) |key, index| {
        width += @as(i32, key.width_units) * unit_width;
        if (index + 1 < rows[row].len) width += gap_width;
    }
    return width;
}

fn keyCenter(row: usize, column: usize) i32 {
    var offset: i32 = 0;
    for (rows[row][0..column]) |key|
        offset += @as(i32, key.width_units) * unit_width + gap_width;
    const width = @as(i32, rows[row][column].width_units) * unit_width;
    return -rowWidth(row) + 2 * offset + width;
}

fn nearestColumn(row: usize, center: i32) usize {
    var nearest: usize = 0;
    var nearest_distance = @abs(keyCenter(row, 0) - center);
    for (1..rows[row].len) |column| {
        const distance = @abs(keyCenter(row, column) - center);
        if (distance < nearest_distance) {
            nearest = column;
            nearest_distance = distance;
        }
    }
    return nearest;
}

pub fn activate(selection: Selection, query: []u8) void {
    const length = std.mem.indexOfScalar(u8, query, 0) orelse query.len;
    if (length + 1 >= query.len) return;
    query[length] = switch (selection.key().action) {
        .character => |character| character,
        .space => ' ',
    };
    query[length + 1] = 0;
}

pub fn erase(query: []u8) void {
    const length = std.mem.indexOfScalar(u8, query, 0) orelse query.len;
    if (length > 0) query[length - 1] = 0;
}

pub fn clear(query: []u8) void {
    @memset(query, 0);
}

test "space key inserts a space" {
    var query = [_]u8{0} ** 16;
    @memcpy(query[0..6], "HOLLOW");
    var selection = Selection{ .row = 2, .column = 7 };
    activate(selection, &query);
    selection = .{ .row = 2, .column = 5 };
    activate(selection, &query);
    try std.testing.expectEqualStrings("HOLLOW N", std.mem.sliceTo(&query, 0));
}

test "selection wraps and stays within the next row" {
    var selection = Selection{};
    selection.moveHorizontal(-1);
    try std.testing.expectEqual(@as(usize, 9), selection.column);
    selection.moveVertical(1);
    try std.testing.expectEqual(@as(usize, 8), selection.column);
    selection.moveVertical(1);
    try std.testing.expectEqual(@as(usize, 7), selection.column);
}

test "vertical movement follows the visual center of the space key" {
    var selection = Selection{ .row = 2, .column = 7 };
    selection.moveVertical(1);
    try std.testing.expectEqual(@as(usize, 3), selection.row);
    try std.testing.expectEqual(@as(usize, 8), selection.column);
    selection.moveVertical(-1);
    try std.testing.expectEqual(@as(usize, 2), selection.row);
    try std.testing.expectEqual(@as(usize, 7), selection.column);
}
