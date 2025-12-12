const c = @import("gtk_c.zig").c;
const g = @import("gtk_lib.zig");
const std = @import("std");
const dbg = std.debug.print;

fn command_line(
    app: *c.GtkApplication,
    cmdline: *c.GApplicationCommandLine,
    data: c.gpointer,
) callconv(.c) void {
    var argc: c.gint = 0;
    const argv = c.g_application_command_line_get_arguments(cmdline, &argc);

    _ = data;
    const window: *c.GtkWidget = c.gtk_application_window_new(app);

    const font = "JuliaMono 15";
    const fontdesc = c.pango_font_description_from_string(font);
    const pctx = c.gtk_widget_get_pango_context(window) orelse @panic("pango pongo");
    c.pango_context_set_font_description(pctx, fontdesc);

    var text: []const u8 = "hewwo";
    if (argc > 1) {
        text = std.mem.span(argv[1]);
    }
    const attr_list = c.pango_attr_list_new();
    var item_list = c.pango_itemize(pctx, text.ptr, 0, @intCast(text.len), attr_list, null);

    const glyphs = g.pango_glyph_string_new() orelse @panic("GLYP");
    while (item_list) |item| {
        const i: *c.PangoItem = @ptrCast(@alignCast(item.*.data));
        item_list = c.g_list_delete_link(item, item);
        dbg("ITYM {}\n", .{i.*});
        const desc = c.pango_font_describe(i.analysis.font);
        dbg("FOONT {s}\n", .{c.pango_font_description_to_string(desc)});

        g.pango_shape_full(text[@intCast(i.offset)..].ptr, i.length, text.ptr, @intCast(text.len), &i.analysis, glyphs);

        for (glyphs.glyphs[0..@intCast(glyphs.num_glyphs)]) |gl| {
            dbg("GLYP {}\n", .{gl});
        }
    }
}

pub fn main() u8 {
    const app: *c.GtkApplication = c.gtk_application_new("io.github.bfredl.zignvim", c.G_APPLICATION_HANDLES_COMMAND_LINE);
    defer c.g_object_unref(@ptrCast(app));

    _ = g.g_signal_connect(app, "command-line", g.G_CALLBACK(&command_line), null);
    const status = c.g_application_run(
        g.g_cast(c.GApplication, c.g_application_get_type(), app),
        @intCast(std.os.argv.len),
        @ptrCast(std.os.argv.ptr),
    );
    return @intCast(status);
}
