const std = @import("std");
const lish = @import("lish");

pub const Node = union(enum) {
    text: []const u8,
    char_string: []const u8,
    instant_string: []const u8,
    lish_inline: *lish.AstNode,
    lish_defer: *lish.AstNode,
    instant_lish: *lish.AstNode,
    char_lish: *lish.AstNode,
};

pub const Beat = []const Node;
pub const Scene = []const Beat;

pub const Script = struct {
    arena: std.heap.ArenaAllocator,
    scenes: std.StringHashMapUnmanaged(Scene),

    pub fn getScene(self: *const Script, name: []const u8) ?Scene {
        return self.scenes.get(name);
    }

    pub fn deinit(self: *Script) void {
        self.arena.deinit();
    }
};
