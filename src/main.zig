const std = @import("std");

pub const tty = @import("tty.zig");

pub const Vaxis = @import("Vaxis.zig");

pub const loop = @import("Loop.zig");
pub const Loop = loop.Loop;

pub const zigimg = @import("zigimg");

pub const Queue = @import("queue.zig").Queue;
pub const Key = @import("Key.zig");
pub const Cell = @import("Cell.zig");
pub const Segment = Cell.Segment;
pub const PrintOptions = Window.PrintOptions;
pub const Style = Cell.Style;
pub const Color = Cell.Color;
pub const Image = @import("Image.zig");
pub const Mouse = @import("Mouse.zig");
pub const Screen = @import("Screen.zig");
pub const AllocatingScreen = @import("InternalScreen.zig");
pub const Parser = @import("Parser.zig");
pub const Window = @import("Window.zig");
pub const widgets = @import("widgets.zig");
pub const gwidth = @import("gwidth.zig");
pub const ctlseqs = @import("ctlseqs.zig");

const log = std.log.scoped(.vaxis);
pub const GraphemeCache = @import("GraphemeCache.zig");
pub const Event = @import("event.zig").Event;
pub const unicode = @import("unicode.zig");

pub const vxfw = @import("vxfw/vxfw.zig");

pub const Tty = tty.Tty;

/// The size of the terminal screen
pub const Winsize = struct {
    rows: u16,
    cols: u16,
    x_pixel: u16,
    y_pixel: u16,
};

/// Initialize a Vaxis application.
pub fn init(io: std.Io, alloc: std.mem.Allocator, env_map: *std.process.Environ.Map, opts: Vaxis.Options) !Vaxis {
    return Vaxis.init(io, alloc, env_map, opts);
}

/// Panic namespace for `pub const panic = vaxis.Panic;`.
///
/// `std.debug.FullPanic` supplies every safety-panic handler the compiler needs;
/// only the top-level `call` is ours, so the terminal is reset first.
pub const Panic = std.debug.FullPanic(panicCall);

/// Resets terminal state on a panic, then calls the default zig panic handler.
///
/// This is the legacy form, for `pub const panic = vaxis.panicHandler;`. Apps on
/// the `std.builtin.Panic` interface want `pub const panic = vaxis.Panic;`, which
/// routes through `panicCall` instead.
pub fn panicHandler(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    recover();
    std.debug.defaultPanic(msg, ret_addr);
}

/// `Panic.call`: the two-argument shape `std.builtin.Panic` requires.
///
/// Kept separate from `panicHandler` so both spellings of the root `panic`
/// declaration keep working.
fn panicCall(msg: []const u8, ret_addr: ?usize) noreturn {
    recover();
    std.debug.defaultPanic(msg, ret_addr);
}

/// Resets the terminal state using the global tty instance. Use this only to recover during a panic
pub fn recover() void {
    if (tty.global_tty) |*gty| {
        const reset: []const u8 = ctlseqs.csi_u_pop ++
            ctlseqs.mouse_reset ++
            ctlseqs.bp_reset ++
            ctlseqs.rmcup;

        // Called from the panic handler, so std.log may lock or allocate here.
        // The reset is best effort either way; report why it failed.
        gty.writer().writeAll(reset) catch |err|
            log.err("could not reset the terminal on panic: {t}", .{err});
        gty.writer().flush() catch |err|
            log.err("could not flush the terminal reset on panic: {t}", .{err});
        gty.deinit();
    }
}

pub const log_scopes = enum {
    vaxis,
};

/// the vaxis logo. In PixelCode
pub const logo =
    \\▄   ▄  ▄▄▄  ▄   ▄ ▄▄▄  ▄▄▄
    \\█   █ █▄▄▄█ ▀▄ ▄▀  █  █   ▀
    \\▀▄ ▄▀ █   █  ▄▀▄   █   ▀▀▀▄
    \\ ▀▄▀  █   █ █   █ ▄█▄ ▀▄▄▄▀
;

test "refAllDecls" {
    std.testing.refAllDecls(@This());
}
