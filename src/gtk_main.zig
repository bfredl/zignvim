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
        c.g_print("The cow jumped over the moon\n");
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
    return 1;
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
    c.gtk_window_set_title(g.GTK_WINDOW(window), "Window");
    c.gtk_window_set_default_size(g.GTK_WINDOW(window), 200, 200);
    var box: *c.GtkWidget = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    c.gtk_window_set_child(g.GTK_WINDOW(window), box);
    var da: *c.GtkWidget = c.gtk_drawing_area_new();
    c.gtk_drawing_area_set_content_width(g.GTK_DRAWING_AREA(da), 500);
    c.gtk_drawing_area_set_content_height(g.GTK_DRAWING_AREA(da), 500);
    var key_ev = c.gtk_event_controller_key_new();
    c.gtk_widget_add_controller(window, key_ev);
    var im_context = c.gtk_im_multicontext_new();
    // ibus on gtk4 has bug :(
    // c.gtk_event_controller_key_set_im_context(g.g_cast(c.GtkEventControllerKey, c.gtk_event_controller_key_get_type(), key_ev), im_context);
    c.gtk_im_context_set_client_widget(im_context, da);
    c.gtk_im_context_set_use_preedit(im_context, c.FALSE);
    _ = g.g_signal_connect(key_ev, "key-pressed", g.G_CALLBACK(key_pressed), self);
    _ = g.g_signal_connect(im_context, "commit", g.G_CALLBACK(commit), self);

    var focus_ev = c.gtk_event_controller_focus_new();
    c.gtk_widget_add_controller(window, focus_ev);
    // TODO: this does not work! (when ALT-TAB)
    _ = g.g_signal_connect(focus_ev, "enter", g.G_CALLBACK(focus_enter), im_context);
    _ = g.g_signal_connect(focus_ev, "leave", g.G_CALLBACK(focus_leave), im_context);
    c.gtk_widget_set_focusable(window, 1);
    c.gtk_widget_set_focusable(da, 1);

    //_ = g.g_signal_connect_swapped(da, "clicked", g.G_CALLBACK(c.gtk_window_destroy), window);
    c.gtk_box_append(g.GTK_BOX(box), da);
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
