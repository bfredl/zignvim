const std = @import("std");
const c = @import("gtk_c.zig");

// translate-C of GTK_WINDOW etc macros fails, let's doit ourselves
pub fn g_cast(comptime T: type, gtk_type: c.GType, value: anytype) *T {
    return @ptrCast(c.g_type_check_instance_cast(@ptrCast(@alignCast(value)), gtk_type));
}

pub fn GTK_WINDOW(value: anytype) *c.GtkWindow {
    return g_cast(c.GtkWindow, c.gtk_window_get_type(), value);
}

pub fn GTK_WIDGET(value: anytype) *c.GtkWidget {
    return g_cast(c.GtkWidget, c.gtk_widget_get_type(), value);
}

pub fn GTK_BOX(value: anytype) *c.GtkBox {
    return g_cast(c.GtkBox, c.gtk_box_get_type(), value);
}

pub fn GTK_DRAWING_AREA(value: anytype) *c.GtkDrawingArea {
    return g_cast(c.GtkDrawingArea, c.gtk_drawing_area_get_type(), value);
}

pub fn G_CALLBACK(value: anytype) c.GCallback {
    return @ptrCast(@alignCast(value));
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

// delet this when translate-c handles the bitfield in PangoGlyphInfo :p
pub const FakePangoGlyphInfo = extern struct {
    glyph: c.PangoGlyph = @import("std").mem.zeroes(c.PangoGlyph),
    geometry: c.PangoGlyphGeometry = @import("std").mem.zeroes(c.PangoGlyphGeometry),
    attr: c.guint = @import("std").mem.zeroes(c.guint),
};

pub const FakePangoGlyphString = extern struct {
    num_glyphs: c_int = @import("std").mem.zeroes(c_int),
    glyphs: [*c]FakePangoGlyphInfo = @import("std").mem.zeroes(?*FakePangoGlyphInfo),
    log_clusters: [*c]c_int = @import("std").mem.zeroes([*c]c_int),
    space: c_int = @import("std").mem.zeroes(c_int),
};

pub extern fn pango_glyph_string_new() ?*FakePangoGlyphString;
pub extern fn pango_shape_full(item_text: [*c]const u8, item_length: c_int, paragraph_text: [*c]const u8, paragraph_length: c_int, analysis: [*c]const c.PangoAnalysis, glyphs: [*c]FakePangoGlyphString) void;
pub extern fn pango_glyph_string_get_width(glyphs: [*c]FakePangoGlyphString) c_int;
pub extern fn pango_cairo_show_glyph_string(cr: ?*c.cairo_t, font: [*c]c.PangoFont, glyphs: [*c]FakePangoGlyphString) void;
