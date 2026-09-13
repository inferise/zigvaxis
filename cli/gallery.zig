const std = @import("std");
const vaxis = @import("zigvaxis");

const vxfw = vaxis.vxfw;
const Allocator = std.mem.Allocator;

/// How many rows the list and scroll demos populate.
const list_len: usize = 24;

/// Longest event description the events demo keeps between frames.
const event_buf_len: usize = 96;

/// Every demo view the gallery can show, in menu order.
///
/// The tag order is the menu order and the number key that selects it, so
/// inserting a demo renumbers the menu automatically.
pub const Demo = enum {
    text,
    styles,
    colors,
    rich_text,
    border,
    padding,
    flex,
    list_view,
    scroll_view,
    text_field,
    button,
    spinner,
    events,

    /// The menu label for this demo.
    pub fn title(self: Demo) []const u8 {
        return switch (self) {
            .text => "Text",
            .styles => "Styles",
            .colors => "Colors",
            .rich_text => "RichText",
            .border => "Border",
            .padding => "Padding & Center",
            .flex => "FlexRow & FlexColumn",
            .list_view => "ListView",
            .scroll_view => "ScrollView",
            .text_field => "TextField",
            .button => "Button",
            .spinner => "Spinner",
            .events => "Events",
        };
    }

    /// One-line description shown beside the menu label.
    pub fn blurb(self: Demo) []const u8 {
        return switch (self) {
            .text => "wrapping, alignment and overflow",
            .styles => "bold, italic, underline, strikethrough",
            .colors => "default, 256-index and 24-bit rgb",
            .rich_text => "per-span styling on one line",
            .border => "box drawing with labels",
            .padding => "insets and centering",
            .flex => "proportional layout in both axes",
            .list_view => "a scrollable list with a cursor",
            .scroll_view => "free scrolling without a cursor",
            .text_field => "editable single-line input",
            .button => "focus and click handling",
            .spinner => "timer-driven animation",
            .events => "live key and mouse reporting",
        };
    }
};

/// Owns every stateful demo widget and renders one demo view at a time.
///
/// Widgets that carry state between frames (the button, the text field, the
/// spinner, the list and scroll views) live here so their addresses stay put.
/// Everything else is rebuilt each frame from the draw context's arena.
pub const Gallery = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    button: vxfw.Button,
    text_field: vxfw.TextField,
    spinner: vxfw.Spinner,
    list: vxfw.ListView,
    scroll: vxfw.ScrollView,

    /// Backing text for the list and scroll demos. Stable storage, because
    /// the builder callbacks hand out widgets that point into this array.
    rows: [list_len]vxfw.Text,
    row_labels: [list_len][24]u8,

    /// Number of times the button demo has been clicked.
    clicks: u32,

    /// Description of the most recent event, for the events demo.
    event_buf: [event_buf_len]u8,
    event_len: usize,

    /// Constructs a gallery bound to the process capabilities.
    ///
    /// Parameters:
    /// - `io`: IO interface, required by the spinner's timer.
    /// - `allocator`: allocator backing the text field's edit buffer.
    ///
    /// Return: a gallery whose stateful widgets are ready to draw. The row
    /// labels are filled in by `prime`, which needs the final address.
    pub fn init(io: std.Io, allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .button = .{ .label = "Click me", .onClick = onClick },
            .text_field = .init(allocator),
            .spinner = .{ .io = io },
            .list = .{ .children = .{ .builder = .{ .userdata = undefined, .buildFn = buildRow } } },
            .scroll = .{ .children = .{ .builder = .{ .userdata = undefined, .buildFn = buildRow } } },
            .rows = undefined,
            .row_labels = undefined,
            .clicks = 0,
            .event_buf = undefined,
            .event_len = 0,
        };
    }

    /// Wires up the self-referential fields once the gallery has its final address.
    ///
    /// Parameters:
    /// - `self`: the gallery, at the address it will keep for its whole life.
    ///
    /// Return: nothing. Must be called exactly once, before the first draw.
    pub fn prime(self: *Self) void {
        for (&self.row_labels, 0..) |*label, i| {
            const text = std.fmt.bufPrint(label, "row {d}", .{i + 1}) catch "row";
            self.rows[i] = .{ .text = text };
        }
        self.button.userdata = self;
        self.list.children.builder.userdata = self;
        self.scroll.children.builder.userdata = self;
    }

    /// Releases everything the gallery owns.
    ///
    /// Parameters:
    /// - `self`: the gallery to tear down.
    ///
    /// Return: nothing.
    pub fn deinit(self: *Self) void {
        self.text_field.deinit();
    }

    /// Records a one-line description of an event for the events demo.
    ///
    /// Parameters:
    /// - `self`: the gallery holding the description buffer.
    /// - `event`: the event to describe.
    ///
    /// Return: nothing. A description too long for the buffer is dropped.
    pub fn note(self: *Self, event: vxfw.Event) void {
        const written = switch (event) {
            .key_press => |key| std.fmt.bufPrint(
                &self.event_buf,
                "key_press  codepoint=0x{x}  shift={}  ctrl={}  alt={}",
                .{ key.codepoint, key.mods.shift, key.mods.ctrl, key.mods.alt },
            ),
            .mouse => |mouse| std.fmt.bufPrint(
                &self.event_buf,
                "mouse  col={d}  row={d}  button={t}  type={t}",
                .{ mouse.col, mouse.row, mouse.button, mouse.type },
            ),
            .winsize => |ws| std.fmt.bufPrint(
                &self.event_buf,
                "winsize  cols={d}  rows={d}",
                .{ ws.cols, ws.rows },
            ),
            .focus_in => std.fmt.bufPrint(&self.event_buf, "focus_in", .{}),
            .focus_out => std.fmt.bufPrint(&self.event_buf, "focus_out", .{}),
            .mouse_enter => std.fmt.bufPrint(&self.event_buf, "mouse_enter", .{}),
            .mouse_leave => std.fmt.bufPrint(&self.event_buf, "mouse_leave", .{}),
            else => std.fmt.bufPrint(&self.event_buf, "{t}", .{event}),
        } catch return;
        self.event_len = written.len;
    }

    /// The event text recorded by `note`, or a prompt if nothing has happened.
    pub fn lastEvent(self: *const Self) []const u8 {
        if (self.event_len == 0) return "press a key or move the mouse";
        return self.event_buf[0..self.event_len];
    }

    /// The widget a demo needs focused to be interactive, if any.
    ///
    /// Parameters:
    /// - `self`: the gallery owning the widget.
    /// - `demo`: the demo about to be shown.
    ///
    /// Return: the widget to focus, or null when the demo is display-only.
    pub fn focusTarget(self: *Self, demo: Demo) ?vxfw.Widget {
        return switch (demo) {
            .text_field => self.text_field.widget(),
            .button => self.button.widget(),
            .list_view => self.list.widget(),
            .scroll_view => self.scroll.widget(),
            else => null,
        };
    }

    /// Draws one demo into a surface of the given size.
    ///
    /// Parameters:
    /// - `self`: the gallery supplying widget state.
    /// - `parent`: widget the surface is attributed to, for hit testing.
    /// - `demo`: which demo to render.
    /// - `ctx`: the frame's draw context.
    /// - `size`: exact size the returned surface must have.
    ///
    /// Return: a surface filled with the demo; propagates arena exhaustion.
    pub fn draw(self: *Self, parent: vxfw.Widget, demo: Demo, ctx: vxfw.DrawContext, size: vxfw.Size) Allocator.Error!vxfw.Surface {
        var surface = try vxfw.Surface.initWithChildren(ctx.arena, parent, size, &.{});
        var kids: std.ArrayList(vxfw.SubSurface) = .empty;

        switch (demo) {
            .text => {
                try line(ctx, &kids, 0, size.width, "softwrap on, width_basis = parent:", .{ .bold = true });
                const para = "Vaxis measures text by grapheme cluster, so wrapping stays correct for emoji and combining marks. This paragraph wraps to the demo pane.";
                const wrapped = try ctx.arena.create(vxfw.Text);
                wrapped.* = .{ .text = para, .softwrap = true, .width_basis = .parent };
                try kids.append(ctx.arena, .{
                    .origin = .{ .row = 1, .col = 0 },
                    .surface = try wrapped.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 6 })),
                });
                try line(ctx, &kids, 8, size.width, "text_align = center:", .{ .bold = true });
                const centered = try ctx.arena.create(vxfw.Text);
                centered.* = .{ .text = "centered in the pane", .text_align = .center, .width_basis = .parent };
                try kids.append(ctx.arena, .{
                    .origin = .{ .row = 9, .col = 0 },
                    .surface = try centered.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 })),
                });
                try line(ctx, &kids, 11, size.width, "overflow = ellipsis, softwrap off:", .{ .bold = true });
                const clipped = try ctx.arena.create(vxfw.Text);
                clipped.* = .{ .text = "this single line is deliberately far too long to fit inside the demo pane and is truncated", .softwrap = false, .overflow = .ellipsis };
                try kids.append(ctx.arena, .{
                    .origin = .{ .row = 12, .col = 0 },
                    .surface = try clipped.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 })),
                });
            },
            .styles => {
                const entries = [_]struct { []const u8, vaxis.Style }{
                    .{ "bold", .{ .bold = true } },
                    .{ "dim", .{ .dim = true } },
                    .{ "italic", .{ .italic = true } },
                    .{ "reverse", .{ .reverse = true } },
                    .{ "strikethrough", .{ .strikethrough = true } },
                    .{ "blink", .{ .blink = true } },
                    .{ "underline single", .{ .ul_style = .single } },
                    .{ "underline double", .{ .ul_style = .double } },
                    .{ "underline curly", .{ .ul_style = .curly } },
                    .{ "underline dotted", .{ .ul_style = .dotted } },
                    .{ "underline dashed", .{ .ul_style = .dashed } },
                    .{ "colored underline", .{ .ul_style = .curly, .ul = .{ .index = 1 } } },
                };
                for (entries, 0..) |entry, i| {
                    try line(ctx, &kids, @intCast(i), size.width, entry[0], entry[1]);
                }
                try line(ctx, &kids, @intCast(entries.len + 1), size.width, "not every terminal implements all of these", .{ .dim = true });
            },
            .colors => {
                try line(ctx, &kids, 0, size.width, "16 indexed colors", .{ .bold = true });
                for (0..16) |i| {
                    const col: u16 = @intCast(i * 3);
                    if (col + 2 >= size.width) break;
                    paint(surface, col, 1, 3, .{ .bg = .{ .index = @intCast(i) } });
                }
                try line(ctx, &kids, 3, size.width, "256-color cube (sample)", .{ .bold = true });
                for (0..@min(72, size.width)) |i| {
                    paint(surface, @intCast(i), 4, 1, .{ .bg = .{ .index = @intCast(16 + i * 3) } });
                }
                try line(ctx, &kids, 6, size.width, "24-bit rgb gradient", .{ .bold = true });
                const span: u16 = @min(size.width, 72);
                for (0..span) |i| {
                    const t: u32 = @intCast((i * 255) / @max(1, span - 1));
                    paint(surface, @intCast(i), 7, 1, .{ .bg = .{ .rgb = .{ @intCast(t), @intCast(128), @intCast(255 - t) } } });
                }
                try line(ctx, &kids, 9, size.width, "NO_COLOR in the environment disables all of this", .{ .dim = true });
            },
            .rich_text => {
                const spans = try ctx.arena.alloc(vxfw.RichText.TextSpan, 5);
                spans[0] = .{ .text = "One ", .style = .{} };
                spans[1] = .{ .text = "RichText", .style = .{ .bold = true, .fg = .{ .index = 4 } } };
                spans[2] = .{ .text = " widget, ", .style = .{} };
                spans[3] = .{ .text = "many styles", .style = .{ .italic = true, .fg = .{ .index = 2 } } };
                spans[4] = .{ .text = " on one line.", .style = .{} };
                const rich = try ctx.arena.create(vxfw.RichText);
                rich.* = .{ .text = spans, .width_basis = .parent };
                try kids.append(ctx.arena, .{
                    .origin = .{ .row = 0, .col = 0 },
                    .surface = try rich.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 2 })),
                });
                try line(ctx, &kids, 2, size.width, "Text takes one style; RichText takes a style per span.", .{ .dim = true });
            },
            .border => {
                const inner = try ctx.arena.create(vxfw.Text);
                inner.* = .{ .text = "  a bordered child  \n  with a label     ", .width_basis = .parent };
                const labels = try ctx.arena.alloc(vxfw.Border.BorderLabel, 1);
                labels[0] = .{ .text = " Border ", .alignment = .top_center };
                const bordered = try ctx.arena.create(vxfw.Border);
                bordered.* = .{ .child = inner.widget(), .style = .{ .fg = .{ .index = 5 } }, .labels = labels };
                try kids.append(ctx.arena, .{
                    .origin = .{ .row = 0, .col = 0 },
                    .surface = try bordered.widget().draw(ctx.withConstraints(.{}, .{ .width = @min(size.width, 30), .height = 5 })),
                });
                try line(ctx, &kids, 6, size.width, "Border wraps any widget and can carry labels.", .{ .dim = true });
            },
            .padding => {
                const inner = try ctx.arena.create(vxfw.Text);
                inner.* = .{ .text = "padded 2 all round" };
                const padded = try ctx.arena.create(vxfw.Padding);
                padded.* = .{ .child = inner.widget(), .padding = vxfw.Padding.all(2) };
                const outline = try ctx.arena.create(vxfw.Border);
                outline.* = .{ .child = padded.widget() };
                try kids.append(ctx.arena, .{
                    .origin = .{ .row = 0, .col = 0 },
                    .surface = try outline.widget().draw(ctx.withConstraints(.{}, .{ .width = @min(size.width, 28), .height = 7 })),
                });
                const middle = try ctx.arena.create(vxfw.Text);
                middle.* = .{ .text = "centered" };
                const center = try ctx.arena.create(vxfw.Center);
                center.* = .{ .child = middle.widget() };
                const center_box = try ctx.arena.create(vxfw.Border);
                center_box.* = .{ .child = center.widget(), .style = .{ .fg = .{ .index = 3 } } };
                if (size.height > 14) {
                    try kids.append(ctx.arena, .{
                        .origin = .{ .row = 8, .col = 0 },
                        .surface = try center_box.widget().draw(ctx.withConstraints(.{}, .{ .width = @min(size.width, 28), .height = 5 })),
                    });
                }
            },
            .flex => {
                const items = try ctx.arena.alloc(vxfw.FlexItem, 3);
                const weights = [_]u8{ 1, 2, 1 };
                const names = [_][]const u8{ " flex 1 ", " flex 2 ", " flex 1 " };
                const tints = [_]u8{ 1, 2, 4 };
                for (items, 0..) |*item, i| {
                    const cell = try ctx.arena.create(vxfw.Text);
                    cell.* = .{ .text = names[i], .style = .{ .bg = .{ .index = tints[i] } }, .width_basis = .parent };
                    item.* = .{ .widget = cell.widget(), .flex = weights[i] };
                }
                const row = try ctx.arena.create(vxfw.FlexRow);
                row.* = .{ .children = items };
                try kids.append(ctx.arena, .{
                    .origin = .{ .row = 0, .col = 0 },
                    .surface = try row.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = 1 })),
                });
                try line(ctx, &kids, 2, size.width, "FlexRow above shares the width 1:2:1.", .{ .dim = true });
                try line(ctx, &kids, 3, size.width, "FlexColumn is the same widget for height.", .{ .dim = true });
            },
            .list_view => {
                try kids.append(ctx.arena, .{
                    .origin = .{ .row = 0, .col = 0 },
                    .surface = try self.list.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height -| 2 })),
                });
                try line(ctx, &kids, size.height -| 1, size.width, "up/down moves the cursor, wheel scrolls", .{ .dim = true });
            },
            .scroll_view => {
                try kids.append(ctx.arena, .{
                    .origin = .{ .row = 0, .col = 0 },
                    .surface = try self.scroll.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height -| 2 })),
                });
                try line(ctx, &kids, size.height -| 1, size.width, "scrolls freely, no cursor", .{ .dim = true });
            },
            .text_field => {
                const framed = try ctx.arena.create(vxfw.Border);
                framed.* = .{ .child = self.text_field.widget() };
                try kids.append(ctx.arena, .{
                    .origin = .{ .row = 0, .col = 0 },
                    .surface = try framed.widget().draw(ctx.withConstraints(.{}, .{ .width = @min(size.width, 40), .height = 3 })),
                });
                try line(ctx, &kids, 4, size.width, "type to edit; the field owns its own cursor", .{ .dim = true });
            },
            .button => {
                try kids.append(ctx.arena, .{
                    .origin = .{ .row = 0, .col = 0 },
                    .surface = try self.button.widget().draw(ctx.withConstraints(.{}, .{ .width = 16, .height = 3 })),
                });
                const count = try std.fmt.allocPrint(ctx.arena, "clicks: {d}", .{self.clicks});
                try line(ctx, &kids, 4, size.width, count, .{ .bold = true });
                try line(ctx, &kids, 6, size.width, "enter activates it while focused; the mouse works too", .{ .dim = true });
            },
            .spinner => {
                try kids.append(ctx.arena, .{
                    .origin = .{ .row = 0, .col = 0 },
                    .surface = try self.spinner.widget().draw(ctx.withConstraints(.{}, .{ .width = 2, .height = 1 })),
                });
                try line(ctx, &kids, 2, size.width, "driven by a Tick command, not a busy loop", .{ .dim = true });
            },
            .events => {
                try line(ctx, &kids, 0, size.width, "most recent event", .{ .bold = true });
                try line(ctx, &kids, 1, size.width, self.lastEvent(), .{ .fg = .{ .index = 2 } });
                try line(ctx, &kids, 3, size.width, "vaxis reports mouse motion, focus and paste too", .{ .dim = true });
            },
        }

        surface.children = try kids.toOwnedSlice(ctx.arena);
        return surface;
    }

    // -------------------------------------------------------------------------
    // Drawing helpers

    /// Appends a single-line text child at `row`, clipped to `width`.
    fn line(ctx: vxfw.DrawContext, kids: *std.ArrayList(vxfw.SubSurface), row: u16, width: u16, text: []const u8, style: vaxis.Style) Allocator.Error!void {
        const item = try ctx.arena.create(vxfw.Text);
        item.* = .{ .text = text, .style = style, .softwrap = false, .overflow = .ellipsis };
        try kids.append(ctx.arena, .{
            .origin = .{ .row = @intCast(row), .col = 0 },
            .surface = try item.widget().draw(ctx.withConstraints(.{}, .{ .width = width, .height = 1 })),
        });
    }

    /// Fills `len` cells of `surface` starting at (col, row) with `style`.
    fn paint(surface: vxfw.Surface, col: u16, row: u16, len: u16, style: vaxis.Style) void {
        for (0..len) |i| {
            surface.writeCell(col + @as(u16, @intCast(i)), row, .{ .style = style });
        }
    }

    // -------------------------------------------------------------------------
    // Widget callbacks

    /// Builds one row for the list and scroll demos.
    fn buildRow(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const Self = @ptrCast(@alignCast(ptr));
        if (idx >= self.rows.len) return null;
        return self.rows[idx].widget();
    }

    /// Counts a button press for the button demo.
    fn onClick(maybe_ptr: ?*anyopaque, ctx: *vxfw.EventContext) anyerror!void {
        const ptr = maybe_ptr orelse return;
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.clicks +|= 1;
        return ctx.consumeAndRedraw();
    }
};

// -----------------------------------------------------------------------------
// Unit Tests

test "Demo: every tag has a title and a blurb" {
    for (std.enums.values(Demo)) |demo| {
        try std.testing.expect(demo.title().len > 0);
        try std.testing.expect(demo.blurb().len > 0);
    }
}
