const std = @import("std");
const tok = @import("token.zig");
const node = @import("node.zig");
const lish = @import("lish");

const Token = tok.Token;
const TokenType = tok.TokenType;
const Node = node.Node;
const Section = node.Section;
const Chapter = node.Chapter;
const Script = node.Script;

pub const ParseError = error{
    MissingMainChapter,
};

const MAIN_CHAPTER = "main";

pub fn parse(tokens: []const Token, allocator: std.mem.Allocator) !Script {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    var chapters: std.StringHashMapUnmanaged(Chapter) = .{};
    var current_name: ?[]const u8 = null;
    var current_sections: std.ArrayListUnmanaged(Section) = .{};
    var current_nodes: std.ArrayListUnmanaged(Node) = .{};
    // Tracks whether the current section was explicitly opened by a section break.
    // An explicitly opened section is always emitted, even if empty, because the
    // author intentionally placed ;; there.
    var explicit_section: bool = false;

    for (tokens) |token| {
        switch (token.token_type) {
            .chapter_decl => {
                try finalizeChapter(arena_alloc, &chapters, current_name, &current_sections, &current_nodes, &explicit_section);
                current_name = token.value;
            },
            .section_break => {
                const section = try closeSectionNodes(arena_alloc, &current_nodes);
                try current_sections.append(arena_alloc, section);
                explicit_section = true;
            },
            .text => try current_nodes.append(arena_alloc, .{ .text = token.value }),
            .instant_string => try current_nodes.append(arena_alloc, .{ .instant_string = token.value }),
            .lish_inline => {
                const ast_node = try lish.parser.parse(arena_alloc, token.value);
                try current_nodes.append(arena_alloc, .{ .lish_inline = ast_node });
            },
            .lish_defer => {
                const ast_node = try lish.parser.parse(arena_alloc, token.value);
                try current_nodes.append(arena_alloc, .{ .lish_defer = ast_node });
            },
            .instant_lish => {
                const ast_node = try lish.parser.parse(arena_alloc, token.value);
                try current_nodes.append(arena_alloc, .{ .instant_lish = ast_node });
            },
            .char_lish => {
                const ast_node = try lish.parser.parse(arena_alloc, token.value);
                try current_nodes.append(arena_alloc, .{ .char_lish = ast_node });
            },
            .eof => {
                try finalizeChapter(arena_alloc, &chapters, current_name, &current_sections, &current_nodes, &explicit_section);
                break;
            },
        }
    }

    if (!chapters.contains(MAIN_CHAPTER)) return error.MissingMainChapter;

    return Script{
        .arena = arena,
        .chapters = chapters,
    };
}

/// Close the current node list into a section, trimming leading and trailing
/// newline-only text nodes. The returned section may be empty.
fn closeSectionNodes(allocator: std.mem.Allocator, nodes: *std.ArrayListUnmanaged(Node)) !Section {
    var start: usize = 0;
    var end: usize = nodes.items.len;
    while (start < end and isNewlineText(nodes.items[start])) start += 1;
    while (end > start and isNewlineText(nodes.items[end - 1])) end -= 1;
    const section = try allocator.dupe(Node, nodes.items[start..end]);
    nodes.clearRetainingCapacity();
    return section;
}

fn isNewlineText(n: Node) bool {
    return n == .text and n.text.len == 1 and n.text[0] == tok.NEWLINE;
}

fn finalizeChapter(
    allocator: std.mem.Allocator,
    chapters: *std.StringHashMapUnmanaged(Chapter),
    name: ?[]const u8,
    sections: *std.ArrayListUnmanaged(Section),
    nodes: *std.ArrayListUnmanaged(Node),
    explicit_section: *bool,
) !void {
    const chapter_name = name orelse {
        // Discard any content appearing before the first chapter declaration.
        nodes.clearRetainingCapacity();
        sections.clearRetainingCapacity();
        explicit_section.* = false;
        return;
    };
    // Add a final section if: there is non-newline content, OR the section was
    // explicitly opened by a ;; (in which case it's intentionally empty).
    const section = try closeSectionNodes(allocator, nodes);
    if (section.len > 0 or explicit_section.*) {
        try sections.append(allocator, section);
    }
    explicit_section.* = false;
    const chapter = try sections.toOwnedSlice(allocator);
    try chapters.put(allocator, chapter_name, chapter);
}

// ── Tests ──

const lexer = @import("lexer.zig");

fn parseSource(source: []const u8, allocator: std.mem.Allocator) !Script {
    const tokens = try lexer.tokenize(source, allocator);
    defer allocator.free(tokens);
    return parse(tokens, allocator);
}

test "missing main chapter is an error" {
    try std.testing.expectError(
        error.MissingMainChapter,
        parseSource("::intro\nHello.", std.testing.allocator),
    );
}

test "empty main chapter" {
    var script = try parseSource("::main", std.testing.allocator);
    defer script.deinit();
    const chapter = script.getChapter("main").?;
    try std.testing.expectEqual(@as(usize, 0), chapter.len);
}

test "single section no section break" {
    var script = try parseSource("::main\nHello.", std.testing.allocator);
    defer script.deinit();
    const chapter = script.getChapter("main").?;
    try std.testing.expectEqual(@as(usize, 1), chapter.len);
    try std.testing.expectEqualStrings("Hello.", chapter[0][0].text);
}

test "section break creates two sections" {
    var script = try parseSource("::main\nHello.\n;;\nWorld.", std.testing.allocator);
    defer script.deinit();
    const chapter = script.getChapter("main").?;
    try std.testing.expectEqual(@as(usize, 2), chapter.len);
    try std.testing.expectEqualStrings("Hello.", chapter[0][0].text);
    try std.testing.expectEqualStrings("World.", chapter[1][0].text);
}

test "trailing section break creates empty final section" {
    var script = try parseSource("::main\nHello.\n;;", std.testing.allocator);
    defer script.deinit();
    const chapter = script.getChapter("main").?;
    try std.testing.expectEqual(@as(usize, 2), chapter.len);
    try std.testing.expectEqual(@as(usize, 1), chapter[0].len);
    try std.testing.expectEqual(@as(usize, 0), chapter[1].len);
}

test "multiple chapters" {
    const source =
        \\::main
        \\Hello.
        \\::shop
        \\Welcome.
    ;
    var script = try parseSource(source, std.testing.allocator);
    defer script.deinit();
    try std.testing.expect(script.getChapter("main") != null);
    try std.testing.expect(script.getChapter("shop") != null);
}

test "chapter boundary implicitly ends previous chapter" {
    const source =
        \\::main
        \\Hello.
        \\::other
        \\World.
    ;
    var script = try parseSource(source, std.testing.allocator);
    defer script.deinit();
    const main = script.getChapter("main").?;
    try std.testing.expectEqual(@as(usize, 1), main.len);
    try std.testing.expectEqualStrings("Hello.", main[0][0].text);
    const other = script.getChapter("other").?;
    try std.testing.expectEqualStrings("World.", other[0][0].text);
}

test "content before first chapter is discarded" {
    const source =
        \\Ignored content.
        \\::main
        \\Hello.
    ;
    var script = try parseSource(source, std.testing.allocator);
    defer script.deinit();
    const chapter = script.getChapter("main").?;
    try std.testing.expectEqual(@as(usize, 1), chapter.len);
    try std.testing.expectEqualStrings("Hello.", chapter[0][0].text);
}

test "all node types parsed correctly" {
    // No spaces between nodes to avoid interleaved text tokens.
    const source = "::main\nplain{ lish }%{ defer }#\"instant\"#{ ilish }@{ clish }";
    var script = try parseSource(source, std.testing.allocator);
    defer script.deinit();
    const section = script.getChapter("main").?[0];
    try std.testing.expectEqual(@as(usize, 6), section.len);
    try std.testing.expect(section[0] == .text);
    try std.testing.expect(section[1] == .lish_inline);
    try std.testing.expect(section[2] == .lish_defer);
    try std.testing.expect(section[3] == .instant_string);
    try std.testing.expect(section[4] == .instant_lish);
    try std.testing.expect(section[5] == .char_lish);
}

test "lish nodes are pre-parsed into AstNodes" {
    var script = try parseSource("::main\n{ color \"red\" }", std.testing.allocator);
    defer script.deinit();
    const section = script.getChapter("main").?[0];
    const ast_node = section[0].lish_inline;
    try std.testing.expect(ast_node.* == .expression);
}

test "instant string value preserved" {
    var script = try parseSource("::main\n#\"hello\"", std.testing.allocator);
    defer script.deinit();
    const section = script.getChapter("main").?[0];
    try std.testing.expectEqualStrings("hello", section[0].instant_string);
}

test "getChapter returns null for unknown chapter" {
    var script = try parseSource("::main\nHello.", std.testing.allocator);
    defer script.deinit();
    try std.testing.expect(script.getChapter("unknown") == null);
}
