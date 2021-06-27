const std = @import("std");
const c = @import("gtk_c.zig");
const g = @import("gtk_lib.zig");

pub fn print_hello(widget: *c.GtkWidget, data: c.gpointer) callconv(.C) void {
    _ = widget;
    _ = data;
    c.g_print("Hello World\n");
}

pub fn activate(app: *c.GtkApplication, user_data: c.gpointer) callconv(.C) void {
    _ = user_data;
    var window: *c.GtkWidget = c.gtk_application_window_new(app);
    c.gtk_window_set_title(g.GTK_WINDOW(window), "Window");
    c.gtk_window_set_default_size(g.GTK_WINDOW(window), 200, 200);
    var box: *c.GtkWidget = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    c.gtk_window_set_child(g.GTK_WINDOW(window), box);
    var button: *c.GtkWidget = c.gtk_button_new_with_label("Hello World");
    _ = g.g_signal_connect(button, "clicked", g.G_CALLBACK(print_hello), null);
    _ = g.g_signal_connect_swapped(button, "clicked", g.G_CALLBACK(c.gtk_window_destroy), window);
    c.gtk_box_append(g.GTK_BOX(box), button);
    c.gtk_widget_show(window);
}
pub export fn main() u8 {
    var argc = @intCast(c_int, std.os.argv.len);
    var argv = @ptrCast([*c][*c]u8, std.os.argv.ptr);
    var app: *c.GtkApplication = c.gtk_application_new("io.github.bfredl.zignvim", c.G_APPLICATION_FLAGS_NONE);
    defer c.g_object_unref(@ptrCast(c.gpointer, app));

    _ = g.g_signal_connect(app, "activate", g.G_CALLBACK(activate), c.NULL);
    var status = c.g_application_run(g.g_cast(c.GApplication, c.g_application_get_type(), app), argc, argv);
    return @intCast(u8, status);
}
