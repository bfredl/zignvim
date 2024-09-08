const std = @import("std");
const c = @import("gtk_c.zig");
const g = @import("gtk_lib.zig");
const io = @import("io_native.zig");
const RPCState = @import("RPCState.zig");
const mem = std.mem;
const os = std.os;

const RGB = RPCState.RGB;

const ArrayList = std.ArrayList;
const mpack = @import("./mpack.zig");

const dbg = std.debug.print;

const Self = @This();

const io_mode = std.io.Mode.evented;

gpa: std.heap.GeneralPurposeAllocator(.{}),

child: std.process.Child = undefined,
enc_buf: ArrayList(u8) = undefined,
key_buf: ArrayList(u8) = undefined,

buf: [1024]u8 = undefined,
decoder: mpack.SkipDecoder = undefined,
rpc: RPCState = undefined,

window: *c.GtkWindow = undefined,
da: *c.GtkWidget = undefined,
cs: ?*c.cairo_surface_t = null,
rows: u16 = 0,
cols: u16 = 0,

context: *c.PangoContext = undefined,
//font_name: []u8,
cell_width: u32 = 0,
cell_height: u32 = 0,

fn get_self(data: c.gpointer) *Self {
    return @ptrCast(@alignCast(data));
}

fn key_pressed(_: *c.GtkEventControllerKey, keyval: c.guint, keycode: c.guint, mod: c.GdkModifierType, data: c.gpointer) callconv(.C) bool {
    _ = keycode;
    const self = get_self(data);
    self.onKeyPress(keyval, mod) catch @panic("We live inside of a dream!");
    return false;
}

fn onKeyPress(self: *Self, keyval: c.guint, mod: c.guint) !void {
    const special: ?[:0]const u8 = switch (keyval) {
        c.GDK_KEY_Left => "Left",
        c.GDK_KEY_Right => "Right",
        else => null,
    };
    var x: [4]u8 = undefined;

    const codepoint = c.gdk_keyval_to_unicode(keyval);
    dbg("Hellooooo! {} {} {}\n", .{ keyval, mod, codepoint });
    if (codepoint == 0 or codepoint > std.math.maxInt(u21)) {
        return;
    }
    const len = std.unicode.utf8Encode(@intCast(codepoint), x[0..x.len]) catch @panic("aaaah");
    var did = false;
    // TODO: be insane enough and just reuse enc_buf :]
    defer self.key_buf.items.len = 0;
    if ((mod & c.GDK_CONTROL_MASK) != 0 or special != null) {
        try self.key_buf.appendSlice("<");
        did = true;
    }
    if ((mod & c.GDK_CONTROL_MASK) != 0) {
        try self.key_buf.appendSlice("c-");
    }
    try self.key_buf.appendSlice(x[0..len]);
    if (did) {
        try self.key_buf.appendSlice(">");
    }

    try self.doCommit(self.key_buf.items);
}

fn mouse_pressed(gesture: *c.GtkGesture, n_press: c.guint, x: c.gdouble, y: c.gdouble, data: c.gpointer) callconv(.C) bool {
    const self = get_self(data);
    self.onMousePress(gesture, n_press, x, y) catch @panic("We live inside of a dream!");
    return false;
}

fn onMousePress(self: *Self, gesture: *c.GtkGesture, n_press: c.guint, x: c.gdouble, y: c.gdouble) !void {
    _ = gesture;
    _ = n_press;

    const col = @as(u32, @intFromFloat(x)) / self.cell_width;
    const row = @as(u32, @intFromFloat(y)) / self.cell_height;

    dbg("KLIIICK {} {}\n", .{ col, row });

    const grid = &self.rpc.ui.grid[0];
    if (col >= grid.cols or row >= grid.cols) return;
    const basepos = row * grid.cols;
    const gridrow = grid.cell.items[basepos..][0..grid.cols];

    const myattr = gridrow[col].attr_id;

    var first = col;
    while (first > 0) : (first -= 1) {
        if (gridrow[first - 1].attr_id != myattr) break;
    }
    var end = col + 1;
    while (end < grid.cols) : (end += 1) {
        if (gridrow[end].attr_id != myattr) break;
    }

    dbg("detektera: {} {}\n", .{ first, end });

    const cr = c.cairo_create(self.cs) orelse @panic("bullllll");
    defer c.cairo_destroy(cr);

    const attr = self.rpc.ui.attr.items[if (myattr < self.rpc.ui.attr.items.len) myattr else 0];
    try self.draw_run(cr, row, first, end - first, gridrow[first..end], attr, true);

    // NB: redisplay if we actually change something
}

fn doCommit(self: *Self, str: []const u8) !void {
    dbg("aha: {s}\n", .{str});
    const encoder = mpack.encoder(self.enc_buf.writer());
    try io.unsafe_input(encoder, str);
    try self.child.stdin.?.writeAll(self.enc_buf.items);
    try self.enc_buf.resize(0);
}

fn commit(_: *c.GtkIMContext, str: [*:0]const u8, data: c.gpointer) callconv(.C) void {
    var self = get_self(data);

    self.doCommit(str[0..mem.len(str)]) catch @panic("It was a dream!");
}

fn focus_enter(_: *c.GtkEventControllerFocus, data: c.gpointer) callconv(.C) void {
    // c.g_print("änter\n");
    const im_context: *c.GtkIMContext = @ptrCast(@alignCast(data));
    c.gtk_im_context_focus_in(im_context);
}

fn focus_leave(_: *c.GtkEventControllerFocus, data: c.gpointer) callconv(.C) void {
    // c.g_print("you must leave now\n");
    const im_context: *c.GtkIMContext = @ptrCast(@alignCast(data));
    c.gtk_im_context_focus_out(im_context);
}

fn on_stdout(_: ?*c.GIOChannel, cond: c.GIOCondition, data: c.gpointer) callconv(.C) c.gboolean {
    _ = cond;
    // dbg("DATTA\n", .{});

    var self = get_self(data);

    const oldlen = self.decoder.data.len;
    if (oldlen > 0 and self.decoder.data.ptr != &self.buf) {
        // TODO: avoid move if remaining space is plenty (like > 900)
        mem.copyForwards(u8, &self.buf, self.decoder.data);
    }
    var stdout = &self.child.stdout.?;
    const lenny = stdout.read(self.buf[oldlen..]) catch @panic("call for help");
    self.decoder.data = self.buf[0 .. oldlen + lenny];

    while (self.decoder.data.len > 0) {
        self.rpc.process(&self.decoder) catch |err| {
            switch (err) {
                error.EOFError => {
                    std.debug.print("!!interrupted. {} bytes left in state {}\n", .{ self.decoder.data.len, self.rpc.state });
                    break;
                },
                error.FlushCondition => {
                    std.debug.print("!!flushed. but {} bytes left in state {}\n", .{ self.decoder.data.len, self.rpc.state });
                    self.flush() catch @panic("NotLikeThis");
                    continue; // there might be more data after the flush
                },
                else => @panic("go crazy yea"),
            }
        };
    }

    return 1;
}

fn redraw_area(_: ?*c.GtkDrawingArea, cr_in: ?*c.cairo_t, width: c_int, height: c_int, data: c.gpointer) callconv(.C) void {
    const self = get_self(data);
    const cs = self.cs orelse return;
    const cr = cr_in orelse return;
    _ = width;
    _ = height;

    c.cairo_surface_flush(cs);
    c.cairo_set_source_surface(cr, cs, 0, 0);
    c.cairo_paint(cr);
}

fn ccolor(cval: u8) f64 {
    const max: f64 = 255.0;
    return @as(f64, @floatFromInt(cval)) / max;
}

fn flush(self: *Self) !void {
    dbg("le flush\n", .{});
    self.rpc.dump_grid();

    const grid = &self.rpc.ui.grid[0];

    // TODO: the right condition for "font[size] changed"
    if (self.cell_height == 0) {
        try self.set_font("JuliaMono 15");
    }

    if (self.rows != grid.rows or self.cols != grid.cols) {
        dbg("le resize\n", .{});
        self.rows = grid.rows;
        self.cols = grid.cols;
        const width: c_int = @intCast(self.cols * self.cell_width);
        const height: c_int = @intCast(self.rows * self.cell_height);

        dbg("LE METRICS {} {}\n", .{ width, height });

        c.gtk_drawing_area_set_content_width(g.GTK_DRAWING_AREA(self.da), width);
        c.gtk_drawing_area_set_content_height(g.GTK_DRAWING_AREA(self.da), height);

        if (self.cs) |cs| {
            c.cairo_surface_destroy(cs);
        }
        const surface = c.gtk_native_get_surface(g.g_cast(c.GtkNative, c.gtk_native_get_type(), self.window));
        self.cs = c.gdk_surface_create_similar_surface(surface, c.CAIRO_CONTENT_COLOR, width, height);
    }

    const cr = c.cairo_create(self.cs) orelse @panic("det är ÖKEN");
    defer c.cairo_destroy(cr);
    // for debugging, fill with invalid color:
    c.cairo_set_source_rgb(cr, 0.8, 0.2, 0.2);
    c.cairo_paint(cr);

    for (0..grid.rows) |row| {
        const basepos = row * grid.cols;
        var cur_attr: u32 = grid.cell.items[basepos].attr_id;
        var begin: usize = 0;
        // dbg("SEGMENTS {}: ", .{row});
        for (1..grid.cols + 1) |col| {
            const last_attr = cur_attr;
            const new = if (col < grid.cols) new: {
                cur_attr = grid.cell.items[basepos + col].attr_id;
                break :new cur_attr != last_attr;
            } else true;

            if (new) {
                // dbg("{}-{}, ", .{ begin, col });

                const attr = self.rpc.ui.attr.items[if (last_attr < self.rpc.ui.attr.items.len) last_attr else 0];

                try self.draw_run(cr, row, begin, col - begin, grid.cell.items[basepos + begin .. basepos + col], attr, false);

                begin = col;
            }
        }
        // dbg("\n", .{});
    }

    c.gtk_widget_queue_draw(g.GTK_WIDGET(self.da));
}

fn draw_run(self: *Self, cr: *c.cairo_t, row: usize, col: usize, width: usize, cells: []RPCState.Cell, attr: RPCState.Attr, debug: bool) !void {
    const pos: c.GdkRectangle = .{
        .x = @intCast(self.cell_width * col),
        .y = @intCast(row * self.cell_height),
        .width = @intCast(self.cell_width * width),
        .height = @intCast(self.cell_height),
    };
    c.gdk_cairo_rectangle(cr, &pos);
    const bg: RGB = @bitCast(attr.bg orelse self.rpc.ui.default_colors.bg);
    // dbg("{}<-{}, ", .{ pos, bg });
    c.cairo_set_source_rgb(cr, ccolor(bg.r), ccolor(bg.g), ccolor(bg.b));
    c.cairo_fill(cr);

    // TODO: shared buffer!
    var text = std.ArrayList(u8).init(self.gpa.allocator());
    // TODO: be smart and cut after last non-space
    var anytext = false;
    for (cells) |cell| {
        if (!mem.eql(u8, cell.char[0..2], &.{ 32, 0 })) anytext = true;
        try text.appendSlice(cell.text());
    }
    if (!anytext) return; // for now this skips empty shit when inspecting
    if (debug) dbg("for text \"{s}\":\n", .{text.items});

    const attr_list = c.pango_attr_list_new();
    var item_list = c.pango_itemize(self.context, text.items.ptr, 0, @intCast(text.items.len), attr_list, null);

    while (item_list) |item| {
        const i: *c.PangoItem = @ptrCast(@alignCast(item.*.data));
        item_list = c.g_list_delete_link(item, item);
        if (debug) dbg("ITYM {}\n", .{i.*});
    }
}

fn pango_pixels_ceil(u: c_int) c_int {
    return @divTrunc((u + (c.PANGO_SCALE - 1)), c.PANGO_SCALE);
}

fn set_font(self: *Self, font: [:0]const u8) !void {
    // TODO: LEAK ALL THE THINGS!

    // TODO: shorten the three-step dance?
    const surface = c.gtk_native_get_surface(g.g_cast(c.GtkNative, c.gtk_native_get_type(), self.window));
    // TODO: this seems dumb. check what a gtk4 gnome-terminal would do!
    const dummy_surface = c.gdk_surface_create_similar_surface(surface, c.CAIRO_CONTENT_COLOR, 500, 500);
    // dbg("s {}\n", .{@ptrToInt(surface)});
    //const cc = c.gdk_surface_create_cairo_context(surface);
    // dbg("cc {}\n", .{@ptrToInt(cc)});
    const cairo = c.cairo_create(dummy_surface);
    // dbg("cairso {}\n", .{@ptrToInt(cairo)});
    const fontdesc = c.pango_font_description_from_string(font);

    const pctx = c.pango_cairo_create_context(cairo) orelse @panic("pango pongo");
    c.pango_context_set_font_description(pctx, fontdesc);

    const metrics = c.pango_context_get_metrics(pctx, fontdesc, c.pango_context_get_language(pctx));
    const width = c.pango_font_metrics_get_approximate_char_width(metrics);
    const height = c.pango_font_metrics_get_height(metrics);
    self.cell_width = @intCast(pango_pixels_ceil(width));
    self.cell_height = @intCast(pango_pixels_ceil(height));

    dbg("le foont terrible {} {}\n", .{ self.cell_width, self.cell_height });

    self.context = pctx;
}

fn init(self: *Self) !void {
    const allocator = self.gpa.allocator();

    var the_fd: ?i32 = null;
    if (false) {
        the_fd = try std.posix.dup(0);
    }

    self.child = try io.spawn(allocator, the_fd);
    self.enc_buf = ArrayList(u8).init(allocator);
    self.key_buf = ArrayList(u8).init(allocator);

    self.decoder = mpack.SkipDecoder{ .data = self.buf[0..0] };
    self.rpc = try RPCState.init(allocator);

    var encoder = mpack.encoder(self.enc_buf.writer());
    try io.attach_test(&encoder, if (the_fd) |_| @as(i32, 3) else null);
    try self.child.stdin.?.writeAll(self.enc_buf.items);
    try self.enc_buf.resize(0);

    const gio = c.g_io_channel_unix_new(self.child.stdout.?.handle);
    _ = c.g_io_add_watch(gio, c.G_IO_IN, on_stdout, self);
}

fn activate(app: *c.GtkApplication, data: c.gpointer) callconv(.C) void {
    const self = get_self(data);
    self.init() catch @panic("heeee");

    const window: *c.GtkWidget = c.gtk_application_window_new(app);
    self.window = g.GTK_WINDOW(window);

    c.gtk_window_set_title(g.GTK_WINDOW(window), "Window");
    c.gtk_window_set_default_size(g.GTK_WINDOW(window), 200, 200);
    const box: *c.GtkWidget = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    c.gtk_window_set_child(g.GTK_WINDOW(window), box);
    self.da = c.gtk_drawing_area_new();
    c.gtk_drawing_area_set_content_width(g.GTK_DRAWING_AREA(self.da), 500);
    c.gtk_drawing_area_set_content_height(g.GTK_DRAWING_AREA(self.da), 500);
    c.gtk_drawing_area_set_draw_func(g.GTK_DRAWING_AREA(self.da), &redraw_area, self, null);
    const key_ev = c.gtk_event_controller_key_new();
    c.gtk_widget_add_controller(window, key_ev);
    const im_context = c.gtk_im_multicontext_new();
    // ibus on gtk4 has bug :(
    // c.gtk_event_controller_key_set_im_context(g.g_cast(c.GtkEventControllerKey, c.gtk_event_controller_key_get_type(), key_ev), im_context);
    c.gtk_im_context_set_client_widget(im_context, self.da);
    c.gtk_im_context_set_use_preedit(im_context, c.FALSE);
    _ = g.g_signal_connect(key_ev, "key-pressed", g.G_CALLBACK(&key_pressed), self);

    const button_ev = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(button_ev), 0); // CAN HAS ALL THE BUTTONS
    c.gtk_widget_add_controller(window, @ptrCast(button_ev));
    _ = g.g_signal_connect(button_ev, "pressed", g.G_CALLBACK(&mouse_pressed), self);

    _ = g.g_signal_connect(im_context, "commit", g.G_CALLBACK(&commit), self);

    const focus_ev = c.gtk_event_controller_focus_new();
    c.gtk_widget_add_controller(window, focus_ev);
    // TODO: this does not work! (when ALT-TAB)
    _ = g.g_signal_connect(focus_ev, "enter", g.G_CALLBACK(&focus_enter), im_context);
    _ = g.g_signal_connect(focus_ev, "leave", g.G_CALLBACK(&focus_leave), im_context);
    c.gtk_widget_set_focusable(window, 1);
    c.gtk_widget_set_focusable(self.da, 1);

    //_ = g.g_signal_connect_swapped(self.da, "clicked", g.G_CALLBACK(c.gtk_window_destroy), window);
    c.gtk_box_append(g.GTK_BOX(box), self.da);
    c.gtk_widget_show(window);
}
pub fn main() u8 {
    // TODO: can we refer directly to .gpa in further fields?
    var self = Self{ .gpa = std.heap.GeneralPurposeAllocator(.{}){} };

    const app: *c.GtkApplication = c.gtk_application_new("io.github.bfredl.zignvim", c.G_APPLICATION_FLAGS_NONE);
    defer c.g_object_unref(@ptrCast(app));

    _ = g.g_signal_connect(app, "activate", g.G_CALLBACK(&activate), &self);
    const status = c.g_application_run(
        g.g_cast(c.GApplication, c.g_application_get_type(), app),
        @intCast(std.os.argv.len),
        @ptrCast(std.os.argv.ptr),
    );
    return @intCast(status);
}
