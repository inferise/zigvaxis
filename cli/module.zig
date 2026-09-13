//! CLI barrel for the zigvaxis demo executable.
//!
//! Re-exports every public type in `cli/` so the entry point imports through
//! this module rather than reaching for sibling files directly.

const std = @import("std");

pub const DemoApp = @import("demo_app.zig").DemoApp;
pub const Gallery = @import("gallery.zig").Gallery;

/// True in Debug builds. Demos use it to show build-mode-dependent detail.
pub const is_debug = @import("builtin").mode == .Debug;

// -----------------------------------------------------------------------------
// Unit Tests

test {
    std.testing.refAllDecls(@This());
}
