const std = @import("std");
const c = @cImport({
    @cInclude("expat.h");
});

const maximum_bytes = 1024 * 1024;
const maximum_nodes = 8192;
const maximum_depth = 32;

pub const Node = struct {
    name: []const u8,
    parent: ?*Node,
    attributes: std.StringHashMapUnmanaged([]const u8) = .{},
    children: std.ArrayListUnmanaged(*Node) = .{},
    text: std.ArrayListUnmanaged(u8) = .{},

    pub fn child(self: *const Node, name: []const u8) ?*Node {
        for (self.children.items) |entry| if (std.mem.eql(u8, entry.name, name)) return entry;
        return null;
    }

    pub fn content(self: *const Node) []const u8 {
        return std.mem.trim(u8, self.text.items, " \t\r\n");
    }
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: *Node,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }
};

const Builder = struct {
    allocator: std.mem.Allocator,
    parser: c.XML_Parser,
    root: ?*Node = null,
    current: ?*Node = null,
    failure: ?anyerror = null,
    depth: usize = 0,
    nodes: usize = 0,
    text_bytes: usize = 0,

    fn fail(self: *Builder, err: anyerror) void {
        self.failure = err;
        _ = c.XML_StopParser(self.parser, c.XML_FALSE);
    }

    fn open(self: *Builder, name: []const u8, attributes: [*c]const [*c]const u8) !void {
        if (self.depth == maximum_depth or self.nodes == maximum_nodes) return error.XmlLimitExceeded;
        const node = try self.allocator.create(Node);
        node.* = .{ .name = try self.allocator.dupe(u8, name), .parent = self.current };
        var index: usize = 0;
        while (attributes[index] != null) : (index += 2) {
            if (index >= 128) return error.XmlLimitExceeded;
            const key = try self.allocator.dupe(u8, std.mem.span(attributes[index]));
            const value = try self.allocator.dupe(u8, std.mem.span(attributes[index + 1]));
            try node.attributes.put(self.allocator, key, value);
        }
        if (self.current) |parent| {
            try parent.children.append(self.allocator, node);
        } else {
            if (self.root != null) return error.InvalidXml;
            self.root = node;
        }
        self.current = node;
        self.depth += 1;
        self.nodes += 1;
    }
};

fn builder(context: ?*anyopaque) *Builder {
    return @ptrCast(@alignCast(context.?));
}

fn start(context: ?*anyopaque, name: [*c]const u8, attributes: [*c]const [*c]const u8) callconv(.c) void {
    const state = builder(context);
    state.open(std.mem.span(name), attributes) catch |err| state.fail(err);
}

fn end(context: ?*anyopaque, _: [*c]const u8) callconv(.c) void {
    const state = builder(context);
    if (state.current) |current| state.current = current.parent;
    if (state.depth > 0) state.depth -= 1;
}

fn text(context: ?*anyopaque, data: [*c]const u8, length: c_int) callconv(.c) void {
    const state = builder(context);
    const current = state.current orelse return;
    const size: usize = @intCast(length);
    if (size > maximum_bytes - state.text_bytes) {
        state.fail(error.XmlLimitExceeded);
        return;
    }
    state.text_bytes += size;
    current.text.appendSlice(state.allocator, data[0..size]) catch |err| state.fail(err);
}

fn doctype(context: ?*anyopaque, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: c_int) callconv(.c) void {
    builder(context).fail(error.XmlDoctypeForbidden);
}

pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Document {
    if (data.len > maximum_bytes) return error.XmlLimitExceeded;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const parser = c.XML_ParserCreate(null) orelse return error.OutOfMemory;
    defer c.XML_ParserFree(parser);
    var state = Builder{ .allocator = arena.allocator(), .parser = parser };
    c.XML_SetUserData(parser, &state);
    c.XML_SetElementHandler(parser, start, end);
    c.XML_SetCharacterDataHandler(parser, text);
    c.XML_SetStartDoctypeDeclHandler(parser, doctype);
    _ = c.XML_SetParamEntityParsing(parser, c.XML_PARAM_ENTITY_PARSING_NEVER);
    const status = c.XML_Parse(parser, data.ptr, @intCast(data.len), c.XML_TRUE);
    if (state.failure) |err| return err;
    if (status != c.XML_STATUS_OK or state.root == null) return error.InvalidXml;
    return .{ .arena = arena, .root = state.root.? };
}

test "empty VAST and CDATA/entity content are parsed, not searched as strings" {
    var empty = try parse(std.testing.allocator, "<?xml version=\"1.0\"?><VAST version=\"4.0\"/>");
    defer empty.deinit();
    try std.testing.expectEqualStrings("VAST", empty.root.name);
    try std.testing.expectEqual(@as(usize, 0), empty.root.children.items.len);
    var doc = try parse(std.testing.allocator, "<VAST><!-- <Ad/> --><Ad id=\"a&amp;b\"><Url> https://example.invalid/?a=1&amp;b=2<![CDATA[&c=3]]></Url></Ad></VAST>");
    defer doc.deinit();
    const ad = doc.root.child("Ad").?;
    try std.testing.expectEqualStrings("a&b", ad.attributes.get("id").?);
    try std.testing.expectEqualStrings("https://example.invalid/?a=1&b=2&c=3", ad.child("Url").?.content());
}

test "malformed XML and external or expanding entities cannot be accepted" {
    for ([_][]const u8{ "", "<VAST>", "<VAST><Ad/></wrong>", "<VAST/>garbage", "<VAST a=\"1\" a=\"2\"/>", "<VAST>&undefined;</VAST>" }) |input|
        try std.testing.expectError(error.InvalidXml, parse(std.testing.allocator, input));
    for ([_][]const u8{ "<!DOCTYPE VAST SYSTEM \"file:///etc/passwd\"><VAST/>", "<!DOCTYPE VAST [<!ENTITY a 'abc'>]><VAST>&a;</VAST>" }) |input|
        try std.testing.expectError(error.XmlDoctypeForbidden, parse(std.testing.allocator, input));
}

test "input and nesting limits are enforced with allocator cleanup" {
    const data = try std.testing.allocator.alloc(u8, maximum_bytes + 1);
    defer std.testing.allocator.free(data);
    try std.testing.expectError(error.XmlLimitExceeded, parse(std.testing.allocator, data));
    const nested = "<A>" ** (maximum_depth + 1) ++ "</A>" ** (maximum_depth + 1);
    try std.testing.expectError(error.XmlLimitExceeded, parse(std.testing.allocator, nested));
}
