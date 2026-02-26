# folio-zig

A dialogue scripting DSL for games. folio lets you write scenes and beats as plain text, embed lish expressions for logic and side-effects, and drive playback through a host-controlled Runner. It is designed to be embedded in game engines or other interactive applications.

Built on [lish-zig](https://github.com/mhogle25/lish-zig).

## Script Syntax

A folio script is a collection of named **scenes**, each composed of **beats**. A beat is one page of content — the player sees it, confirms, and moves on.

### Scenes and Beats

```
::main
Hello there.
;;
Are you still with me?
;;
Good.

::elsewhere
This is a different scene.
```

- `::name` declares a new scene. Scripts must have a `main` scene.
- `;;` separates beats within a scene.
- Every script must contain a `::main` scene.

### Text Sigils

| Text & Sigils | Name | Behavior |
|---------------|------|----------|
| *(plain text)* | text | Typewriter character-by-character. Affected by `instant` mode. |
| `#"..."` | instant string | Displayed all at once, bypasses typewriter. |
| `@"..."` | char string | Always typewriter, even when instant mode is on. |
| `{ lish }` | lish inline | Evaluates a lish expression at typewriter position (before the next character). Side-effects only. |
| `%{ lish }` | lish defer | Queues a lish expression to fire when the player confirms. Side-effects only. |
| `#{ lish }` | instant lish | Evaluates a lish expression and displays the result instantly as text. |
| `@{ lish }` | char lish | Evaluates a lish expression and displays the result character-by-character. |

### Example Script

```
::main
#"Stranger:"
You there.
;;
Yes, you. Don't look so alarmed.
;;
#"Stranger:"
I just need...{ delay medium } directions.
;;
The stranger pulls out a crumpled map.
;;
#"Stranger:"
The market. Do you know it?
;;
#"You:"
Follow the main road south — you can't miss it.
;;
The stranger folds the map and walks away.%{ scene market }

::market
#{ concat "The market is " "loud and bright" } — a stark contrast to the cold square.
```

In this example:
- `#"Stranger:"` displays the speaker label instantly.
- `{ delay medium }` pauses the typewriter mid-sentence.
- `%{ scene market }` jumps to the `market` scene when the player confirms the current beat.
- `#{ concat ... }` evaluates a lish expression and inserts the result as instant text.

## Installation

Requires **Zig 0.15.2** or later.

Add as a dependency in your `build.zig.zon`:

```
zig fetch --save git+https://github.com/mhogle25/folio-zig.git
```

Wire it up in `build.zig` alongside lish:

```zig
const lish_dep = b.dependency("lish", .{ .target = target, .optimize = optimize });
const lish_mod = lish_dep.module("lish");

const folio_dep = b.dependency("folio", .{ .target = target, .optimize = optimize });
const folio_mod = folio_dep.module("folio");

your_module.addImport("lish", lish_mod);
your_module.addImport("folio", folio_mod);
```

## Usage

### Loading and Compiling a Script

```zig
const folio = @import("folio");

// Read source text
const source = try std.fs.cwd().readFileAlloc(allocator, "scene.folio", 1024 * 1024);
defer allocator.free(source);

// Tokenize and parse into a Script (raw AST)
const tokens = try folio.lexer.tokenize(source, allocator);
defer allocator.free(tokens);

var script = try folio.parser.parse(tokens, allocator);
defer script.deinit();

// Compile into an executable Programme
var compile_result = try folio.programme.compile(&script, allocator);
// script can be deinited after compile — Programme is fully independent

var prog = switch (compile_result) {
    .ok => |p| p,
    .err => |*errors| {
        defer errors.deinit();
        for (errors.items) |node_err| {
            for (node_err.errors) |verr| {
                std.debug.print("[{s} beat {d}] {s}\n", .{
                    node_err.scene, node_err.beat_index, verr.message,
                });
            }
        }
        return error.CompileFailed;
    },
};
defer prog.deinit();
```

### Runner Integration

The `Runner` drives a compiled `Programme` through a `RenderTarget` interface. Implement `RenderTarget.Vtable` to connect folio output to your renderer or UI system.

```zig
const folio = @import("folio");
const lish = @import("lish");

const Runner = folio.runner.Runner;
const RenderTarget = folio.runner.RenderTarget;

// 1. Implement RenderTarget.Vtable
const MyTarget = struct {
    fn renderTarget(self: *MyTarget) RenderTarget {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = RenderTarget.Vtable{
        .appendChar = appendChar,
        .appendText = appendText,
        .clear = clear,
        .reportError = reportError,
    };

    fn appendChar(ctx: *anyopaque, char: u8) void {
        const self: *MyTarget = @ptrCast(@alignCast(ctx));
        _ = self;
        // emit one character to your renderer
    }

    fn appendText(ctx: *anyopaque, text: []const u8) void {
        const self: *MyTarget = @ptrCast(@alignCast(ctx));
        _ = self;
        // emit a full string at once (instant display)
    }

    fn clear(ctx: *anyopaque) void {
        const self: *MyTarget = @ptrCast(@alignCast(ctx));
        _ = self;
        // clear the display (called between beats)
    }

    fn reportError(ctx: *anyopaque, message: []const u8) void {
        const self: *MyTarget = @ptrCast(@alignCast(ctx));
        _ = self;
        // display or log a lish runtime error
        _ = message;
    }
};

// 2. Set up registry and runner
var registry = lish.Registry{};
defer registry.deinit(allocator);
try lish.builtins.registerAll(&registry, allocator);

var my_target = MyTarget{};
var runner = Runner.init(
    &prog,
    &registry,
    &lish.Scope.EMPTY,
    my_target.renderTarget(),
    .{ .chars_per_sec = 60.0 },
    allocator,
);
defer runner.deinit();

// Register folio's built-in ops (instant, speed, delay, scene, skip, continue, clear)
try folio.ops.registerAll(&registry, &runner, allocator);

// 3. Load a scene and drive the loop
_ = runner.loadScene("main");

// Call advance() every frame with the elapsed time in milliseconds
const state = runner.advance(delta_ms);

// When state is .waiting, show a prompt and wait for the player
if (state == .waiting) {
    // player presses confirm...
    runner.confirm();
}
```

### Runner State Machine

```
loadScene()
    │
    ▼
 emitting ──advance()──► emitting (typewriter in progress)
    │                        │
    │                        ▼ (beat complete)
    │                     waiting ──confirm()──► emitting (next beat)
    │                                               │
    │                                               ▼ (last beat)
    └───────────────────────────────────────────► done
```

| State | Meaning |
|-------|---------|
| `emitting` | Typewriter is actively outputting characters |
| `waiting` | Current beat is fully displayed; waiting for `confirm()` |
| `done` | All beats played; scene is complete |

### RunnerConfig

```zig
pub const RunnerConfig = struct {
    /// Characters emitted per second during typewriter effect. Default: 60.0
    chars_per_sec: f64 = 60.0,
    /// If true, confirm() while emitting flushes the current beat instantly. Default: true
    confirm_skips: bool = true,
};
```

## Built-in Ops

`folio.ops.registerAll` registers these operations into your lish registry:

| Op | Args | Description |
|----|------|-------------|
| `instant` | 0 or 1 | Toggle instant mode (0 args), or set it by truthiness (1 arg) |
| `ffwd` | 0 or 1 | Toggle fast-forward mode (0 args), or set it by truthiness (1 arg). When enabled, confirm() while the typewriter is emitting flushes the beat instantly. |
| `speed` | 0 or 1 | Set typewriter speed: `"slow"` (30), `"normal"` (60), `"fast"` (120), or a number (chars/sec). No arguments resets to the host-configured default. |
| `delay` | 1 | Pause typewriter: `"short"` (250ms), `"medium"` (500ms), `"long"` (1000ms), or a number (ms) |
| `scene` | 1 | Jump to a named scene |
| `skip` | 0 | Flush current beat and immediately advance to the next |
| `continue` | 0 | Flush current beat to waiting state without advancing |
| `clear` | 0 | Clear the render target |

These map directly to runner behavior — no game-specific rendering logic is included.

## Scope Integration

Pass game state into folio scripts via a `lish.Scope`. Variables set on the scope are accessible from any embedded lish expression using `:varname`.

```zig
var scope = lish.Scope{};

// Bind a static value (evaluated once)
try scope.setValue(allocator, "playerName", .{ .string = "Aiden" });

// Bind a lazily-evaluated expression (re-evaluated each access)
const greet_expr = ...; // lish.exec.Expression
try scope.setExpression(allocator, "greeting", greet_expr);

var runner = Runner.init(&prog, &registry, &scope, target, .{}, allocator);
```

In the script:
```
Hello, #{ identity :playerName }.
```

## Terminal Player

folio-zig ships a terminal player for previewing scripts during development.

```sh
# Build
zig build

# Play a script
zig build run -- demo.folio

# Start from a specific scene
zig build run -- demo.folio --scene market
```

**Controls:**

| Key | Action |
|-----|--------|
| Space / Enter | Advance beat (or skip typewriter if still emitting) |
| `q` / Ctrl+C | Quit |

The terminal player prints `---` between beats and shows a `▶` prompt when waiting for input.

## Building

```sh
# Run all tests
zig build test

# Build library + terminal player
zig build
```

## Architecture

| File | Purpose |
|------|---------|
| `root.zig` | Public API re-exports |
| `token.zig` | Token types and syntax constants |
| `lexer.zig` | Tokenizer — converts folio source to tokens |
| `node.zig` | AST node types: `Script`, `Scene`, `Beat`, `Node` |
| `parser.zig` | Converts token stream into a `Script` |
| `programme.zig` | Compiles a `Script` into an executable `Programme` |
| `runner.zig` | Drives a `Programme` via `RenderTarget`; typewriter, beats, deferred ops |
| `ops.zig` | folio built-in lish operations (instant, speed, delay, scene, skip, continue, clear) |
| `main.zig` | Terminal player entry point |

## License

[MIT](LICENSE)
