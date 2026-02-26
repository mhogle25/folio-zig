const std = @import("std");
const lish = @import("lish");
const runner_mod = @import("runner.zig");

const Allocator = std.mem.Allocator;
const Args = lish.Args;
const ExecError = lish.exec.ExecError;
const Operation = lish.Operation;
const Registry = lish.Registry;
const Runner = runner_mod.Runner;

/// Register all folio runner ops into the given registry, bound to the given runner.
pub fn registerAll(registry: *Registry, runner: *Runner, allocator: Allocator) Allocator.Error!void {
    try registry.registerOperation(allocator, "instant", Operation.fromBoundFn(Runner, instantOp, runner));
    try registry.registerOperation(allocator, "ffwd", Operation.fromBoundFn(Runner, ffwdOp, runner));
    try registry.registerOperation(allocator, "speed", Operation.fromBoundFn(Runner, speedOp, runner));
    try registry.registerOperation(allocator, "delay", Operation.fromBoundFn(Runner, delayOp, runner));
    try registry.registerOperation(allocator, "scene", Operation.fromBoundFn(Runner, sceneOp, runner));
    try registry.registerOperation(allocator, "skip", Operation.fromBoundFn(Runner, skipOp, runner));
    try registry.registerOperation(allocator, "continue", Operation.fromBoundFn(Runner, continueOp, runner));
    try registry.registerOperation(allocator, "clear", Operation.fromBoundFn(Runner, clearOp, runner));
    try registry.registerOperation(allocator, "end", Operation.fromBoundFn(Runner, endOp, runner));
}

// ── Ops ──

/// Toggle instant mode (0 args), or set it by truthiness (1 arg).
fn instantOp(self: *Runner, args: Args) ExecError!?lish.Value {
    switch (args.count()) {
        0 => self.instant_mode = !self.instant_mode,
        1 => self.instant_mode = (try args.at(0).get()) != null,
        else => return args.env.fail("instant takes 0 or 1 argument"),
    }
    return null;
}

/// Toggle confirm_skips (0 args), or set it by truthiness (1 arg).
fn ffwdOp(self: *Runner, args: Args) ExecError!?lish.Value {
    switch (args.count()) {
        0 => self.config.confirm_skips = !self.config.confirm_skips,
        1 => self.config.confirm_skips = (try args.at(0).get()) != null,
        else => return args.env.fail("ffwd takes 0 or 1 argument"),
    }
    return null;
}

/// Set the typewriter speed. Accepts a number (chars/sec) or one of:
///   "slow" = 30, "normal" = 60, "fast" = 120
/// With no arguments, resets to the host-configured default.
fn speedOp(self: *Runner, args: Args) ExecError!?lish.Value {
    if (args.count() == 0) {
        self.config.chars_per_sec = self.base_chars_per_sec;
        return null;
    }
    const value = try args.resolveSingle();
    switch (value) {
        .string => |str| {
            if (std.mem.eql(u8, str, "slow")) {
                self.config.chars_per_sec = 30.0;
            } else if (std.mem.eql(u8, str, "normal")) {
                self.config.chars_per_sec = 60.0;
            } else if (std.mem.eql(u8, str, "fast")) {
                self.config.chars_per_sec = 120.0;
            } else {
                return args.env.fail("speed: unknown constant, expected \"slow\", \"normal\", or \"fast\"");
            }
        },
        .int => |n| self.config.chars_per_sec = @floatFromInt(n),
        .float => |f| self.config.chars_per_sec = f,
        .list => return args.env.fail("speed: expected a number or speed constant"),
    }
    return null;
}

/// Pause the typewriter for a duration. Accepts a number (milliseconds) or one of:
///   "short" = 250, "medium" = 500, "long" = 1000
fn delayOp(self: *Runner, args: Args) ExecError!?lish.Value {
    const value = try args.resolveSingle();
    switch (value) {
        .string => |str| {
            if (std.mem.eql(u8, str, "short")) {
                self.pause_remaining = 250.0;
            } else if (std.mem.eql(u8, str, "medium")) {
                self.pause_remaining = 500.0;
            } else if (std.mem.eql(u8, str, "long")) {
                self.pause_remaining = 1000.0;
            } else {
                return args.env.fail("delay: unknown constant, expected \"short\", \"medium\", or \"long\"");
            }
        },
        .int => |n| self.pause_remaining = @floatFromInt(n),
        .float => |f| self.pause_remaining = f,
        .list => return args.env.fail("delay: expected a number or delay constant"),
    }
    return null;
}

/// Jump to a named scene.
fn sceneOp(self: *Runner, args: Args) ExecError!?lish.Value {
    var name_buf: [256]u8 = undefined;
    const name = try (try args.single()).resolveString(&name_buf);
    if (!self.loadScene(name)) {
        return args.env.fail("scene: unknown scene name");
    }
    return null;
}

/// Flush and immediately advance to the next beat without waiting for confirm.
fn skipOp(self: *Runner, args: Args) ExecError!?lish.Value {
    _ = args;
    self.skipBeat();
    return null;
}

/// Flush the current beat to waiting state without advancing.
fn continueOp(self: *Runner, args: Args) ExecError!?lish.Value {
    _ = args;
    self.continueBeat();
    return null;
}

/// Clear the render target.
fn clearOp(self: *Runner, args: Args) ExecError!?lish.Value {
    _ = args;
    self.render_target.clear();
    return null;
}

/// Immediately end the scene, bypassing any remaining beats.
fn endOp(self: *Runner, args: Args) ExecError!?lish.Value {
    _ = args;
    self.endScene();
    return null;
}
