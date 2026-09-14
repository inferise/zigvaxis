//! A PTY pair
const Pty = @This();

const std = @import("std");
const builtin = @import("builtin");
const Winsize = @import("../../main.zig").Winsize;

const posix = std.posix;

/// Darwin's pty interface, which std does not expose.
///
/// The ioctl numbers are stable ABI values from <sys/ttycom.h>; `std.c.T` does
/// not carry them on this target.
const darwin = struct {
    /// Darwin's `ioctl` takes a signed request; the constants have the high bit
    /// set, so they are bit-cast rather than converted.
    pub const Request = c_int;
    pub fn req(comptime value: u32) Request {
        return @bitCast(value);
    }

    pub const IOCSWINSZ: u32 = 0x80087467;
    pub const IOCSCTTY: u32 = 0x20007461;
    const O_RDWR: c_int = 0x0002;
    const O_NOCTTY: c_int = 0x20000;

    extern "c" fn posix_openpt(oflag: c_int) c_int;
    extern "c" fn grantpt(fd: c_int) c_int;
    extern "c" fn unlockpt(fd: c_int) c_int;
    extern "c" fn ptsname(fd: c_int) ?[*:0]u8;
};

/// Terminal ioctl numbers for the host. Selected at comptime, so only the
/// matching branch is analysed.
pub const T = switch (builtin.os.tag) {
    .linux => struct {
        pub const Request = u32;
        pub fn req(comptime value: u32) Request {
            return value;
        }

        pub const IOCSWINSZ: u32 = posix.T.IOCSWINSZ;
        pub const IOCSCTTY: u32 = posix.T.IOCSCTTY;
    },
    .macos, .ios, .tvos, .watchos, .visionos => darwin,
    else => @compileError("unsupported os"),
};

pty: std.Io.File,
tty: std.Io.File,

/// opens a new tty/pty pair
pub fn init(io: std.Io) !Pty {
    switch (builtin.os.tag) {
        .linux => return openPtyLinux(io),
        .macos, .ios, .tvos, .watchos, .visionos => return openPtyDarwin(io),
        else => @compileError("unsupported os"),
    }
}

/// closes the tty and pty
pub fn deinit(self: Pty, io: std.Io) void {
    self.pty.close(io);
    self.tty.close(io);
}

/// sets the size of the pty
pub fn setSize(self: Pty, ws: Winsize) !void {
    const _ws: posix.winsize = .{
        .row = @truncate(ws.rows),
        .col = @truncate(ws.cols),
        .xpixel = @truncate(ws.x_pixel),
        .ypixel = @truncate(ws.y_pixel),
    };
    if (posix.system.ioctl(self.pty.handle, comptime T.req(T.IOCSWINSZ), @intFromPtr(&_ws)) != 0)
        return error.SetWinsizeError;
}

fn openPtyLinux(io: std.Io) !Pty {
    const pty = try std.Io.Dir.openFileAbsolute(io, "/dev/ptmx", .{
        .mode = .read_write,
        .allow_ctty = false,
    });
    errdefer pty.close(io);

    // unlockpt
    var n: c_uint = 0;
    if (posix.system.ioctl(pty.handle, posix.T.IOCSPTLCK, @intFromPtr(&n)) != 0) return error.IoctlError;

    // ptsname
    if (posix.system.ioctl(pty.handle, @bitCast(@as(c_uint, posix.T.IOCGPTN)), @intFromPtr(&n)) != 0) return error.IoctlError;
    var buf: [16]u8 = undefined;
    const sname = try std.fmt.bufPrint(&buf, "/dev/pts/{d}", .{n});
    std.log.debug("pts: {s}", .{sname});

    const tty = try std.Io.Dir.openFileAbsolute(io, sname, .{
        .mode = .read_write,
        .allow_ctty = false,
    });

    return .{
        .pty = pty,
        .tty = tty,
    };
}

/// opens a pty pair on Darwin, where /dev/ptmx has no Linux-style ioctls
///
/// The name of the slave device is only valid until the next `ptsname` call on
/// this thread, so it is opened immediately rather than stored.
fn openPtyDarwin(io: std.Io) !Pty {
    const master = darwin.posix_openpt(darwin.O_RDWR | darwin.O_NOCTTY);
    if (master < 0) return error.OpenPtyFailed;
    errdefer _ = std.c.close(master);

    if (darwin.grantpt(master) != 0) return error.GrantPtFailed;
    if (darwin.unlockpt(master) != 0) return error.UnlockPtFailed;

    const name = darwin.ptsname(master) orelse return error.PtsNameFailed;
    const sname = std.mem.span(name);
    std.log.debug("pts: {s}", .{sname});

    const tty = try std.Io.Dir.openFileAbsolute(io, sname, .{
        .mode = .read_write,
        .allow_ctty = false,
    });

    return .{
        .pty = .{ .handle = master, .flags = .{ .nonblocking = false } },
        .tty = tty,
    };
}
