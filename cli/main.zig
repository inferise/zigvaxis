const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("zigvaxis");
const cli = @import("module.zig");

/// Log configuration for the executable.
///
/// The demo owns the terminal, so anything written to stderr corrupts the
/// display. Keep logging off unless a debug build asks for it.
pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .err,
};

/// Restores the terminal before the default panic handler runs, so a crash
/// inside a draw call does not leave the shell in raw mode.
pub const panic = vaxis.Panic;

/// Entry point for the zigvaxis demo CLI.
///
/// Keeps the executable thin: the gallery and every demo view live in
/// `cli.DemoApp` so they stay reachable from the unit test suite.
///
/// Parameters:
/// - `init`: process capabilities supplied by the runtime (allocator, IO, environment).
///
/// Return: nothing on success; propagates whatever the app failed with.
pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var app: vxfw.App = try .init(init.io, init.gpa, init.environ_map, &buffer);
    defer app.deinit();

    // The root widget needs a stable address: child widgets store a pointer to
    // it as their userdata, and those pointers outlive any single frame.
    const demo = try init.gpa.create(cli.DemoApp);
    defer init.gpa.destroy(demo);

    demo.* = cli.DemoApp.init(init.io, init.gpa);
    defer demo.deinit();

    try app.run(demo.widget(), .{});
}

const vxfw = vaxis.vxfw;

test {
    std.testing.refAllDecls(@This());
}
