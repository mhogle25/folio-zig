const std = @import("std");
const lish = @import("lish");

pub const Node = union(enum) {
    text: []const u8,
    instant_string: []const u8,
    lish_inline: *lish.AstNode,
    lish_defer: *lish.AstNode,
    instant_lish: *lish.AstNode,
    char_lish: *lish.AstNode,
};

pub const Section = []const Node;
pub const Chapter = []const Section;

pub const Script = struct {
    arena: std.heap.ArenaAllocator,
    chapters: std.StringHashMapUnmanaged(Chapter),

    pub fn getChapter(self: *const Script, name: []const u8) ?Chapter {
        return self.chapters.get(name);
    }

    pub fn deinit(self: *Script) void {
        self.arena.deinit();
    }
};
