const std = @import("std");
const c = @import("gtk_c.zig");
const g = @import("gtk_lib.zig");
const io = @import("io_native.zig");
const RPC = @import("RPC.zig");
const mem = std.mem;

const ArrayList = std.ArrayList;
const mpack = @import("./mpack.zig");

const dbg = std.debug.print;

const Self = @This();

const io_mode = std.io.Mode.evented;

gpa: std.heap.GeneralPurposeAllocator(.{}),

child: *std.ChildProcess = undefined,
enc_buf: ArrayList(u8) = undefined,
key_buf: ArrayList(u8) = undefined,

buf: [1024]u8 = undefined,
decoder: mpack.Decoder = undefined,
rpc: RPC = undefined,

window: *c.GtkWindow = undefined,
da: *c.GtkWidget = undefined,
cs: ?*c.cairo_surface_t = null,
rows: u16 = 0,
cols: u16 = 0,

layout: *c.PangoLayout = undefined,
//font_name: []u8,
cell_width: u32 = 0,
cell_height: u32 = 0,

// TODO: this fails to build???
// decodeFrame: @Frame(RPC.decodeLoop) = undefined,
df: anyframe->RPC.RPCError!void = undefined,

fn get_self(data: c.gpointer) *Self {
    return @ptrCast(*Self, @alignCast(@alignOf(Self), data));
}

fn key_pressed(_: *c.GtkEventControllerKey, keyval: c.guint, keycode: c.guint, mod: c.GdkModifierType, data: c.gpointer) callconv(.C) void {
    _ = keycode;
    var self = get_self(data);
    self.onKeyPress(keyval, mod) catch @panic("We live inside of a dream!");
}

fn onKeyPress(self: *Self, keyval: c.guint, mod: c.guint) !void {
    var special: ?[:0]const u8 = switch (keyval) {
        c.GDK_KEY_Left => "Left",
        c.GDK_KEY_Right => "Right",
        else => null,
    };
    var x: [4]u8 = undefined;

    var codepoint = c.gdk_keyval_to_unicode(keyval);
    dbg("Hellooooo! {} {} {}\n", .{ keyval, mod, codepoint });
    if (codepoint == 0 or codepoint > std.math.maxInt(u21)) {
        return;
    }
    const len = std.unicode.utf8Encode(@intCast(u21, codepoint), x[0..x.len]) catch @panic("aaaah");
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

fn doCommit(self: *Self, str: []const u8) !void {
    dbg("aha: {s}\n", .{str});
    var encoder = mpack.encoder(self.enc_buf.writer());
    try io.unsafe_input(encoder, str);
    try self.child.stdin.?.writeAll(self.enc_buf.items);
    try self.enc_buf.resize(0);
}

fn commit(_: *c.GtkIMContext, str: [*:0]const u8, data: c.gpointer) callconv(.C) void {
    var self = get_self(data);

    self.doCommit(str[0..mem.len(str)]) catch @panic("It was a dream!");
}

fn focus_enter(_: *c.GtkEventControllerFocus, data: c.gpointer) callconv(.C) void {
    c.g_print("änter\n");
    var im_context = @ptrCast(*c.GtkIMContext, @alignCast(@alignOf(c.GtkIMContext), data));
    c.gtk_im_context_focus_in(im_context);
}

fn focus_leave(_: *c.GtkEventControllerFocus, data: c.gpointer) callconv(.C) void {
    c.g_print("you must leave now\n");
    var im_context = @ptrCast(*c.GtkIMContext, @alignCast(@alignOf(c.GtkIMContext), data));
    c.gtk_im_context_focus_out(im_context);
}

fn on_stdout(_: ?*c.GIOChannel, cond: c.GIOCondition, data: c.gpointer) callconv(.C) c.gboolean {
    _ = cond;
    // dbg("DATTA\n", .{});

    var self = get_self(data);
    if (self.decoder.frame == null) {
        dbg("The cow jumped over the moon\n", .{});
        nosuspend await self.df catch @panic("mooooh");
        return 0;
    }

    const oldlen = self.decoder.data.len;
    if (oldlen > 0 and self.decoder.data.ptr != &self.buf) {
        // TODO: avoid move if remaining space is plenty (like > 900)
        mem.copy(u8, &self.buf, self.decoder.data);
    }
    var stdout = &self.child.stdout.?;
    var lenny = stdout.read(self.buf[oldlen..]) catch @panic("call for help");
    self.decoder.data = self.buf[0 .. oldlen + lenny];

    resume self.decoder.frame.?;

    while (self.rpc.frame) |frame| {
        // NB: this doesn't mean specifically flush,
        // but currently it is the only event rpc will return back
        // to the main loop
        self.flush() catch @panic("le panic");
        resume frame;
    }

    return 1;
}

fn flush(self: *Self) !void {
    dbg("le flush\n", .{});
    try self.rpc.dumpGrid();

    const grid = &self.rpc.grid[0];

    // TODO: the right condition for "font[size] changed"
    if (self.cell_height == 0) {
        try self.set_font("JuliaMono 15");
    }

    if (self.rows != grid.rows or self.cols != grid.cols) {
        dbg("le resize\n", .{});
        self.rows = grid.rows;
        self.cols = grid.cols;
        const width = @intCast(c_int, self.cols * self.cell_width);
        const height = @intCast(c_int, self.rows * self.cell_height);

        dbg("LE METRICS {} {}", .{ width, height });

        c.gtk_drawing_area_set_content_width(g.GTK_DRAWING_AREA(self.da), width);
        c.gtk_drawing_area_set_content_height(g.GTK_DRAWING_AREA(self.da), height);

        if (self.cs) |cs| {
            c.cairo_surface_destroy(cs);
        }
        const surface = c.gtk_native_get_surface(g.g_cast(c.GtkNative, c.gtk_native_get_type(), self.window));
        self.cs = c.gdk_surface_create_similar_surface(surface, c.CAIRO_CONTENT_COLOR, width, height);
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
    dbg("s {}\n", .{@ptrToInt(surface)});
    //const cc = c.gdk_surface_create_cairo_context(surface);
    // dbg("cc {}\n", .{@ptrToInt(cc)});
    var cairo = c.cairo_create(dummy_surface);
    dbg("cairso {}\n", .{@ptrToInt(cairo)});
    var fontdesc = c.pango_font_description_from_string(font);

    var pctx = c.pango_cairo_create_context(cairo);
    c.pango_context_set_font_description(pctx, fontdesc);

    var metrics = c.pango_context_get_metrics(pctx, fontdesc, c.pango_context_get_language(pctx));
    var width = c.pango_font_metrics_get_approximate_char_width(metrics);
    var height = c.pango_font_metrics_get_height(metrics);
    self.cell_width = @intCast(u32, pango_pixels_ceil(width));
    self.cell_height = @intCast(u32, pango_pixels_ceil(height));

    dbg("le foont terrible {} {}\n", .{ self.cell_width, self.cell_height });

    self.layout = c.pango_layout_new(pctx) orelse return error.AmIAloneInHere;
    c.pango_layout_set_font_description(self.layout, fontdesc);
    c.pango_layout_set_alignment(self.layout, c.PANGO_ALIGN_LEFT);
}

fn init(self: *Self) !void {
    self.child = try io.spawn(&self.gpa.allocator);
    self.enc_buf = ArrayList(u8).init(&self.gpa.allocator);
    self.key_buf = ArrayList(u8).init(&self.gpa.allocator);

    self.decoder = mpack.Decoder{ .data = self.buf[0..0] };
    self.rpc = RPC.init(&self.gpa.allocator);

    // TODO: this should not be allocated, but @Frame(RPC.decodeLoop) fails at module scope..
    var decodeFrame = try self.gpa.allocator.create(@Frame(RPC.decodeLoop));
    decodeFrame.* = async self.rpc.decodeLoop(&self.decoder);
    self.df = decodeFrame;

    var encoder = mpack.encoder(self.enc_buf.writer());
    try io.attach_test(&encoder);
    try self.child.stdin.?.writeAll(self.enc_buf.items);
    try self.enc_buf.resize(0);

    var gio = c.g_io_channel_unix_new(self.child.stdout.?.handle);
    _ = c.g_io_add_watch(gio, c.G_IO_IN, on_stdout, self);
}

fn activate(app: *c.GtkApplication, data: c.gpointer) callconv(.C) void {
    var self = get_self(data);
    self.init() catch @panic("heeee");

    var window: *c.GtkWidget = c.gtk_application_window_new(app);
    self.window = g.GTK_WINDOW(window);

    c.gtk_window_set_title(g.GTK_WINDOW(window), "Window");
    c.gtk_window_set_default_size(g.GTK_WINDOW(window), 200, 200);
    var box: *c.GtkWidget = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    c.gtk_window_set_child(g.GTK_WINDOW(window), box);
    self.da = c.gtk_drawing_area_new();
    c.gtk_drawing_area_set_content_width(g.GTK_DRAWING_AREA(self.da), 500);
    c.gtk_drawing_area_set_content_height(g.GTK_DRAWING_AREA(self.da), 500);
    var key_ev = c.gtk_event_controller_key_new();
    c.gtk_widget_add_controller(window, key_ev);
    var im_context = c.gtk_im_multicontext_new();
    // ibus on gtk4 has bug :(
    // c.gtk_event_controller_key_set_im_context(g.g_cast(c.GtkEventControllerKey, c.gtk_event_controller_key_get_type(), key_ev), im_context);
    c.gtk_im_context_set_client_widget(im_context, self.da);
    c.gtk_im_context_set_use_preedit(im_context, c.FALSE);
    _ = g.g_signal_connect(key_ev, "key-pressed", g.G_CALLBACK(key_pressed), self);
    _ = g.g_signal_connect(im_context, "commit", g.G_CALLBACK(commit), self);

    var focus_ev = c.gtk_event_controller_focus_new();
    c.gtk_widget_add_controller(window, focus_ev);
    // TODO: this does not work! (when ALT-TAB)
    _ = g.g_signal_connect(focus_ev, "enter", g.G_CALLBACK(focus_enter), im_context);
    _ = g.g_signal_connect(focus_ev, "leave", g.G_CALLBACK(focus_leave), im_context);
    c.gtk_widget_set_focusable(window, 1);
    c.gtk_widget_set_focusable(self.da, 1);

    //_ = g.g_signal_connect_swapped(self.da, "clicked", g.G_CALLBACK(c.gtk_window_destroy), window);
    c.gtk_box_append(g.GTK_BOX(box), self.da);
    c.gtk_widget_show(window);
}
pub fn main() u8 {
    var argc = @intCast(c_int, std.os.argv.len);
    var argv = @ptrCast([*c][*c]u8, std.os.argv.ptr);

    // TODO: can we refer directly to .gpa in further fields?
    var self = Self{ .gpa = std.heap.GeneralPurposeAllocator(.{}){} };

    var app: *c.GtkApplication = c.gtk_application_new("io.github.bfredl.zignvim", c.G_APPLICATION_FLAGS_NONE);
    defer c.g_object_unref(@ptrCast(c.gpointer, app));

    _ = g.g_signal_connect(app, "activate", g.G_CALLBACK(activate), &self);
    var status = c.g_application_run(g.g_cast(c.GApplication, c.g_application_get_type(), app), argc, argv);
    return @intCast(u8, status);
}
