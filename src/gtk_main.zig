const std = @import("std");
const c = @import("gtk_c.zig");
const g = @import("gtk_lib.zig");

pub fn key_pressed(_: *c.GtkEventControllerKey, keyval: c.guint, keycode: c.guint, mod: c.GdkModifierType, data: c.gpointer) callconv(.C) void {
    _ = keyval;
    _ = keycode;
    _ = mod;
    _ = data;
    c.g_print("Hellooooo!\n");
}

pub fn activate(app: *c.GtkApplication, user_data: c.gpointer) callconv(.C) void {
    _ = user_data;
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
    _ = g.g_signal_connect(key_ev, "key-pressed", g.G_CALLBACK(key_pressed), null);
    //_ = g.g_signal_connect_swapped(da, "clicked", g.G_CALLBACK(c.gtk_window_destroy), window);
    c.gtk_box_append(g.GTK_BOX(box), da);
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
