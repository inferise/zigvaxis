const std = @import("std");
const vaxis = @import("zigvaxis");

const vxfw = vaxis.vxfw;
const Allocator = std.mem.Allocator;
const gallery = @import("gallery.zig");

const Demo = gallery.Demo;

/// Every demo in menu order, resolved once at comptime.
const demos = std.enums.values(Demo);

/// Row the menu list starts on, leaving space for the title.
const menu_top: u16 = 2;

/// The key that quits from the menu. Selector letters must stay below it so a
/// demo can never claim it.
const quit_key: u8 = 'q';

comptime {
    if (demos.len > quit_key - 'a') {
        @compileError("too many demos: selector letters would reach '" ++ [_]u8{quit_key} ++ "'");
    }
}

/// The selector letter for the demo at `idx`: 0 -> 'a', 1 -> 'b', and so on.
fn selector(idx: usize) u8 {
    return 'a' + @as(u8, @intCast(idx));
}

/// Root widget: a numbered menu of demo views, and the view itself.
///
/// The menu is the base view. Selecting an entry swaps in that demo, and
/// escape returns here. Only one demo is drawn at a time, but every demo's
/// state lives in the `Gallery` for the whole run, so returning to one finds
/// it as you left it.
pub const DemoApp = struct {
    const Self = @This();

    /// The demo on screen, or null while the menu is showing.
    active: ?Demo,

    /// Highlighted menu row.
    cursor: usize,

    /// Owns every stateful demo widget.
    views: gallery.Gallery,

    /// Constructs the app bound to the process capabilities.
    ///
    /// Parameters:
    /// - `io`: IO interface, needed by the spinner demo's timer.
    /// - `allocator`: allocator backing the text field demo.
    ///
    /// Return: an app showing the menu. Call `widget` only after the value has
    /// reached its final address; `Gallery` stores pointers into itself.
    pub fn init(io: std.Io, allocator: std.mem.Allocator) Self {
        return .{
            .active = null,
            .cursor = 0,
            .views = .init(io, allocator),
        };
    }

    /// Releases everything the app owns.
    pub fn deinit(self: *Self) void {
        self.views.deinit();
    }

    /// Returns the type-erased widget for the vxfw runtime.
    ///
    /// Also primes the gallery's self-referential fields, so this must be
    /// called once the app has its final address.
    pub fn widget(self: *Self) vxfw.Widget {
        self.views.prime();
        return .{
            .userdata = self,
            .captureHandler = typeErasedCaptureHandler,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    // -------------------------------------------------------------------------
    // Runtime callbacks

    /// Claims the two keys that must work everywhere, before any child sees them.
    ///
    /// The capture phase runs root-first. ListView and ScrollView both consume
    /// escape for their own scroll handling, so intercepting it in the bubble
    /// phase would never fire while one of them has focus.
    fn typeErasedCaptureHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                    return ctx.consumeEvent();
                }
                if (self.active != null and key.matches(vaxis.Key.escape, .{})) {
                    return self.showMenu(ctx);
                }
            },
            else => {},
        }
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => return ctx.requestFocus(self.widget()),
            .key_press => |key| return self.onKey(ctx, key),
            .mouse => {
                if (self.active) |demo| {
                    if (demo == .events) {
                        self.views.note(event);
                        return ctx.consumeAndRedraw();
                    }
                }
            },
            .focus_in, .focus_out, .mouse_enter, .mouse_leave, .winsize => {
                if (self.active) |demo| {
                    if (demo == .events) {
                        self.views.note(event);
                        ctx.redraw = true;
                    }
                }
            },
            else => {},
        }
    }

    /// Handles a key press for whichever view is showing.
    fn onKey(self: *Self, ctx: *vxfw.EventContext, key: vaxis.Key) anyerror!void {
        if (self.active) |demo| {
            if (demo == .events) self.views.note(.{ .key_press = key });
            // ctrl+c and escape are claimed in the capture phase. The text field
            // wants every other key, including q and the digits.
            if (demo != .text_field and key.matches('q', .{})) return self.showMenu(ctx);
            if (demo == .events) return ctx.consumeAndRedraw();
            return;
        }

        // Menu navigation. Checked before the letter range below, which the
        // comptime guard keeps clear of this key.
        if (key.matches(quit_key, .{})) {
            ctx.quit = true;
            return;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            self.cursor = (self.cursor + 1) % demos.len;
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.up, .{})) {
            self.cursor = if (self.cursor == 0) demos.len - 1 else self.cursor - 1;
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.space, .{})) {
            return self.open(ctx, demos[self.cursor]);
        }
        // Letter keys jump straight to a demo. 'a' is the first entry; letters
        // are used rather than digits so entries past the ninth stay reachable.
        if (key.codepoint >= 'a' and key.codepoint < 'a' + demos.len) {
            return self.open(ctx, demos[key.codepoint - 'a']);
        }
    }

    /// Switches to a demo, focusing whatever widget makes it interactive.
    fn open(self: *Self, ctx: *vxfw.EventContext, demo: Demo) anyerror!void {
        self.active = demo;
        self.cursor = @intFromEnum(demo);
        // The spinner animates off a Tick command, so it only runs while shown.
        if (demo == .spinner) {
            if (self.views.spinner.start()) |cmd| try ctx.addCmd(cmd);
        }
        if (self.views.focusTarget(demo)) |target| {
            try ctx.requestFocus(target);
        } else {
            try ctx.requestFocus(self.widget());
        }
        return ctx.consumeAndRedraw();
    }

    /// Returns to the menu.
    fn showMenu(self: *Self, ctx: *vxfw.EventContext) anyerror!void {
        self.views.spinner.stop();
        self.active = null;
        try ctx.requestFocus(self.widget());
        return ctx.consumeAndRedraw();
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();
        if (max.width == 0 or max.height == 0) return .empty(self.widget());
        return if (self.active) |demo| self.drawDemo(ctx, max, demo) else self.drawMenu(ctx, max);
    }

    // -------------------------------------------------------------------------
    // Views

    /// Draws the numbered menu of demos.
    fn drawMenu(self: *Self, ctx: vxfw.DrawContext, max: vxfw.Size) Allocator.Error!vxfw.Surface {
        var kids: std.ArrayList(vxfw.SubSurface) = .empty;

        try self.row(ctx, &kids, 0, max.width, "zigvaxis gallery", .{ .bold = true, .fg = .{ .index = 4 } });

        for (demos, 0..) |demo, i| {
            const row_idx = menu_top + @as(u16, @intCast(i));
            if (row_idx >= max.height -| 2) break;
            const selected = i == self.cursor;
            const text = try std.fmt.allocPrint(ctx.arena, "{s}  {c}  {s: <22} {s}", .{
                if (selected) ">" else " ",
                selector(i),
                demo.title(),
                demo.blurb(),
            });
            const style: vaxis.Style = if (selected)
                .{ .bold = true, .fg = .{ .index = 6 } }
            else
                .{};
            try self.row(ctx, &kids, row_idx, max.width, text, style);
        }

        const footer = try std.fmt.allocPrint(ctx.arena, "a-{c} or arrows to choose  .  enter to open  .  q to quit", .{selector(demos.len - 1)});
        try self.row(ctx, &kids, max.height -| 1, max.width, footer, .{ .dim = true });

        return .{
            .size = max,
            .widget = self.widget(),
            .buffer = &.{},
            .children = try kids.toOwnedSlice(ctx.arena),
        };
    }

    /// Draws the active demo with a title bar and a footer.
    fn drawDemo(self: *Self, ctx: vxfw.DrawContext, max: vxfw.Size, demo: Demo) Allocator.Error!vxfw.Surface {
        var kids: std.ArrayList(vxfw.SubSurface) = .empty;

        const heading = try std.fmt.allocPrint(ctx.arena, "{c}. {s} - {s}", .{
            selector(@intFromEnum(demo)),
            demo.title(),
            demo.blurb(),
        });
        try self.row(ctx, &kids, 0, max.width, heading, .{ .bold = true, .fg = .{ .index = 4 } });

        // The demo pane is everything between the heading and the footer.
        const pane: vxfw.Size = .{
            .width = max.width,
            .height = max.height -| 3,
        };
        if (pane.height > 0) {
            try kids.append(ctx.arena, .{
                .origin = .{ .row = 2, .col = 0 },
                .surface = try self.views.draw(self.widget(), demo, ctx.withConstraints(.{}, .fromSize(pane)), pane),
            });
        }

        try self.row(ctx, &kids, max.height -| 1, max.width, "esc back  .  ctrl+c quit", .{ .dim = true });

        return .{
            .size = max,
            .widget = self.widget(),
            .buffer = &.{},
            .children = try kids.toOwnedSlice(ctx.arena),
        };
    }

    /// Appends a single-line text child at `row`.
    fn row(self: *Self, ctx: vxfw.DrawContext, kids: *std.ArrayList(vxfw.SubSurface), row_idx: u16, width: u16, text: []const u8, style: vaxis.Style) Allocator.Error!void {
        _ = self;
        const item = try ctx.arena.create(vxfw.Text);
        item.* = .{ .text = text, .style = style, .softwrap = false, .overflow = .ellipsis };
        try kids.append(ctx.arena, .{
            .origin = .{ .row = @intCast(row_idx), .col = 0 },
            .surface = try item.widget().draw(ctx.withConstraints(.{}, .{ .width = width, .height = 1 })),
        });
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "DemoApp: the menu is the initial view" {
    var app: DemoApp = .init(std.testing.io, std.testing.allocator);
    defer app.deinit();
    try std.testing.expect(app.active == null);
    try std.testing.expectEqual(@as(usize, 0), app.cursor);
}

test "DemoApp: every demo has a selector letter that is not the quit key" {
    for (demos, 0..) |_, i| {
        const key = selector(i);
        try std.testing.expect(key >= 'a');
        try std.testing.expect(key != quit_key);
    }
}
