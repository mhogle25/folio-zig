const std = @import("std");
const lish = @import("lish");
const prog_mod = @import("programme.zig");

const Allocator = std.mem.Allocator;
const Programme = prog_mod.Programme;
const ProgrammeScene = prog_mod.ProgrammeScene;
const ProgrammeBeat = prog_mod.ProgrammeBeat;
const ProgrammeNode = prog_mod.ProgrammeNode;

// ── RenderTarget ──

/// Interface for receiving runner output. Implement by constructing a
/// RenderTarget with a context pointer and a Vtable of function pointers.
pub const RenderTarget = struct {
    context: *anyopaque,
    vtable: *const Vtable,

    pub const Vtable = struct {
        /// Called once per character during typewriter emission.
        appendChar: *const fn (*anyopaque, u8) void,
        /// Called to emit a string all at once (instant display).
        appendText: *const fn (*anyopaque, []const u8) void,
        /// Called when transitioning to the next section.
        clear: *const fn (*anyopaque) void,
        /// Called when a lish expression fails at runtime. message is valid only
        /// for the duration of the call — copy it if you need to retain it.
        reportError: *const fn (*anyopaque, []const u8) void,
    };

    pub fn appendChar(self: RenderTarget, char: u8) void {
        self.vtable.appendChar(self.context, char);
    }

    pub fn appendText(self: RenderTarget, text: []const u8) void {
        self.vtable.appendText(self.context, text);
    }

    pub fn clear(self: RenderTarget) void {
        self.vtable.clear(self.context);
    }

    pub fn reportError(self: RenderTarget, message: []const u8) void {
        self.vtable.reportError(self.context, message);
    }
};

// ── RunnerConfig ──

pub const RunnerConfig = struct {
    /// Characters emitted per second during typewriter effect.
    chars_per_sec: f64 = 60.0,
    /// If true, confirm() while emitting flushes the current section instantly.
    confirm_skips: bool = true,
};

// ── RunnerState ──

pub const RunnerState = enum {
    /// Typewriter is actively emitting characters.
    emitting,
    /// Current section fully displayed; waiting for confirm().
    waiting,
    /// Scene complete; no more beats.
    done,
};

// ── Runner ──

pub const Runner = struct {
    // Consumer-provided (borrowed — must outlive the Runner)
    programme: *const Programme,
    registry: *const lish.Registry,
    scope: *const lish.Scope,
    render_target: RenderTarget,
    config: RunnerConfig,

    // Allocator for lish evaluation results (reset per section)
    allocator: Allocator,
    eval_arena: std.heap.ArenaAllocator,

    // Commands deferred with %{ } — fired in order when the player confirms.
    deferred_queue: std.ArrayListUnmanaged(lish.exec.Expression),

    // Position
    runner_state: RunnerState,
    scene: ProgrammeScene,
    beat_index: usize,
    node_index: usize,

    // Current char-by-char text and position within it
    current_text: []const u8,
    char_index: usize,

    // Accumulated time since last character emission (milliseconds)
    char_timer: f64,

    /// Remaining delay before typewriter resumes (milliseconds). Set by the delay op.
    pause_remaining: f64,

    /// When true, text nodes are emitted instantly instead of character-by-char.
    /// char_string and char_lish nodes always use typewriter regardless of this flag.
    instant_mode: bool,

    // chars_per_sec and confirm_skips from the initial config — restored on each scene load.
    base_chars_per_sec: f64,
    base_confirm_skips: bool,

    pub fn init(
        programme: *const Programme,
        registry: *const lish.Registry,
        scope: *const lish.Scope,
        render_target: RenderTarget,
        config: RunnerConfig,
        allocator: Allocator,
    ) Runner {
        return .{
            .programme = programme,
            .registry = registry,
            .scope = scope,
            .render_target = render_target,
            .config = config,
            .allocator = allocator,
            .eval_arena = std.heap.ArenaAllocator.init(allocator),
            .deferred_queue = .{},
            .runner_state = .done,
            .scene = &.{},
            .beat_index = 0,
            .node_index = 0,
            .current_text = "",
            .char_index = 0,
            .char_timer = 0,
            .pause_remaining = 0,
            .instant_mode = false,
            .base_chars_per_sec = config.chars_per_sec,
            .base_confirm_skips = config.confirm_skips,
        };
    }

    pub fn deinit(self: *Runner) void {
        self.deferred_queue.deinit(self.allocator);
        self.eval_arena.deinit();
    }

    /// Load a scene by name. Returns false if the scene does not exist.
    /// Resets all runner state and begins emission from the first beat.
    pub fn loadScene(self: *Runner, name: []const u8) bool {
        const scene = self.programme.getScene(name) orelse return false;
        self.scene = scene;
        self.beat_index = 0;
        self.char_timer = 0;
        self.pause_remaining = 0;
        self.instant_mode = false;
        self.config.chars_per_sec = self.base_chars_per_sec;
        self.config.confirm_skips = self.base_confirm_skips;
        if (scene.len > 0) {
            self.enterBeat();
        } else {
            self.runner_state = .done;
        }
        return true;
    }

    /// Advance the runner by delta_ms milliseconds. Drains any active delay
    /// first, then emits characters. Surplus time after a delay expires carries
    /// over into character emission. Returns the current state after advancement.
    pub fn advance(self: *Runner, delta_ms: f64) RunnerState {
        if (self.runner_state != .emitting) return self.runner_state;

        var remaining = delta_ms;

        if (self.pause_remaining > 0) {
            if (remaining <= self.pause_remaining) {
                self.pause_remaining -= remaining;
                return self.runner_state;
            }
            remaining -= self.pause_remaining;
            self.pause_remaining = 0;
        }

        self.char_timer += remaining;
        const ms_per_char = 1000.0 / self.config.chars_per_sec;

        while (self.step(ms_per_char)) {
            if (self.pause_remaining > 0) break;
        }

        return self.runner_state;
    }

    /// Handle player confirmation. Context-sensitive:
    ///   emitting + confirm_skips: flush current beat instantly → waiting
    ///   emitting + !confirm_skips: no effect
    ///   waiting: advance to next beat (or done)
    ///   done: no effect
    pub fn confirm(self: *Runner) void {
        switch (self.runner_state) {
            .emitting => if (self.config.confirm_skips) self.flushBeat(),
            .waiting => self.advanceBeat(),
            .done => {},
        }
    }

    /// Flush the current beat instantly without advancing. Transitions to waiting.
    /// Intended for use by the continue op.
    pub fn continueBeat(self: *Runner) void {
        self.flushBeat();
    }

    /// Flush the current beat instantly and immediately advance to the next.
    /// Intended for use by the skip op.
    pub fn skipBeat(self: *Runner) void {
        self.flushBeat();
        self.advanceBeat();
    }

    pub fn getState(self: *const Runner) RunnerState {
        return self.runner_state;
    }

    // ── Internal ──

    fn currentBeat(self: *const Runner) ?ProgrammeBeat {
        if (self.beat_index >= self.scene.len) return null;
        return self.scene[self.beat_index];
    }

    fn enterBeat(self: *Runner) void {
        _ = self.eval_arena.reset(.retain_capacity);
        self.node_index = 0;
        self.current_text = "";
        self.char_index = 0;
        self.deferred_queue.clearRetainingCapacity();

        if (self.currentBeat() == null) {
            self.runner_state = .done;
            return;
        }

        self.runner_state = .emitting;
    }

    /// Process one step of the runner. Returns true if more processing may
    /// be possible this frame, false if we should stop (timer exhausted or done).
    fn step(self: *Runner, ms_per_char: f64) bool {
        if (self.runner_state != .emitting) return false;

        // If we have pending chars in the current text node, try to drip one.
        if (self.current_text.len > 0) {
            if (self.char_index < self.current_text.len) {
                if (self.char_timer < ms_per_char) return false;
                self.render_target.appendChar(self.current_text[self.char_index]);
                self.char_index += 1;
                self.char_timer -= ms_per_char;
                return true;
            }
            // Current text node exhausted; advance to the next node.
            self.node_index += 1;
            self.current_text = "";
            self.char_index = 0;
        }

        return self.loadNode();
    }

    /// Load and process the node at the current node_index.
    /// Free nodes (instant, void) are consumed immediately and return true.
    /// Char nodes set current_text and return true (to drip on next step).
    /// Returns false when the section is exhausted (sets state to waiting).
    fn loadNode(self: *Runner) bool {
        const beat = self.currentBeat() orelse {
            self.runner_state = .waiting;
            return false;
        };

        if (self.node_index >= beat.len) {
            self.runner_state = .waiting;
            return false;
        }

        switch (beat[self.node_index]) {
            .lish_inline => |expr| {
                // Fires at typewriter position — immediately before the next character.
                self.node_index += 1;
                self.executeSideEffect(expr);
                return true;
            },
            .lish_defer => |expr| {
                // Queued for confirm time — fires when the player advances.
                self.node_index += 1;
                self.deferred_queue.append(self.allocator, expr) catch {};
                return true;
            },
            .instant_string => |str| {
                self.render_target.appendText(str);
                self.node_index += 1;
                return true;
            },
            .instant_lish => |expr| {
                const str = self.evaluateToString(expr);
                if (str.len > 0) self.render_target.appendText(str);
                self.node_index += 1;
                return true;
            },
            .text => |str| {
                if (self.instant_mode) {
                    self.render_target.appendText(str);
                    self.node_index += 1;
                    return true;
                }
                self.current_text = str;
                self.char_index = 0;
                return true;
            },
            .char_string => |str| {
                // Always char-by-char regardless of instant_mode.
                self.current_text = str;
                self.char_index = 0;
                return true;
            },
            .char_lish => |expr| {
                // Always char-by-char; evaluate once then drip.
                self.current_text = self.evaluateToString(expr);
                self.char_index = 0;
                return true;
            },
        }
    }

    /// Flush all remaining content in the current beat instantly.
    fn flushBeat(self: *Runner) void {
        const beat = self.currentBeat() orelse {
            self.runner_state = .waiting;
            return;
        };

        // Emit any remaining chars of the current text node.
        if (self.current_text.len > 0) {
            if (self.char_index < self.current_text.len) {
                self.render_target.appendText(self.current_text[self.char_index..]);
            }
            self.current_text = "";
            self.char_index = 0;
            self.node_index += 1;
        }

        // Process all remaining nodes instantly.
        while (self.node_index < beat.len) {
            const prog_node = beat[self.node_index];
            self.node_index += 1;
            switch (prog_node) {
                .lish_inline => |expr| self.executeSideEffect(expr),
                .lish_defer => |expr| self.deferred_queue.append(self.allocator, expr) catch {},
                .text, .char_string => |str| self.render_target.appendText(str),
                .instant_string => |str| self.render_target.appendText(str),
                .char_lish, .instant_lish => |expr| {
                    const str = self.evaluateToString(expr);
                    if (str.len > 0) self.render_target.appendText(str);
                },
            }
        }

        self.runner_state = .waiting;
    }

    fn advanceBeat(self: *Runner) void {
        // Drain deferred queue by swapping it out before iterating.
        // This keeps the list stable even if a command (e.g. scene op) calls
        // enterBeat() and clears self.deferred_queue mid-execution.
        var pending = self.deferred_queue;
        self.deferred_queue = .{};
        defer pending.deinit(self.allocator);

        for (pending.items) |expr| {
            self.executeSideEffect(expr);
        }

        self.render_target.clear();

        // If a deferred command changed runner state (e.g. scene op called
        // loadScene which called enterBeat), don't auto-advance.
        if (self.runner_state != .waiting) return;

        self.beat_index += 1;
        if (self.beat_index >= self.scene.len) {
            self.runner_state = .done;
            return;
        }
        self.enterBeat();
    }

    fn executeSideEffect(self: *Runner, expr: lish.exec.Expression) void {
        var env = lish.Env{
            .registry = self.registry,
            .allocator = self.eval_arena.allocator(),
        };
        _ = env.processExpression(expr, self.scope) catch |err| {
            const message = switch (err) {
                error.RuntimeError => env.runtime_error orelse "unknown error",
                error.OutOfMemory => "out of memory",
            };
            self.render_target.reportError(message);
        };
    }

    fn evaluateToString(self: *Runner, expr: lish.exec.Expression) []const u8 {
        const eval_alloc = self.eval_arena.allocator();
        var env = lish.Env{
            .registry = self.registry,
            .allocator = eval_alloc,
        };
        const result = env.processExpression(expr, self.scope) catch |err| {
            const message = switch (err) {
                error.RuntimeError => env.runtime_error orelse "unknown error",
                error.OutOfMemory => "out of memory",
            };
            self.render_target.reportError(message);
            return "";
        };
        const value = result orelse return "";
        return valueToString(value, eval_alloc) catch return "";
    }

    fn valueToString(value: lish.Value, allocator: Allocator) Allocator.Error![]const u8 {
        return switch (value) {
            .string => |str| str,
            .int => |n| std.fmt.allocPrint(allocator, "{}", .{n}),
            .float => |f| std.fmt.allocPrint(allocator, "{d}", .{f}),
            .list => |items| blk: {
                if (items.len == 0) break :blk "";
                var buf: std.ArrayListUnmanaged(u8) = .{};
                var first = true;
                for (items) |maybe_item| {
                    const item = maybe_item orelse continue;
                    if (!first) try buf.append(allocator, ' ');
                    first = false;
                    const item_str = try valueToString(item, allocator);
                    try buf.appendSlice(allocator, item_str);
                }
                break :blk buf.items;
            },
        };
    }
};

// ── Tests ──

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");

fn parseAndCompile(source: []const u8, allocator: Allocator) !prog_mod.Programme {
    var script = blk: {
        const tokens = try lexer.tokenize(source, allocator);
        defer allocator.free(tokens);
        break :blk try parser.parse(tokens, allocator);
    };
    defer script.deinit();

    var result = try prog_mod.compile(&script, allocator);
    return switch (result) {
        .ok => |prog| prog,
        .err => |*errors| {
            errors.deinit();
            return error.CompileFailed;
        },
    };
}

const TestTarget = struct {
    allocator: Allocator,
    buffer: std.ArrayListUnmanaged(u8),
    clears: usize,
    /// Slices into the runner's eval arena — valid as long as the runner is alive.
    error_log: std.ArrayListUnmanaged([]const u8),

    fn init(allocator: Allocator) TestTarget {
        return .{ .allocator = allocator, .buffer = .{}, .clears = 0, .error_log = .{} };
    }

    fn deinit(self: *TestTarget) void {
        self.buffer.deinit(self.allocator);
        self.error_log.deinit(self.allocator);
    }

    fn renderTarget(self: *TestTarget) RenderTarget {
        return .{ .context = self, .vtable = &vtable };
    }

    fn output(self: *const TestTarget) []const u8 {
        return self.buffer.items;
    }

    const vtable = RenderTarget.Vtable{
        .appendChar = appendChar,
        .appendText = appendText,
        .clear = clear,
        .reportError = reportError,
    };

    fn appendChar(ctx: *anyopaque, char: u8) void {
        const self: *TestTarget = @ptrCast(@alignCast(ctx));
        self.buffer.append(self.allocator, char) catch {};
    }

    fn appendText(ctx: *anyopaque, text: []const u8) void {
        const self: *TestTarget = @ptrCast(@alignCast(ctx));
        self.buffer.appendSlice(self.allocator, text) catch {};
    }

    fn clear(ctx: *anyopaque) void {
        const self: *TestTarget = @ptrCast(@alignCast(ctx));
        self.buffer.clearRetainingCapacity();
        self.clears += 1;
    }

    fn reportError(ctx: *anyopaque, message: []const u8) void {
        const self: *TestTarget = @ptrCast(@alignCast(ctx));
        self.error_log.append(self.allocator, message) catch {};
    }
};

test "loadScene returns false for unknown scene" {
    var prog = try parseAndCompile("::main\nHello.", std.testing.allocator);
    defer prog.deinit();

    var target = TestTarget.init(std.testing.allocator);
    defer target.deinit();

    var registry = lish.Registry{};
    var runner = Runner.init(&prog, &registry, &lish.Scope.EMPTY, target.renderTarget(), .{}, std.testing.allocator);
    defer runner.deinit();

    try std.testing.expect(!runner.loadScene("unknown"));
    try std.testing.expectEqual(RunnerState.done, runner.getState());
}

test "advance emits text character by character" {
    var prog = try parseAndCompile("::main\nhello", std.testing.allocator);
    defer prog.deinit();

    var target = TestTarget.init(std.testing.allocator);
    defer target.deinit();

    var registry = lish.Registry{};
    // 1 char per second → ms_per_char = 1000ms; advance(1000) emits exactly 1 char
    var runner = Runner.init(&prog, &registry, &lish.Scope.EMPTY, target.renderTarget(), .{ .chars_per_sec = 1.0 }, std.testing.allocator);
    defer runner.deinit();

    _ = runner.loadScene("main");

    _ = runner.advance(1000.0);
    try std.testing.expectEqualStrings("h", target.output());

    _ = runner.advance(1000.0);
    try std.testing.expectEqualStrings("he", target.output());

    _ = runner.advance(1000.0);
    try std.testing.expectEqualStrings("hel", target.output());
}

test "advance completes section and enters waiting state" {
    var prog = try parseAndCompile("::main\nhi", std.testing.allocator);
    defer prog.deinit();

    var target = TestTarget.init(std.testing.allocator);
    defer target.deinit();

    var registry = lish.Registry{};
    var runner = Runner.init(&prog, &registry, &lish.Scope.EMPTY, target.renderTarget(), .{ .chars_per_sec = 1.0 }, std.testing.allocator);
    defer runner.deinit();

    _ = runner.loadScene("main");

    // "hi" = 2 chars; 2000ms covers both
    const state = runner.advance(2000.0);
    try std.testing.expectEqualStrings("hi", target.output());
    try std.testing.expectEqual(RunnerState.waiting, state);
}

test "instant_string emits all at once" {
    var prog = try parseAndCompile("::main\n#\"hello\"", std.testing.allocator);
    defer prog.deinit();

    var target = TestTarget.init(std.testing.allocator);
    defer target.deinit();

    var registry = lish.Registry{};
    // Very slow typewriter — instant_string should bypass it entirely
    var runner = Runner.init(&prog, &registry, &lish.Scope.EMPTY, target.renderTarget(), .{ .chars_per_sec = 0.001 }, std.testing.allocator);
    defer runner.deinit();

    _ = runner.loadScene("main");
    _ = runner.advance(1.0);

    // Instant string appears even though timer hasn't budged enough for chars
    try std.testing.expectEqualStrings("hello", target.output());
    try std.testing.expectEqual(RunnerState.waiting, runner.getState());
}

test "char_string always typewriter even in instant_mode" {
    var prog = try parseAndCompile("::main\n@\"hi\"", std.testing.allocator);
    defer prog.deinit();

    var target = TestTarget.init(std.testing.allocator);
    defer target.deinit();

    var registry = lish.Registry{};
    var runner = Runner.init(&prog, &registry, &lish.Scope.EMPTY, target.renderTarget(), .{ .chars_per_sec = 1.0 }, std.testing.allocator);
    defer runner.deinit();

    _ = runner.loadScene("main");
    runner.instant_mode = true;

    // Only one char-worth of time — should emit 'h' only
    _ = runner.advance(1000.0);
    try std.testing.expectEqualStrings("h", target.output());
    try std.testing.expectEqual(RunnerState.emitting, runner.getState());
}

test "confirm advances to next section and clears" {
    const source =
        \\::main
        \\Hello.
        \\;;
        \\World.
    ;
    var prog = try parseAndCompile(source, std.testing.allocator);
    defer prog.deinit();

    var target = TestTarget.init(std.testing.allocator);
    defer target.deinit();

    var registry = lish.Registry{};
    var runner = Runner.init(&prog, &registry, &lish.Scope.EMPTY, target.renderTarget(), .{ .chars_per_sec = 1.0 }, std.testing.allocator);
    defer runner.deinit();

    _ = runner.loadScene("main");

    // Finish section 1
    _ = runner.advance(1_000_000.0);
    try std.testing.expectEqual(RunnerState.waiting, runner.getState());

    runner.confirm();

    // clear() should have been called; buffer reset
    try std.testing.expectEqual(@as(usize, 1), target.clears);
    try std.testing.expectEqual(RunnerState.emitting, runner.getState());
}

test "confirm with confirm_skips flushes remaining text" {
    var prog = try parseAndCompile("::main\nhello", std.testing.allocator);
    defer prog.deinit();

    var target = TestTarget.init(std.testing.allocator);
    defer target.deinit();

    var registry = lish.Registry{};
    var runner = Runner.init(&prog, &registry, &lish.Scope.EMPTY, target.renderTarget(), .{ .chars_per_sec = 1.0, .confirm_skips = true }, std.testing.allocator);
    defer runner.deinit();

    _ = runner.loadScene("main");

    // Emit only 'h'
    _ = runner.advance(1000.0);
    try std.testing.expectEqualStrings("h", target.output());

    // Confirm while still emitting — should flush rest
    runner.confirm();
    try std.testing.expectEqualStrings("hello", target.output());
    try std.testing.expectEqual(RunnerState.waiting, runner.getState());
}

test "confirm without confirm_skips does not flush" {
    var prog = try parseAndCompile("::main\nhello", std.testing.allocator);
    defer prog.deinit();

    var target = TestTarget.init(std.testing.allocator);
    defer target.deinit();

    var registry = lish.Registry{};
    var runner = Runner.init(&prog, &registry, &lish.Scope.EMPTY, target.renderTarget(), .{ .chars_per_sec = 1.0, .confirm_skips = false }, std.testing.allocator);
    defer runner.deinit();

    _ = runner.loadScene("main");

    _ = runner.advance(1000.0);
    try std.testing.expectEqualStrings("h", target.output());

    runner.confirm();
    // Still emitting, nothing flushed
    try std.testing.expectEqualStrings("h", target.output());
    try std.testing.expectEqual(RunnerState.emitting, runner.getState());
}

test "last section confirm results in done" {
    var prog = try parseAndCompile("::main\nhi", std.testing.allocator);
    defer prog.deinit();

    var target = TestTarget.init(std.testing.allocator);
    defer target.deinit();

    var registry = lish.Registry{};
    var runner = Runner.init(&prog, &registry, &lish.Scope.EMPTY, target.renderTarget(), .{}, std.testing.allocator);
    defer runner.deinit();

    _ = runner.loadScene("main");
    _ = runner.advance(1_000_000.0);
    try std.testing.expectEqual(RunnerState.waiting, runner.getState());

    runner.confirm();
    try std.testing.expectEqual(RunnerState.done, runner.getState());
}

// ── lish_inline / lish_defer timing tests ──

/// Test-only op that increments a counter each time it is called.
const FireCounter = struct {
    count: usize = 0,

    fn inc(self: *FireCounter, args: lish.Args) lish.exec.ExecError!?lish.Value {
        _ = args;
        self.count += 1;
        return null;
    }
};

test "lish_inline fires between preceding and following text" {
    // Beat: text("A"), lish_inline(ping), text("B")
    // After 'A' is emitted, ping fires and 'B' is loaded — but not yet emitted.
    var prog = try parseAndCompile("::main\nA{ ping }B", std.testing.allocator);
    defer prog.deinit();

    var target = TestTarget.init(std.testing.allocator);
    defer target.deinit();

    var counter = FireCounter{};
    var registry = lish.Registry{};
    defer registry.deinit(std.testing.allocator);
    try registry.registerOperation(
        std.testing.allocator,
        "ping",
        lish.Operation.fromBoundFn(FireCounter, FireCounter.inc, &counter),
    );

    var runner = Runner.init(&prog, &registry, &lish.Scope.EMPTY, target.renderTarget(), .{ .chars_per_sec = 1.0 }, std.testing.allocator);
    defer runner.deinit();
    _ = runner.loadScene("main");

    // 500ms: timer building, nothing emitted yet
    _ = runner.advance(500.0);
    try std.testing.expectEqualStrings("", target.output());
    try std.testing.expectEqual(@as(usize, 0), counter.count);

    // Another 500ms: 'A' emits, ping fires inline, 'B' loaded but not yet emitted
    _ = runner.advance(500.0);
    try std.testing.expectEqualStrings("A", target.output());
    try std.testing.expectEqual(@as(usize, 1), counter.count);
    try std.testing.expectEqual(RunnerState.emitting, runner.getState());
}

test "lish_inline at beat end fires when waiting state begins" {
    // Beat: text("A"), lish_inline(ping) — inline is the last node
    var prog = try parseAndCompile("::main\nA{ ping }", std.testing.allocator);
    defer prog.deinit();

    var target = TestTarget.init(std.testing.allocator);
    defer target.deinit();

    var counter = FireCounter{};
    var registry = lish.Registry{};
    defer registry.deinit(std.testing.allocator);
    try registry.registerOperation(
        std.testing.allocator,
        "ping",
        lish.Operation.fromBoundFn(FireCounter, FireCounter.inc, &counter),
    );

    var runner = Runner.init(&prog, &registry, &lish.Scope.EMPTY, target.renderTarget(), .{ .chars_per_sec = 1.0 }, std.testing.allocator);
    defer runner.deinit();
    _ = runner.loadScene("main");

    _ = runner.advance(1_000_000.0);
    try std.testing.expectEqual(@as(usize, 1), counter.count);
    try std.testing.expectEqual(RunnerState.waiting, runner.getState());
}

test "lish_defer does not fire during advance, fires on confirm" {
    // Beat: text("AB"), lish_defer(ping) — deferred should be silent until confirm
    var prog = try parseAndCompile("::main\nAB%{ ping }", std.testing.allocator);
    defer prog.deinit();

    var target = TestTarget.init(std.testing.allocator);
    defer target.deinit();

    var counter = FireCounter{};
    var registry = lish.Registry{};
    defer registry.deinit(std.testing.allocator);
    try registry.registerOperation(
        std.testing.allocator,
        "ping",
        lish.Operation.fromBoundFn(FireCounter, FireCounter.inc, &counter),
    );

    var runner = Runner.init(&prog, &registry, &lish.Scope.EMPTY, target.renderTarget(), .{ .chars_per_sec = 1.0 }, std.testing.allocator);
    defer runner.deinit();
    _ = runner.loadScene("main");

    _ = runner.advance(1_000_000.0);
    try std.testing.expectEqualStrings("AB", target.output());
    try std.testing.expectEqual(RunnerState.waiting, runner.getState());
    // Deferred command has NOT fired yet
    try std.testing.expectEqual(@as(usize, 0), counter.count);

    runner.confirm();
    // Now it fires
    try std.testing.expectEqual(@as(usize, 1), counter.count);
}

test "lish_defer fires in declaration order" {
    // Two deferred pings — both fire on confirm, first then second
    var prog = try parseAndCompile("::main\n%{ ping }%{ ping }", std.testing.allocator);
    defer prog.deinit();

    var target = TestTarget.init(std.testing.allocator);
    defer target.deinit();

    var counter = FireCounter{};
    var registry = lish.Registry{};
    defer registry.deinit(std.testing.allocator);
    try registry.registerOperation(
        std.testing.allocator,
        "ping",
        lish.Operation.fromBoundFn(FireCounter, FireCounter.inc, &counter),
    );

    var runner = Runner.init(&prog, &registry, &lish.Scope.EMPTY, target.renderTarget(), .{}, std.testing.allocator);
    defer runner.deinit();
    _ = runner.loadScene("main");

    _ = runner.advance(1_000_000.0);
    try std.testing.expectEqual(RunnerState.waiting, runner.getState());
    try std.testing.expectEqual(@as(usize, 0), counter.count);

    runner.confirm();
    try std.testing.expectEqual(@as(usize, 2), counter.count);
}

// ── Error reporting tests ──

test "lish_inline runtime error is reported" {
    // 'unknown' is not registered — should produce a runtime error
    var prog = try parseAndCompile("::main\nA{ unknown }B", std.testing.allocator);
    defer prog.deinit();

    var target = TestTarget.init(std.testing.allocator);
    defer target.deinit();

    var registry = lish.Registry{};
    var runner = Runner.init(&prog, &registry, &lish.Scope.EMPTY, target.renderTarget(), .{}, std.testing.allocator);
    defer runner.deinit();
    _ = runner.loadScene("main");

    _ = runner.advance(1_000_000.0);

    try std.testing.expectEqual(@as(usize, 1), target.error_log.items.len);
}

test "lish_defer runtime error is reported on confirm" {
    var prog = try parseAndCompile("::main\nAB%{ unknown }", std.testing.allocator);
    defer prog.deinit();

    var target = TestTarget.init(std.testing.allocator);
    defer target.deinit();

    var registry = lish.Registry{};
    var runner = Runner.init(&prog, &registry, &lish.Scope.EMPTY, target.renderTarget(), .{}, std.testing.allocator);
    defer runner.deinit();
    _ = runner.loadScene("main");

    _ = runner.advance(1_000_000.0);
    // No errors yet — deferred has not fired
    try std.testing.expectEqual(@as(usize, 0), target.error_log.items.len);
    try std.testing.expectEqual(RunnerState.waiting, runner.getState());

    runner.confirm();
    try std.testing.expectEqual(@as(usize, 1), target.error_log.items.len);
}

test "instant_lish runtime error is reported and output is empty" {
    var prog = try parseAndCompile("::main\n#{ unknown }", std.testing.allocator);
    defer prog.deinit();

    var target = TestTarget.init(std.testing.allocator);
    defer target.deinit();

    var registry = lish.Registry{};
    var runner = Runner.init(&prog, &registry, &lish.Scope.EMPTY, target.renderTarget(), .{}, std.testing.allocator);
    defer runner.deinit();
    _ = runner.loadScene("main");

    _ = runner.advance(1_000_000.0);

    try std.testing.expectEqual(@as(usize, 1), target.error_log.items.len);
    try std.testing.expectEqualStrings("", target.output());
}

// ── ffwd op tests ──

const ops_mod = @import("ops.zig");

test "ffwd with no args toggles confirm_skips" {
    // Start with confirm_skips = true; { ffwd } should flip it to false
    var prog = try parseAndCompile("::main\n{ ffwd }", std.testing.allocator);
    defer prog.deinit();

    var target = TestTarget.init(std.testing.allocator);
    defer target.deinit();

    var registry = lish.Registry{};
    defer registry.deinit(std.testing.allocator);

    var runner = Runner.init(&prog, &registry, &lish.Scope.EMPTY, target.renderTarget(), .{ .confirm_skips = true }, std.testing.allocator);
    defer runner.deinit();
    try ops_mod.registerAll(&registry, &runner, std.testing.allocator);

    _ = runner.loadScene("main");
    try std.testing.expect(runner.config.confirm_skips);

    _ = runner.advance(1_000_000.0);
    try std.testing.expect(!runner.config.confirm_skips);
}

test "ffwd with $none disables confirm_skips" {
    var target = TestTarget.init(std.testing.allocator);
    defer target.deinit();

    var registry = lish.Registry{};
    defer registry.deinit(std.testing.allocator);
    try lish.builtins.registerAll(&registry, std.testing.allocator);

    var prog = try parseAndCompile("::main\n{ ffwd $none }", std.testing.allocator);
    defer prog.deinit();
    var runner = Runner.init(&prog, &registry, &lish.Scope.EMPTY, target.renderTarget(), .{ .confirm_skips = true }, std.testing.allocator);
    defer runner.deinit();
    try ops_mod.registerAll(&registry, &runner, std.testing.allocator);

    _ = runner.loadScene("main");
    _ = runner.advance(1_000_000.0);
    try std.testing.expect(!runner.config.confirm_skips);
}

test "ffwd with truthy value enables confirm_skips" {
    var target = TestTarget.init(std.testing.allocator);
    defer target.deinit();

    var registry = lish.Registry{};
    defer registry.deinit(std.testing.allocator);

    var prog = try parseAndCompile("::main\n{ ffwd \"yes\" }", std.testing.allocator);
    defer prog.deinit();
    var runner = Runner.init(&prog, &registry, &lish.Scope.EMPTY, target.renderTarget(), .{ .confirm_skips = false }, std.testing.allocator);
    defer runner.deinit();
    try ops_mod.registerAll(&registry, &runner, std.testing.allocator);

    _ = runner.loadScene("main");
    _ = runner.advance(1_000_000.0);
    try std.testing.expect(runner.config.confirm_skips);
}

test "loadScene resets confirm_skips to configured default" {
    const source =
        \\::main
        \\{ ffwd $none }
        \\
        \\::other
        \\hello
    ;
    var prog = try parseAndCompile(source, std.testing.allocator);
    defer prog.deinit();

    var target = TestTarget.init(std.testing.allocator);
    defer target.deinit();

    var registry = lish.Registry{};
    defer registry.deinit(std.testing.allocator);
    try lish.builtins.registerAll(&registry, std.testing.allocator);

    var runner = Runner.init(&prog, &registry, &lish.Scope.EMPTY, target.renderTarget(), .{ .confirm_skips = true }, std.testing.allocator);
    defer runner.deinit();
    try ops_mod.registerAll(&registry, &runner, std.testing.allocator);

    _ = runner.loadScene("main");
    _ = runner.advance(1_000_000.0);
    // ffwd $none ran — confirm_skips should now be false
    try std.testing.expect(!runner.config.confirm_skips);

    // Loading a new scene resets to the configured default (true)
    _ = runner.loadScene("other");
    try std.testing.expect(runner.config.confirm_skips);
}
