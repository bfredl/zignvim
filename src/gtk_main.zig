// zig build-exe gtk_main.zig -I/usr/include/gtk-4.0 -I/usr/include/pango-1.0 -I/usr/include/glib-2.0 -I/usr/lib/glib-2.0/include -I/usr/include/harfbuzz -I/usr/include/freetype2 -I/usr/include/libpng16 -I/usr/include/libmount -I/usr/include/blkid -I/usr/include/fribidi -I/usr/include/cairo -I/usr/include/lzo -I/usr/include/pixman-1 -I/usr/include/gdk-pixbuf-2.0 -I/usr/include/graphene-1.0 -I/usr/lib/graphene-1.0/include -I/usr/include/gio-unix-2.0 -I/usr/include/ -lgtk-4 -lpangocairo-1.0 -lpango-1.0 -lharfbuzz -lgdk_pixbuf-2.0 -lcairo-gobject -lcairo -lvulkan -lgraphene-1.0 -lgio-2.0 -lgobject-2.0 -lglib-2.0 -lc

const std = @import("std");
const c = @cImport({
    @cInclude("gtk/gtk.h");
});

pub fn print_hello(arg_widget: [*c]c.GtkWidget, arg_data: c.gpointer) callconv(.C) void {
    var widget = arg_widget;
    _ = widget;
    var data = arg_data;
    _ = data;
    c.g_print("Hello World\n");
}

pub fn gtk_cast(comptime T: type, gtk_type: anytype, value: anytype) *T {
    return @ptrCast(*T, @alignCast(@import("std").meta.alignment(T), c.g_type_check_instance_cast(@ptrCast([*c]c.GTypeInstance, @alignCast(@import("std").meta.alignment(c.GTypeInstance), value)), gtk_type)));
}

pub fn activate(arg_app: [*c]c.GtkApplication, arg_user_data: c.gpointer) callconv(.C) void {
    var app = arg_app;
    _ = app;
    var user_data = arg_user_data;
    _ = user_data;
    var window: [*c]c.GtkWidget = undefined;
    _ = window;
    var button: [*c]c.GtkWidget = undefined;
    _ = button;
    var box: [*c]c.GtkWidget = undefined;
    _ = box;
    window = c.gtk_application_window_new(app);
    c.gtk_window_set_title(gtk_cast(c.GtkWindow, c.gtk_window_get_type(), window), "Window");
    c.gtk_window_set_default_size(@ptrCast([*c]c.GtkWindow, @alignCast(@import("std").meta.alignment(c.GtkWindow), c.g_type_check_instance_cast(@ptrCast([*c]c.GTypeInstance, @alignCast(@import("std").meta.alignment(c.GTypeInstance), window)), c.gtk_window_get_type()))), @as(c_int, 200), @as(c_int, 200));
    box = c.gtk_box_new(@bitCast(c_uint, c.GTK_ORIENTATION_HORIZONTAL), @as(c_int, 0));
    c.gtk_window_set_child(@ptrCast([*c]c.GtkWindow, @alignCast(@import("std").meta.alignment(c.GtkWindow), c.g_type_check_instance_cast(@ptrCast([*c]c.GTypeInstance, @alignCast(@import("std").meta.alignment(c.GTypeInstance), window)), c.gtk_window_get_type()))), box);
    button = c.gtk_button_new_with_label("Hello World");
    _ = c.g_signal_connect_data(@ptrCast(c.gpointer, button), "clicked", @ptrCast(c.GCallback, @alignCast(@import("std").meta.alignment(fn () callconv(.C) void), print_hello)), @intToPtr(?*c_void, @as(c_int, 0)), null, @bitCast(c_uint, @as(c_int, 0)));
    _ = c.g_signal_connect_data(@ptrCast(c.gpointer, button), "clicked", @ptrCast(c.GCallback, @alignCast(@import("std").meta.alignment(fn () callconv(.C) void), c.gtk_window_destroy)), @ptrCast(c.gpointer, window), null, @bitCast(c_uint, c.G_CONNECT_SWAPPED));
    c.gtk_box_append(@ptrCast([*c]c.GtkBox, @alignCast(@import("std").meta.alignment(c.GtkBox), c.g_type_check_instance_cast(@ptrCast([*c]c.GTypeInstance, @alignCast(@import("std").meta.alignment(c.GTypeInstance), box)), c.gtk_box_get_type()))), button);
    c.gtk_widget_show(window);
}
pub export fn main() u8 {
    var argc = @intCast(c_int, std.os.argv.len);
    _ = argc;
    var argv = @ptrCast([*c][*c]u8, std.os.argv.ptr);
    _ = argv;
    var app: [*c]c.GtkApplication = undefined;
    _ = app;
    var status: c_int = undefined;
    _ = status;
    app = c.gtk_application_new("io.github.bfredl.zignvim", @bitCast(c_uint, c.G_APPLICATION_FLAGS_NONE));
    _ = c.g_signal_connect_data(@ptrCast(c.gpointer, app), "activate", @ptrCast(c.GCallback, @alignCast(@import("std").meta.alignment(fn () callconv(.C) void), activate)), @intToPtr(?*c_void, @as(c_int, 0)), null, @bitCast(c_uint, @as(c_int, 0)));
    status = c.g_application_run(@ptrCast([*c]c.GApplication, @alignCast(@import("std").meta.alignment(c.GApplication), c.g_type_check_instance_cast(@ptrCast([*c]c.GTypeInstance, @alignCast(@import("std").meta.alignment(c.GTypeInstance), app)), c.g_application_get_type()))), argc, argv);
    c.g_object_unref(@ptrCast(c.gpointer, app));
    return @intCast(u8, status);
}
