const c = @import("gtk_c.zig");
const g = @import("gtk_lib.zig");
const std = @import("std");
const dbg = std.debug.print;

fn activate(app: *c.GtkApplication, data: c.gpointer) callconv(.C) void {
    _ = data;
    const window: *c.GtkWidget = c.gtk_application_window_new(app);

    const font = "JuliaMono 15";
    const fontdesc = c.pango_font_description_from_string(font);
    const pctx = c.gtk_widget_get_pango_context(window) orelse @panic("pango pongo");
    c.pango_context_set_font_description(pctx, fontdesc);

    const text = "hewwo";
    const attr_list = c.pango_attr_list_new();
    var item_list = c.pango_itemize(pctx, text.ptr, 0, @intCast(text.len), attr_list, null);
    while (item_list) |item| {
        const i: *c.PangoItem = @ptrCast(@alignCast(item.*.data));
        item_list = c.g_list_delete_link(item, item);
        dbg("ITYM {}\n", .{i.*});
    }
}

pub fn main() u8 {
    const app: *c.GtkApplication = c.gtk_application_new("io.github.bfredl.zignvim", c.G_APPLICATION_FLAGS_NONE);
    defer c.g_object_unref(@ptrCast(app));

    _ = g.g_signal_connect(app, "activate", g.G_CALLBACK(&activate), null);
    const status = c.g_application_run(
        g.g_cast(c.GApplication, c.g_application_get_type(), app),
        @intCast(std.os.argv.len),
        @ptrCast(std.os.argv.ptr),
    );
    return @intCast(status);
}
