const std = @import("std");
const tok = @import("token.zig");
const Token = tok.Token;
const TokenType = tok.TokenType;

pub const LexError = error{
    UnclosedBrace,
    UnclosedString,
    EmptySceneName,
};

pub fn tokenize(source: []const u8, allocator: std.mem.Allocator) ![]Token {
    var lexer = Lexer.init(source);
    return lexer.scan(allocator);
}

const Lexer = struct {
    source: []const u8,
    pos: usize,
    line: u32,
    col: u32,
    at_line_start: bool,

    fn init(source: []const u8) Lexer {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
            .col = 1,
            .at_line_start = true,
        };
    }

    fn scan(self: *Lexer, allocator: std.mem.Allocator) ![]Token {
        var tokens: std.ArrayListUnmanaged(Token) = .{};
        errdefer tokens.deinit(allocator);
        while (true) {
            const next_tok = try self.next();
            try tokens.append(allocator, next_tok);
            if (next_tok.token_type == .eof) break;
        }
        return tokens.toOwnedSlice(allocator);
    }

    fn next(self: *Lexer) LexError!Token {
        if (self.at_line_start) self.skipSpaces();

        if (self.pos >= self.source.len) {
            return Token{ .token_type = .eof, .value = "", .line = self.line, .column = self.col };
        }

        const line = self.line;
        const col = self.col;
        const ch = self.source[self.pos];

        if (self.at_line_start) {
            if (ch == tok.SCENE_SIGIL and self.peekAt(1) == tok.SCENE_SIGIL) {
                return self.scanSceneDecl(line, col);
            }
            if (ch == tok.BEAT_SIGIL and self.peekAt(1) == tok.BEAT_SIGIL) {
                self.pos += 2;
                self.col += 2;
                self.skipToNewline();
                return Token{ .token_type = .beat_break, .value = "", .line = line, .column = col };
            }
        }

        self.at_line_start = false;

        if (ch == tok.NEWLINE) {
            self.pos += 1;
            self.line += 1;
            self.col = 1;
            self.at_line_start = true;
            return Token{ .token_type = .text, .value = "\n", .line = line, .column = col };
        }

        if (ch == tok.BLOCK_OPEN) {
            self.pos += 1;
            self.col += 1;
            const content = try self.scanBraceContent();
            return Token{ .token_type = .lish_inline, .value = content, .line = line, .column = col };
        }

        if (ch == tok.DEFER_SIGIL and self.peekAt(1) == tok.BLOCK_OPEN) {
            self.pos += 2;
            self.col += 2;
            const content = try self.scanBraceContent();
            return Token{ .token_type = .lish_defer, .value = content, .line = line, .column = col };
        }

        if (ch == tok.INSTANT_SIGIL) {
            if (self.peekAt(1) == tok.QUOTE_DOUBLE or self.peekAt(1) == tok.QUOTE_SINGLE) {
                const quote = self.source[self.pos + 1];
                self.pos += 2;
                self.col += 2;
                const content = try self.scanQuotedString(quote);
                return Token{ .token_type = .instant_string, .value = content, .line = line, .column = col };
            }
            if (self.peekAt(1) == tok.BLOCK_OPEN) {
                self.pos += 2;
                self.col += 2;
                const content = try self.scanBraceContent();
                return Token{ .token_type = .instant_lish, .value = content, .line = line, .column = col };
            }
        }

        if (ch == tok.CHAR_SIGIL) {
            if (self.peekAt(1) == tok.QUOTE_DOUBLE or self.peekAt(1) == tok.QUOTE_SINGLE) {
                const quote = self.source[self.pos + 1];
                self.pos += 2;
                self.col += 2;
                const content = try self.scanQuotedString(quote);
                return Token{ .token_type = .char_string, .value = content, .line = line, .column = col };
            }
            if (self.peekAt(1) == tok.BLOCK_OPEN) {
                self.pos += 2;
                self.col += 2;
                const content = try self.scanBraceContent();
                return Token{ .token_type = .char_lish, .value = content, .line = line, .column = col };
            }
        }

        return self.scanPlainText(line, col);
    }

    fn scanSceneDecl(self: *Lexer, line: u32, col: u32) LexError!Token {
        self.pos += 2;
        self.col += 2;
        self.skipSpaces();
        const name_start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != tok.NEWLINE) {
            self.pos += 1;
        }
        const name = std.mem.trimRight(u8, self.source[name_start..self.pos], " \t\r");
        if (name.len == 0) return error.EmptySceneName;
        if (self.pos < self.source.len and self.source[self.pos] == tok.NEWLINE) {
            self.pos += 1;
            self.line += 1;
            self.col = 1;
            self.at_line_start = true;
        }
        return Token{ .token_type = .scene_decl, .value = name, .line = line, .column = col };
    }

    fn scanPlainText(self: *Lexer, line: u32, col: u32) Token {
        const start = self.pos;
        while (self.pos < self.source.len) {
            switch (self.source[self.pos]) {
                tok.NEWLINE, tok.BLOCK_OPEN => break,
                tok.DEFER_SIGIL => if (self.peekAt(1) == tok.BLOCK_OPEN) break,
                tok.INSTANT_SIGIL => if (self.peekAt(1) == tok.BLOCK_OPEN or
                    self.peekAt(1) == tok.QUOTE_DOUBLE or
                    self.peekAt(1) == tok.QUOTE_SINGLE) break,
                tok.CHAR_SIGIL => if (self.peekAt(1) == tok.BLOCK_OPEN or
                    self.peekAt(1) == tok.QUOTE_DOUBLE or
                    self.peekAt(1) == tok.QUOTE_SINGLE) break,
                else => {},
            }
            self.pos += 1;
            self.col += 1;
        }
        return Token{ .token_type = .text, .value = self.source[start..self.pos], .line = line, .column = col };
    }

    fn scanBraceContent(self: *Lexer) LexError![]const u8 {
        const start = self.pos;
        var depth: u32 = 1;
        while (self.pos < self.source.len) {
            switch (self.source[self.pos]) {
                '"', '\'' => |quote| {
                    self.pos += 1;
                    try self.skipQuotedContent(quote);
                },
                '{' => {
                    depth += 1;
                    self.pos += 1;
                },
                '}' => {
                    depth -= 1;
                    if (depth == 0) {
                        const content = std.mem.trim(u8, self.source[start..self.pos], " \t\r\n");
                        self.pos += 1;
                        return content;
                    }
                    self.pos += 1;
                },
                tok.NEWLINE => {
                    self.line += 1;
                    self.col = 1;
                    self.pos += 1;
                },
                else => self.pos += 1,
            }
        }
        return error.UnclosedBrace;
    }

    fn skipQuotedContent(self: *Lexer, quote: u8) LexError!void {
        while (self.pos < self.source.len) {
            if (self.source[self.pos] == tok.BACKSLASH) {
                self.pos += 2;
            } else if (self.source[self.pos] == quote) {
                self.pos += 1;
                return;
            } else {
                self.pos += 1;
            }
        }
        return error.UnclosedString;
    }

    fn scanQuotedString(self: *Lexer, quote: u8) LexError![]const u8 {
        const start = self.pos;
        while (self.pos < self.source.len) {
            if (self.source[self.pos] == tok.BACKSLASH) {
                self.pos += 2;
            } else if (self.source[self.pos] == quote) {
                const content = self.source[start..self.pos];
                self.pos += 1;
                return content;
            } else {
                self.pos += 1;
            }
        }
        return error.UnclosedString;
    }

    fn peekAt(self: *Lexer, offset: usize) ?u8 {
        const idx = self.pos + offset;
        if (idx >= self.source.len) return null;
        return self.source[idx];
    }

    fn skipSpaces(self: *Lexer) void {
        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (ch != ' ' and ch != '\t' and ch != '\r') break;
            self.pos += 1;
            self.col += 1;
        }
    }

    fn skipToNewline(self: *Lexer) void {
        while (self.pos < self.source.len and self.source[self.pos] != tok.NEWLINE) {
            self.pos += 1;
        }
    }
};

// ── Tests ──

test "empty source" {
    const tokens = try tokenize("", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try std.testing.expectEqual(TokenType.eof, tokens[0].token_type);
}

test "scene decl" {
    const tokens = try tokenize("::main", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(TokenType.scene_decl, tokens[0].token_type);
    try std.testing.expectEqualStrings("main", tokens[0].value);
}

test "scene decl trims trailing whitespace" {
    const tokens = try tokenize("::main   ", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqualStrings("main", tokens[0].value);
}

test "scene decl with leading spaces before name" {
    const tokens = try tokenize("::   my-scene", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqualStrings("my-scene", tokens[0].value);
}

test "empty scene name is an error" {
    try std.testing.expectError(error.EmptySceneName, tokenize("::", std.testing.allocator));
}

test "beat break" {
    const tokens = try tokenize("::main\n;;", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(TokenType.scene_decl, tokens[0].token_type);
    try std.testing.expectEqual(TokenType.beat_break, tokens[1].token_type);
}

test "beat break ignores trailing content on same line" {
    const tokens = try tokenize("::main\n;;   ignored", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(TokenType.beat_break, tokens[1].token_type);
}

test "plain text" {
    const tokens = try tokenize("::main\nhello world", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(TokenType.text, tokens[1].token_type);
    try std.testing.expectEqualStrings("hello world", tokens[1].value);
}

test "newline emitted as text" {
    const tokens = try tokenize("::main\nhello\nworld", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(TokenType.text, tokens[2].token_type);
    try std.testing.expectEqualStrings("\n", tokens[2].value);
}

test "lish inline" {
    const tokens = try tokenize("::main\n{ say \"hi\" }", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(TokenType.lish_inline, tokens[1].token_type);
    try std.testing.expectEqualStrings("say \"hi\"", tokens[1].value);
}

test "lish inline trims whitespace from content" {
    const tokens = try tokenize("::main\n{   color \"red\"   }", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqualStrings("color \"red\"", tokens[1].value);
}

test "lish inline with nested braces" {
    const tokens = try tokenize("::main\n{ if (x) { y } }", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(TokenType.lish_inline, tokens[1].token_type);
    try std.testing.expectEqualStrings("if (x) { y }", tokens[1].value);
}

test "lish inline with single-quoted string containing braces" {
    const tokens = try tokenize("::main\n{ say 'hello { world }' }", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(TokenType.lish_inline, tokens[1].token_type);
    try std.testing.expectEqualStrings("say 'hello { world }'", tokens[1].value);
}

test "lish defer" {
    const tokens = try tokenize("::main\n%{ scene \"next\" }", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(TokenType.lish_defer, tokens[1].token_type);
    try std.testing.expectEqualStrings("scene \"next\"", tokens[1].value);
}

test "instant string double quote" {
    const tokens = try tokenize("::main\n#\"hello\"", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(TokenType.instant_string, tokens[1].token_type);
    try std.testing.expectEqualStrings("hello", tokens[1].value);
}

test "instant string single quote" {
    const tokens = try tokenize("::main\n#'hello'", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(TokenType.instant_string, tokens[1].token_type);
    try std.testing.expectEqualStrings("hello", tokens[1].value);
}

test "instant string single quote containing double quote" {
    const tokens = try tokenize("::main\n#'she said \"hi\"'", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(TokenType.instant_string, tokens[1].token_type);
    try std.testing.expectEqualStrings("she said \"hi\"", tokens[1].value);
}

test "instant lish" {
    const tokens = try tokenize("::main\n#{ player-name }", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(TokenType.instant_lish, tokens[1].token_type);
    try std.testing.expectEqualStrings("player-name", tokens[1].value);
}

test "char string double quote" {
    const tokens = try tokenize("::main\n@\"hello\"", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(TokenType.char_string, tokens[1].token_type);
    try std.testing.expectEqualStrings("hello", tokens[1].value);
}

test "char string single quote" {
    const tokens = try tokenize("::main\n@'hello'", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(TokenType.char_string, tokens[1].token_type);
    try std.testing.expectEqualStrings("hello", tokens[1].value);
}

test "char-by-char lish" {
    const tokens = try tokenize("::main\n@{ player-name }", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(TokenType.char_lish, tokens[1].token_type);
    try std.testing.expectEqualStrings("player-name", tokens[1].value);
}

test "mixed line: text and sigils interleaved" {
    const tokens = try tokenize("::main\nhello { color \"red\" } world", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(TokenType.text, tokens[1].token_type);
    try std.testing.expectEqualStrings("hello ", tokens[1].value);
    try std.testing.expectEqual(TokenType.lish_inline, tokens[2].token_type);
    try std.testing.expectEqualStrings("color \"red\"", tokens[2].value);
    try std.testing.expectEqual(TokenType.text, tokens[3].token_type);
    try std.testing.expectEqualStrings(" world", tokens[3].value);
}

test "escape sequence in instant string preserved raw" {
    const tokens = try tokenize("::main\n#\"hello\\nworld\"", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(TokenType.instant_string, tokens[1].token_type);
    try std.testing.expectEqualStrings("hello\\nworld", tokens[1].value);
}

test "escaped quote in instant string does not close it early" {
    const tokens = try tokenize("::main\n#\"say \\\"hi\\\"\"", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(TokenType.instant_string, tokens[1].token_type);
    try std.testing.expectEqualStrings("say \\\"hi\\\"", tokens[1].value);
}

test "bare sigils without expected follower are plain text" {
    const tokens = try tokenize("::main\n100% done #tag @handle", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(TokenType.text, tokens[1].token_type);
    try std.testing.expectEqualStrings("100% done #tag @handle", tokens[1].value);
}

test "unclosed brace is an error" {
    try std.testing.expectError(error.UnclosedBrace, tokenize("::main\n{ unclosed", std.testing.allocator));
}

test "unclosed string is an error" {
    try std.testing.expectError(error.UnclosedString, tokenize("::main\n#\"unclosed", std.testing.allocator));
}

test "multiple scenes" {
    const source =
        \\::intro
        \\Hello.
        \\::shop
        \\Welcome.
    ;
    const tokens = try tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(TokenType.scene_decl, tokens[0].token_type);
    try std.testing.expectEqualStrings("intro", tokens[0].value);
    try std.testing.expectEqual(TokenType.scene_decl, tokens[3].token_type);
    try std.testing.expectEqualStrings("shop", tokens[3].value);
}

test "line and column tracking" {
    const tokens = try tokenize("::main\nhello", std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(@as(u32, 1), tokens[0].line);
    try std.testing.expectEqual(@as(u32, 1), tokens[0].column);
    try std.testing.expectEqual(@as(u32, 2), tokens[1].line);
    try std.testing.expectEqual(@as(u32, 1), tokens[1].column);
}

test "full script" {
    const source =
        \\::main
        \\{ nametag "Vendor" }Welcome, #{ player-name }.
        \\I have some #"items" for sale.
        \\;;
        \\%{ scene "shop" }
    ;
    const tokens = try tokenize(source, std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(TokenType.scene_decl, tokens[0].token_type);
    try std.testing.expectEqual(TokenType.lish_inline, tokens[1].token_type);
    try std.testing.expectEqual(TokenType.text, tokens[2].token_type);
    try std.testing.expectEqual(TokenType.instant_lish, tokens[3].token_type);
    try std.testing.expectEqual(TokenType.text, tokens[4].token_type);
}
