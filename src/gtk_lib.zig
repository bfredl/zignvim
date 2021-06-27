const std = @import("std");
const c = @import("gtk_c.zig");

// translate-C of GTK_WINDOW etc macros fails, let's doit ourselves
pub fn g_cast(comptime T: type, gtk_type: c.GType, value: anytype) *T {
    return @ptrCast(*T, c.g_type_check_instance_cast(@ptrCast(*c.GTypeInstance, value), gtk_type));
}

pub fn GTK_WINDOW(value: anytype) *c.GtkWindow {
    return g_cast(c.GtkWindow, c.gtk_window_get_type(), value);
}

pub fn GTK_BOX(value: anytype) *c.GtkBox {
    return g_cast(c.GtkBox, c.gtk_box_get_type(), value);
}

pub fn GTK_DRAWING_AREA(value: anytype) *c.GtkDrawingArea {
    return g_cast(c.GtkDrawingArea, c.gtk_drawing_area_get_type(), value);
}

pub fn G_CALLBACK(value: anytype) c.GCallback {
    return @ptrCast(c.GCallback, @alignCast(std.meta.alignment(fn () callconv(.C) void), value));
}

pub fn g_signal_connect_data(instance: anytype, detailed_signal: [*:0]const u8, handler: anytype, data: anytype, flags: anytype) c.gulong {
    return c.g_signal_connect_data(instance, detailed_signal, handler, data, null, std.zig.c_translation.cast(c.GConnectFlags, flags));
}

pub fn g_signal_connect(instance: anytype, detailed_signal: [*:0]const u8, handler: anytype, data: anytype) c.gulong {
    return g_signal_connect_data(instance, detailed_signal, handler, data, 0);
}

pub fn g_signal_connect_swapped(instance: anytype, detailed_signal: [*:0]const u8, handler: anytype, data: anytype) c.gulong {
    return g_signal_connect_data(instance, detailed_signal, handler, data, c.G_CONNECT_SWAPPED);
}
