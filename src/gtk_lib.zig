const std = @import("std");
const c = @import("gtk_c.zig");

// translate-C of GTK_WINDOW etc macros fails, let's doit ourselves
fn gtk_cast(comptime T: type, gtk_type: anytype, value: anytype) *T {
    return @ptrCast(*T, @alignCast(std.meta.alignment(T), c.g_type_check_instance_cast(@ptrCast([*c]c.GTypeInstance, @alignCast(std.meta.alignment(c.GTypeInstance), value)), gtk_type)));
}

pub fn GTK_WINDOW(value: anytype) *c.GtkWindow {
    return gtk_cast(c.GtkWindow, c.gtk_window_get_type(), value);
}

pub fn GTK_BOX(value: anytype) *c.GtkBox {
    return gtk_cast(c.GtkBox, c.gtk_box_get_type(), value);
}

pub fn G_CALLBACK(value: anytype) c.GCallback {
    return @ptrCast(c.GCallback, @alignCast(std.meta.alignment(fn () callconv(.C) void), value));
}
