// zig build-exe gtk_main.zig -I/usr/include/gtk-4.0 -I/usr/include/pango-1.0 -I/usr/include/glib-2.0 -I/usr/lib/glib-2.0/include -I/usr/include/harfbuzz -I/usr/include/freetype2 -I/usr/include/libpng16 -I/usr/include/libmount -I/usr/include/blkid -I/usr/include/fribidi -I/usr/include/cairo -I/usr/include/lzo -I/usr/include/pixman-1 -I/usr/include/gdk-pixbuf-2.0 -I/usr/include/graphene-1.0 -I/usr/lib/graphene-1.0/include -I/usr/include/gio-unix-2.0 -I/usr/include/ -lgtk-4 -lpangocairo-1.0 -lpango-1.0 -lharfbuzz -lgdk_pixbuf-2.0 -lcairo-gobject -lcairo -lvulkan -lgraphene-1.0 -lgio-2.0 -lgobject-2.0 -lglib-2.0 -lc

const std = @import("std");
const c = @import("gtk_c.zig");
const g = @import("gtk_lib.zig");
const GTK_WINDOW = g.GTK_WINDOW;
const G_CALLBACK = g.G_CALLBACK;

pub fn print_hello(arg_widget: [*c]c.GtkWidget, arg_data: c.gpointer) callconv(.C) void {
    var widget = arg_widget;
    _ = widget;
    var data = arg_data;
    _ = data;
    c.g_print("Hello World\n");
}

pub fn activate(app: [*c]c.GtkApplication, user_data: c.gpointer) callconv(.C) void {
    _ = user_data;
    var window: *c.GtkWidget = c.gtk_application_window_new(app);
    c.gtk_window_set_title(g.GTK_WINDOW(window), "Window");
    c.gtk_window_set_default_size(g.GTK_WINDOW(window), @as(c_int, 200), @as(c_int, 200));
    var box: *c.GtkWidget = c.gtk_box_new(@bitCast(c_uint, c.GTK_ORIENTATION_HORIZONTAL), @as(c_int, 0));
    c.gtk_window_set_child(g.GTK_WINDOW(window), box);
    var button: *c.GtkWidget = c.gtk_button_new_with_label("Hello World");
    _ = c.g_signal_connect_data(@ptrCast(c.gpointer, button), "clicked", G_CALLBACK(print_hello), @intToPtr(?*c_void, @as(c_int, 0)), null, @bitCast(c_uint, @as(c_int, 0)));
    _ = c.g_signal_connect_data(@ptrCast(c.gpointer, button), "clicked", G_CALLBACK(c.gtk_window_destroy), @ptrCast(c.gpointer, window), null, @bitCast(c_uint, c.G_CONNECT_SWAPPED));
    c.gtk_box_append(g.GTK_BOX(box), button);
    c.gtk_widget_show(window);
}
pub export fn main() u8 {
    var argc = @intCast(c_int, std.os.argv.len);
    var argv = @ptrCast([*c][*c]u8, std.os.argv.ptr);
    var app: *c.GtkApplication = c.gtk_application_new("io.github.bfredl.zignvim", @bitCast(c_uint, c.G_APPLICATION_FLAGS_NONE));
    _ = c.g_signal_connect_data(@ptrCast(c.gpointer, app), "activate", @ptrCast(c.GCallback, @alignCast(@import("std").meta.alignment(fn () callconv(.C) void), activate)), @intToPtr(?*c_void, @as(c_int, 0)), null, @bitCast(c_uint, @as(c_int, 0)));
    var status = c.g_application_run(@ptrCast([*c]c.GApplication, @alignCast(@import("std").meta.alignment(c.GApplication), c.g_type_check_instance_cast(@ptrCast([*c]c.GTypeInstance, @alignCast(@import("std").meta.alignment(c.GTypeInstance), app)), c.g_application_get_type()))), argc, argv);
    c.g_object_unref(@ptrCast(c.gpointer, app));
    return @intCast(u8, status);
}
