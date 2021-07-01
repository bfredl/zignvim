const std = @import("std");
const c = @import("gtk_c.zig");
const g = @import("gtk_lib.zig");
const io = @import("io_native.zig");

const ArrayList = std.ArrayList;
const mpack = @import("./mpack.zig");

const Self = @This();

const io_mode = std.io.Mode.evented;

gpa: std.heap.GeneralPurposeAllocator(.{}),

child: *std.ChildProcess = undefined,
enc_buffer: ArrayList(u8) = undefined,

fn get_self(data: c.gpointer) *Self {
    return @ptrCast(*Self, @alignCast(@alignOf(Self), data));
}

fn key_pressed(_: *c.GtkEventControllerKey, keyval: c.guint, keycode: c.guint, mod: c.GdkModifierType, data: c.gpointer) callconv(.C) void {
    _ = keyval;
    _ = keycode;
    _ = mod;
    _ = data;
    c.g_print("Hellooooo!\n");
}

fn commit(_: *c.GtkIMContext, str: [*:0]const u8, data: c.gpointer) callconv(.C) void {
    _ = data;
    c.g_print("aha: ");
    c.g_print(str);
    c.g_print("\n");
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

fn init(self: *Self) !void {
    self.child = try io.spawn(&self.gpa.allocator);
    self.enc_buffer = ArrayList(u8).init(&self.gpa.allocator);
    var encoder = mpack.encoder(self.enc_buffer.writer());
    try io.attach_test(&encoder);
    try self.child.stdin.?.writeAll(self.enc_buffer.items);
    try self.enc_buffer.resize(0);
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
    c.gtk_event_controller_key_set_im_context(g.g_cast(c.GtkEventControllerKey, c.gtk_event_controller_key_get_type(), key_ev), im_context);
    //c.gtk_im_context_set_client_window(im_context, da);
    c.gtk_im_context_set_use_preedit(im_context, c.FALSE);
    _ = g.g_signal_connect(key_ev, "key-pressed", g.G_CALLBACK(key_pressed), null);
    _ = g.g_signal_connect(im_context, "commit", g.G_CALLBACK(commit), null);

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

    var self = Self{ .gpa = std.heap.GeneralPurposeAllocator(.{}){} };

    var app: *c.GtkApplication = c.gtk_application_new("io.github.bfredl.zignvim", c.G_APPLICATION_FLAGS_NONE);
    defer c.g_object_unref(@ptrCast(c.gpointer, app));

    _ = g.g_signal_connect(app, "activate", g.G_CALLBACK(activate), &self);
    var status = c.g_application_run(g.g_cast(c.GApplication, c.g_application_get_type(), app), argc, argv);
    return @intCast(u8, status);
}
