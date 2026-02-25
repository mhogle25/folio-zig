const std = @import("std");
const posix = std.posix;
const lish = @import("lish");
const folio = @import("folio");

const lexer = folio.lexer;
const parser = folio.parser;
const programme = folio.programme;
const runner_mod = folio.runner;
const ops = folio.ops;

const Runner = runner_mod.Runner;
const RenderTarget = runner_mod.RenderTarget;

// ── Terminal state ──

var global_original_termios: ?posix.termios = null;

fn sigintHandler(_: c_int) callconv(.c) void {
    if (global_original_termios) |original| {
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, original) catch {};
    }
    _ = posix.write(posix.STDOUT_FILENO, "\n") catch 0;
    std.process.exit(130);
}

fn enableRawMode() !posix.termios {
    const original = try posix.tcgetattr(posix.STDIN_FILENO);
    global_original_termios = original;

    const act = posix.Sigaction{
        .handler = .{ .handler = &sigintHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);

    var raw = original;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    // Non-blocking reads
    raw.cc[@intFromEnum(posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;

    try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
    return original;
}

fn disableRawMode(original: posix.termios) void {
    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, original) catch {};
    global_original_termios = null;
}

// ── TerminalTarget ──

const TerminalTarget = struct {
    fn renderTarget(self: *TerminalTarget) RenderTarget {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = RenderTarget.Vtable{
        .appendChar = appendChar,
        .appendText = appendText,
        .clear = clear,
    };

    fn appendChar(_: *anyopaque, char: u8) void {
        if (char == '\n') {
            _ = posix.write(posix.STDOUT_FILENO, "\r\n") catch 0;
        } else {
            _ = posix.write(posix.STDOUT_FILENO, &[1]u8{char}) catch 0;
        }
    }

    fn appendText(_: *anyopaque, text: []const u8) void {
        var remaining = text;
        while (std.mem.indexOfScalar(u8, remaining, '\n')) |idx| {
            _ = posix.write(posix.STDOUT_FILENO, remaining[0..idx]) catch 0;
            _ = posix.write(posix.STDOUT_FILENO, "\r\n") catch 0;
            remaining = remaining[idx + 1 ..];
        }
        if (remaining.len > 0) {
            _ = posix.write(posix.STDOUT_FILENO, remaining) catch 0;
        }
    }

    fn clear(_: *anyopaque) void {
        _ = posix.write(posix.STDOUT_FILENO, "\r\n\r\n---\r\n\r\n") catch 0;
    }

};

// ── Entry point ──

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stderr = lish.session.fdWriter(posix.STDERR_FILENO);
    const stdout = lish.session.fdWriter(posix.STDOUT_FILENO);

    // ── Parse CLI args ──

    const argv = std.os.argv;

    if (argv.len < 2) {
        stderr.writeAll("usage: folio <script.folio> [--scene <name>]\n") catch {};
        std.process.exit(1);
    }

    const script_path = std.mem.span(argv[1]);
    var scene_name: []const u8 = "main";

    var arg_index: usize = 2;
    while (arg_index < argv.len) : (arg_index += 1) {
        const arg = std.mem.span(argv[arg_index]);
        if (std.mem.eql(u8, arg, "--scene") and arg_index + 1 < argv.len) {
            arg_index += 1;
            scene_name = std.mem.span(argv[arg_index]);
        }
    }

    // ── Load and compile script ──

    const source = std.fs.cwd().readFileAlloc(allocator, script_path, 1024 * 1024) catch |err| {
        stderr.print("folio: could not read \"{s}\": {s}\n", .{ script_path, @errorName(err) }) catch {};
        std.process.exit(1);
    };
    defer allocator.free(source);

    const tokens = try lexer.tokenize(source, allocator);
    defer allocator.free(tokens);

    var script = try parser.parse(tokens, allocator);
    defer script.deinit();

    var compile_result = try programme.compile(&script, allocator);

    var prog = switch (compile_result) {
        .ok => |p| p,
        .err => |*errors| {
            defer errors.deinit();
            for (errors.items) |node_err| {
                for (node_err.errors) |verr| {
                    stderr.print("folio: [{s} beat {d} node {d}] {s}\n", .{
                        node_err.scene,
                        node_err.beat_index,
                        node_err.node_index,
                        verr.message,
                    }) catch {};
                }
            }
            std.process.exit(1);
        },
    };
    defer prog.deinit();

    // ── Set up runner ──

    var terminal_target = TerminalTarget{};
    var registry = lish.Registry{};
    defer registry.deinit(allocator);
    try lish.builtins.registerAll(&registry, allocator);

    var runner = Runner.init(
        &prog,
        &registry,
        &lish.Scope.EMPTY,
        terminal_target.renderTarget(),
        .{},
        allocator,
    );
    defer runner.deinit();

    try ops.registerAll(&registry, &runner, allocator);

    // ── Startup message ──

    stdout.print("folio: playing \"{s}\" (scene: {s})\n\n", .{ script_path, scene_name }) catch {};

    if (!runner.loadScene(scene_name)) {
        stderr.print("folio: scene \"{s}\" not found\n", .{scene_name}) catch {};
        std.process.exit(1);
    }

    // ── Enable raw mode ──

    const original_termios = enableRawMode() catch {
        // Non-terminal (piped input) — run without raw mode, auto-advance
        runLoop(&runner, false);
        return;
    };
    defer disableRawMode(original_termios);

    runLoop(&runner, true);

    _ = posix.write(posix.STDOUT_FILENO, "\r\n") catch 0;
}

fn runLoop(runner: *Runner, is_terminal: bool) void {
    var timer = std.time.Timer.start() catch return;
    var waiting_prompt_shown = false;

    while (runner.getState() != .done) {
        const delta_ns = timer.lap();
        const delta_ms = @as(f64, @floatFromInt(delta_ns)) / 1_000_000.0;
        _ = runner.advance(delta_ms);

        if (runner.getState() == .waiting and !waiting_prompt_shown) {
            _ = posix.write(posix.STDOUT_FILENO, "\r\n\u{25b6} ") catch 0;
            waiting_prompt_shown = true;
        }

        if (!is_terminal) {
            // Auto-advance without waiting for input
            if (runner.getState() == .waiting) {
                waiting_prompt_shown = false;
                runner.confirm();
            }
            continue;
        }

        // Poll stdin with 16ms timeout
        var fds = [1]posix.pollfd{.{
            .fd = posix.STDIN_FILENO,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        _ = posix.poll(&fds, 16) catch continue;
        if (fds[0].revents & posix.POLL.IN == 0) continue;

        var byte: u8 = undefined;
        const n = posix.read(posix.STDIN_FILENO, (&byte)[0..1]) catch break;
        if (n == 0) continue;

        switch (byte) {
            '\r', ' ' => {
                if (runner.getState() == .waiting) {
                    waiting_prompt_shown = false;
                    runner.confirm();
                } else if (runner.getState() == .emitting) {
                    runner.confirm();
                }
            },
            'q', 0x03 => break,
            else => {},
        }
    }
}
