const std = @import("std");
const lish = @import("lish");
const node_mod = @import("node.zig");

const Script = node_mod.Script;
const Node = node_mod.Node;

pub const ProgrammeNode = union(enum) {
    text: []const u8,
    instant_string: []const u8,
    lish_inline: lish.exec.Expression,
    lish_defer: lish.exec.Expression,
    instant_lish: lish.exec.Expression,
    char_lish: lish.exec.Expression,
};

pub const ProgrammeSection = []const ProgrammeNode;
pub const ProgrammeChapter = []const ProgrammeSection;

pub const Programme = struct {
    arena: std.heap.ArenaAllocator,
    chapters: std.StringHashMapUnmanaged(ProgrammeChapter),

    pub fn getChapter(self: *const Programme, name: []const u8) ?ProgrammeChapter {
        return self.chapters.get(name);
    }

    pub fn deinit(self: *Programme) void {
        self.arena.deinit();
    }
};

// ── Compile errors ──

pub const NodeError = struct {
    chapter: []const u8,
    section_index: usize,
    node_index: usize,
    errors: []const lish.validation.ValidationError,
};

pub const CompileErrors = struct {
    arena: std.heap.ArenaAllocator,
    items: []const NodeError,

    pub fn deinit(self: *CompileErrors) void {
        self.arena.deinit();
    }
};

pub const CompileResult = union(enum) {
    ok: Programme,
    err: CompileErrors,
};

// ── Compile ──

/// Compile a Script into an executable Programme by validating all embedded
/// lish expressions. Returns a Programme on success or CompileErrors on failure.
///
/// All strings in the returned Programme are independent copies — the Script
/// may be deinited after compile returns. CompileErrors are also fully
/// self-contained and may be used after the Script is deinited.
pub fn compile(script: *const Script, allocator: std.mem.Allocator) !CompileResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var node_errors: std.ArrayListUnmanaged(NodeError) = .{};
    var chapters: std.StringHashMapUnmanaged(ProgrammeChapter) = .{};

    var chapter_iter = script.chapters.iterator();
    while (chapter_iter.next()) |entry| {
        const chapter_name = try alloc.dupe(u8, entry.key_ptr.*);
        const source_chapter = entry.value_ptr.*;

        var prog_sections: std.ArrayListUnmanaged(ProgrammeSection) = .{};

        for (source_chapter, 0..) |source_section, section_idx| {
            var prog_nodes: std.ArrayListUnmanaged(ProgrammeNode) = .{};

            for (source_section, 0..) |source_node, node_idx| {
                if (try compileNode(alloc, source_node, chapter_name, section_idx, node_idx, &node_errors)) |prog_node| {
                    try prog_nodes.append(alloc, prog_node);
                }
            }

            try prog_sections.append(alloc, try prog_nodes.toOwnedSlice(alloc));
        }

        try chapters.put(alloc, chapter_name, try prog_sections.toOwnedSlice(alloc));
    }

    if (node_errors.items.len > 0) {
        return .{ .err = .{
            .arena = arena,
            .items = node_errors.items,
        } };
    }

    return .{ .ok = .{
        .arena = arena,
        .chapters = chapters,
    } };
}

fn compileNode(
    alloc: std.mem.Allocator,
    source_node: Node,
    chapter_name: []const u8,
    section_index: usize,
    node_index: usize,
    node_errors: *std.ArrayListUnmanaged(NodeError),
) !?ProgrammeNode {
    return switch (source_node) {
        .text => |str| .{ .text = try alloc.dupe(u8, str) },
        .instant_string => |str| .{ .instant_string = try alloc.dupe(u8, str) },
        .lish_inline => |ast_node| blk: {
            const expr = try validateLishNode(alloc, ast_node, chapter_name, section_index, node_index, node_errors) orelse break :blk null;
            break :blk .{ .lish_inline = expr };
        },
        .lish_defer => |ast_node| blk: {
            const expr = try validateLishNode(alloc, ast_node, chapter_name, section_index, node_index, node_errors) orelse break :blk null;
            break :blk .{ .lish_defer = expr };
        },
        .instant_lish => |ast_node| blk: {
            const expr = try validateLishNode(alloc, ast_node, chapter_name, section_index, node_index, node_errors) orelse break :blk null;
            break :blk .{ .instant_lish = expr };
        },
        .char_lish => |ast_node| blk: {
            const expr = try validateLishNode(alloc, ast_node, chapter_name, section_index, node_index, node_errors) orelse break :blk null;
            break :blk .{ .char_lish = expr };
        },
    };
}

fn validateLishNode(
    alloc: std.mem.Allocator,
    ast_node: *lish.AstNode,
    chapter_name: []const u8,
    section_index: usize,
    node_index: usize,
    node_errors: *std.ArrayListUnmanaged(NodeError),
) !?lish.exec.Expression {
    const result = try lish.validation.validate(alloc, ast_node);
    switch (result) {
        .ok => |expression| return expression,
        .err => |validation_errors| {
            // Deep-copy errors so CompileErrors is independent from the Script's arena.
            const duped_errors = try alloc.alloc(lish.validation.ValidationError, validation_errors.len);
            for (validation_errors, 0..) |verr, i| {
                duped_errors[i] = .{
                    .message = try alloc.dupe(u8, verr.message),
                    .line = verr.line,
                    .column = verr.column,
                    .start = verr.start,
                    .end = verr.end,
                };
            }
            try node_errors.append(alloc, .{
                .chapter = chapter_name,
                .section_index = section_index,
                .node_index = node_index,
                .errors = duped_errors,
            });
            return null;
        },
    }
}

// ── Tests ──

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");

fn parseSource(source: []const u8, allocator: std.mem.Allocator) !Script {
    const tokens = try lexer.tokenize(source, allocator);
    defer allocator.free(tokens);
    return parser.parse(tokens, allocator);
}

test "compile plain text" {
    var script = try parseSource("::main\nHello.", std.testing.allocator);
    defer script.deinit();
    var result = try compile(&script, std.testing.allocator);
    switch (result) {
        .ok => |*prog| {
            defer prog.deinit();
            const chapter = prog.getChapter("main").?;
            try std.testing.expectEqual(@as(usize, 1), chapter.len);
            try std.testing.expectEqualStrings("Hello.", chapter[0][0].text);
        },
        .err => |*errors| {
            errors.deinit();
            return error.TestUnexpectedResult;
        },
    }
}

test "compile instant string" {
    var script = try parseSource("::main\n#\"hello\"", std.testing.allocator);
    defer script.deinit();
    var result = try compile(&script, std.testing.allocator);
    switch (result) {
        .ok => |*prog| {
            defer prog.deinit();
            const section = prog.getChapter("main").?[0];
            try std.testing.expectEqualStrings("hello", section[0].instant_string);
        },
        .err => |*errors| {
            errors.deinit();
            return error.TestUnexpectedResult;
        },
    }
}

test "compile valid lish expression" {
    var script = try parseSource("::main\n{ say \"hello\" }", std.testing.allocator);
    defer script.deinit();
    var result = try compile(&script, std.testing.allocator);
    switch (result) {
        .ok => |*prog| {
            defer prog.deinit();
            const section = prog.getChapter("main").?[0];
            try std.testing.expect(section[0] == .lish_inline);
        },
        .err => |*errors| {
            errors.deinit();
            return error.TestUnexpectedResult;
        },
    }
}

test "invalid lish expression produces compile error" {
    var script = try parseSource("::main\n{}", std.testing.allocator);
    defer script.deinit();
    var result = try compile(&script, std.testing.allocator);
    switch (result) {
        .ok => |*prog| {
            prog.deinit();
            return error.TestUnexpectedResult;
        },
        .err => |*errors| {
            defer errors.deinit();
            try std.testing.expectEqual(@as(usize, 1), errors.items.len);
            try std.testing.expectEqualStrings("main", errors.items[0].chapter);
            try std.testing.expectEqual(@as(usize, 0), errors.items[0].section_index);
            try std.testing.expectEqual(@as(usize, 0), errors.items[0].node_index);
        },
    }
}

test "multiple invalid lish nodes accumulate errors" {
    var script = try parseSource("::main\n{}\n{}", std.testing.allocator);
    defer script.deinit();
    var result = try compile(&script, std.testing.allocator);
    switch (result) {
        .ok => |*prog| {
            prog.deinit();
            return error.TestUnexpectedResult;
        },
        .err => |*errors| {
            defer errors.deinit();
            try std.testing.expectEqual(@as(usize, 2), errors.items.len);
        },
    }
}

test "compile multiple chapters" {
    const source =
        \\::main
        \\Hello.
        \\::shop
        \\Welcome.
    ;
    var script = try parseSource(source, std.testing.allocator);
    defer script.deinit();
    var result = try compile(&script, std.testing.allocator);
    switch (result) {
        .ok => |*prog| {
            defer prog.deinit();
            try std.testing.expect(prog.getChapter("main") != null);
            try std.testing.expect(prog.getChapter("shop") != null);
        },
        .err => |*errors| {
            errors.deinit();
            return error.TestUnexpectedResult;
        },
    }
}

test "compiled programme is independent from source script" {
    var script = try parseSource("::main\nHello.", std.testing.allocator);
    var result = try compile(&script, std.testing.allocator);
    script.deinit();
    switch (result) {
        .ok => |*prog| {
            defer prog.deinit();
            const chapter = prog.getChapter("main").?;
            try std.testing.expectEqualStrings("Hello.", chapter[0][0].text);
        },
        .err => |*errors| {
            errors.deinit();
            return error.TestUnexpectedResult;
        },
    }
}
