const std = @import("std");
const tok = @import("token.zig");
const node = @import("node.zig");
const lish = @import("lish");

const Token = tok.Token;
const TokenType = tok.TokenType;
const Node = node.Node;
const Beat = node.Beat;
const Scene = node.Scene;
const Script = node.Script;

pub const ParseError = error{
    MissingMainScene,
};

const MAIN_SCENE = "main";

pub fn parse(tokens: []const Token, allocator: std.mem.Allocator) !Script {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    var scenes: std.StringHashMapUnmanaged(Scene) = .{};
    var current_name: ?[]const u8 = null;
    var current_beats: std.ArrayListUnmanaged(Beat) = .{};
    var current_nodes: std.ArrayListUnmanaged(Node) = .{};

    for (tokens) |token| {
        switch (token.token_type) {
            .scene_decl => {
                try finalizeScene(arena_alloc, &scenes, current_name, &current_beats, &current_nodes);
                current_name = token.value;
            },
            .beat_break => {
                const beat = try closeBeatNodes(arena_alloc, &current_nodes);
                try current_beats.append(arena_alloc, beat);
            },
            .text => try current_nodes.append(arena_alloc, .{ .text = token.value }),
            .char_string => try current_nodes.append(arena_alloc, .{ .char_string = token.value }),
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
                try finalizeScene(arena_alloc, &scenes, current_name, &current_beats, &current_nodes);
                break;
            },
        }
    }

    if (!scenes.contains(MAIN_SCENE)) return error.MissingMainScene;

    return Script{
        .arena = arena,
        .scenes = scenes,
    };
}

/// Close the current node list into a beat, trimming leading and trailing
/// newline-only text nodes. The returned beat may be empty.
fn closeBeatNodes(allocator: std.mem.Allocator, nodes: *std.ArrayListUnmanaged(Node)) !Beat {
    var start: usize = 0;
    var end: usize = nodes.items.len;
    while (start < end and isNewlineText(nodes.items[start])) start += 1;
    while (end > start and isNewlineText(nodes.items[end - 1])) end -= 1;
    const beat = try allocator.dupe(Node, nodes.items[start..end]);
    nodes.clearRetainingCapacity();
    return beat;
}

fn isNewlineText(n: Node) bool {
    return n == .text and n.text.len == 1 and n.text[0] == tok.NEWLINE;
}

fn finalizeScene(
    allocator: std.mem.Allocator,
    scenes: *std.StringHashMapUnmanaged(Scene),
    name: ?[]const u8,
    beats: *std.ArrayListUnmanaged(Beat),
    nodes: *std.ArrayListUnmanaged(Node),
) !void {
    const scene_name = name orelse {
        // Discard any content appearing before the first scene declaration.
        nodes.clearRetainingCapacity();
        beats.clearRetainingCapacity();
        return;
    };
    const beat = try closeBeatNodes(allocator, nodes);
    if (beat.len > 0) try beats.append(allocator, beat);
    const scene = try beats.toOwnedSlice(allocator);
    try scenes.put(allocator, scene_name, scene);
}

// ── Tests ──

const lexer = @import("lexer.zig");

fn parseSource(source: []const u8, allocator: std.mem.Allocator) !Script {
    const tokens = try lexer.tokenize(source, allocator);
    defer allocator.free(tokens);
    return parse(tokens, allocator);
}

test "missing main scene is an error" {
    try std.testing.expectError(
        error.MissingMainScene,
        parseSource("::intro\nHello.", std.testing.allocator),
    );
}

test "empty main scene" {
    var script = try parseSource("::main", std.testing.allocator);
    defer script.deinit();
    const scene = script.getScene("main").?;
    try std.testing.expectEqual(@as(usize, 0), scene.len);
}

test "single beat no beat break" {
    var script = try parseSource("::main\nHello.", std.testing.allocator);
    defer script.deinit();
    const scene = script.getScene("main").?;
    try std.testing.expectEqual(@as(usize, 1), scene.len);
    try std.testing.expectEqualStrings("Hello.", scene[0][0].text);
}

test "beat break creates two beats" {
    var script = try parseSource("::main\nHello.\n;;\nWorld.", std.testing.allocator);
    defer script.deinit();
    const scene = script.getScene("main").?;
    try std.testing.expectEqual(@as(usize, 2), scene.len);
    try std.testing.expectEqualStrings("Hello.", scene[0][0].text);
    try std.testing.expectEqualStrings("World.", scene[1][0].text);
}

test "trailing beat break is ignored" {
    var script = try parseSource("::main\nHello.\n;;", std.testing.allocator);
    defer script.deinit();
    const scene = script.getScene("main").?;
    try std.testing.expectEqual(@as(usize, 1), scene.len);
    try std.testing.expectEqualStrings("Hello.", scene[0][0].text);
}

test "multiple scenes" {
    const source =
        \\::main
        \\Hello.
        \\::shop
        \\Welcome.
    ;
    var script = try parseSource(source, std.testing.allocator);
    defer script.deinit();
    try std.testing.expect(script.getScene("main") != null);
    try std.testing.expect(script.getScene("shop") != null);
}

test "scene boundary implicitly ends previous scene" {
    const source =
        \\::main
        \\Hello.
        \\::other
        \\World.
    ;
    var script = try parseSource(source, std.testing.allocator);
    defer script.deinit();
    const main = script.getScene("main").?;
    try std.testing.expectEqual(@as(usize, 1), main.len);
    try std.testing.expectEqualStrings("Hello.", main[0][0].text);
    const other = script.getScene("other").?;
    try std.testing.expectEqualStrings("World.", other[0][0].text);
}

test "content before first scene is discarded" {
    const source =
        \\Ignored content.
        \\::main
        \\Hello.
    ;
    var script = try parseSource(source, std.testing.allocator);
    defer script.deinit();
    const scene = script.getScene("main").?;
    try std.testing.expectEqual(@as(usize, 1), scene.len);
    try std.testing.expectEqualStrings("Hello.", scene[0][0].text);
}

test "all node types parsed correctly" {
    // No spaces between nodes to avoid interleaved text tokens.
    const source = "::main\nplain@\"cstr\"{ lish }%{ defer }#\"instant\"#{ ilish }@{ clish }";
    var script = try parseSource(source, std.testing.allocator);
    defer script.deinit();
    const beat = script.getScene("main").?[0];
    try std.testing.expectEqual(@as(usize, 7), beat.len);
    try std.testing.expect(beat[0] == .text);
    try std.testing.expect(beat[1] == .char_string);
    try std.testing.expect(beat[2] == .lish_inline);
    try std.testing.expect(beat[3] == .lish_defer);
    try std.testing.expect(beat[4] == .instant_string);
    try std.testing.expect(beat[5] == .instant_lish);
    try std.testing.expect(beat[6] == .char_lish);
}

test "lish nodes are pre-parsed into AstNodes" {
    var script = try parseSource("::main\n{ color \"red\" }", std.testing.allocator);
    defer script.deinit();
    const beat = script.getScene("main").?[0];
    const ast_node = beat[0].lish_inline;
    try std.testing.expect(ast_node.* == .expression);
}

test "instant string value preserved" {
    var script = try parseSource("::main\n#\"hello\"", std.testing.allocator);
    defer script.deinit();
    const beat = script.getScene("main").?[0];
    try std.testing.expectEqualStrings("hello", beat[0].instant_string);
}

test "getScene returns null for unknown scene" {
    var script = try parseSource("::main\nHello.", std.testing.allocator);
    defer script.deinit();
    try std.testing.expect(script.getScene("unknown") == null);
}
