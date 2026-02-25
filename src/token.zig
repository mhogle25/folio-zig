pub const TokenType = enum {
    scene_decl,
    beat_break,
    text,
    char_string,
    lish_inline,
    lish_defer,
    instant_string,
    instant_lish,
    char_lish,
    eof
};

pub const Token = struct {
    token_type: TokenType,
    value: []const u8,
    line: u32,
    column: u32
};

// ── Syntax constants ──

pub const SCENE_SIGIL = ':';
pub const BEAT_SIGIL = ';';
pub const BLOCK_OPEN = '{';
pub const BLOCK_CLOSE = '}';
pub const DEFER_SIGIL = '%';
pub const INSTANT_SIGIL = '#';
pub const CHAR_SIGIL = '@';
pub const QUOTE_DOUBLE = '"';
pub const QUOTE_SINGLE = '\'';
pub const BACKSLASH = '\\';
pub const NEWLINE = '\n';
pub const CARRIAGE_RETURN = '\r';

