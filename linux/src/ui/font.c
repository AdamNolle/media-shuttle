#include "font.h"
#include <fontconfig/fontconfig.h>
#include <stdio.h>
#include <string.h>

static gboolean font_initialized = FALSE;

void font_init(const char *asset_dir)
{
    if (font_initialized) {
        return;
    }
    font_initialized = TRUE;

    FcInit();
    FcConfig *config = FcConfigGetCurrent();

    const char *candidates[] = {
        asset_dir ? g_build_filename(asset_dir, "CascadiaMono.ttf", NULL) : NULL,
        g_build_filename("linux", "assets", "CascadiaMono.ttf", NULL),
        g_build_filename("assets", "CascadiaMono.ttf", NULL),
        g_build_filename("..", "assets", "CascadiaMono.ttf", NULL),
        g_build_filename("..", "linux", "assets", "CascadiaMono.ttf", NULL)
    };

    for (guint i = 0; i < G_N_ELEMENTS(candidates); i++) {
        if (candidates[i] != NULL && g_file_test(candidates[i], G_FILE_TEST_EXISTS)) {
            FcConfigAppFontAddFile(config, (const FcChar8 *) candidates[i]);
            break;
        }
    }

    for (guint i = 0; i < G_N_ELEMENTS(candidates); i++) {
        g_free((char *) candidates[i]);
    }
}

static PangoLayout *create_layout(
    cairo_t *cr,
    const char *text,
    double size_pt,
    TextWeight weight,
    double letter_spacing,
    double max_width,
    TextAlign align)
{
    PangoLayout *layout = pango_cairo_create_layout(cr);
    pango_layout_set_text(layout, text ? text : "", -1);

    PangoFontDescription *desc = pango_font_description_new();
    pango_font_description_set_family(desc, "Cascadia Mono, monospace");
    /* In XAML / CSS, 1 font size unit = 1 device pixel at 96 DPI */
    pango_font_description_set_absolute_size(desc, size_pt * PANGO_SCALE);
    pango_font_description_set_weight(desc, (PangoWeight) weight);
    pango_layout_set_font_description(layout, desc);
    pango_font_description_free(desc);

    if (letter_spacing > 0.001 || letter_spacing < -0.001) {
        PangoAttrList *attrs = pango_attr_list_new();
        /* tracking is in 1/1000 em */
        int tracking_pango = (int) (letter_spacing * size_pt * PANGO_SCALE);
        pango_attr_list_insert(attrs, pango_attr_letter_spacing_new(tracking_pango));
        pango_layout_set_attributes(layout, attrs);
        pango_attr_list_unref(attrs);
    }

    if (max_width > 0) {
        pango_layout_set_width(layout, (int) (max_width * PANGO_SCALE));
        pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END);
        if (align == MS_ALIGN_CENTER) {
            pango_layout_set_alignment(layout, PANGO_ALIGN_CENTER);
        } else if (align == MS_ALIGN_RIGHT) {
            pango_layout_set_alignment(layout, PANGO_ALIGN_RIGHT);
        } else {
            pango_layout_set_alignment(layout, PANGO_ALIGN_LEFT);
        }
    }

    return layout;
}

void font_draw_text(
    cairo_t *cr,
    const char *text,
    double x,
    double y,
    double size_pt,
    TextWeight weight,
    UiColor color,
    double letter_spacing,
    double max_width,
    TextAlign align)
{
    if (text == NULL || *text == '\0') {
        return;
    }

    PangoLayout *layout = create_layout(cr, text, size_pt, weight, letter_spacing, max_width, align);

    int text_w = 0, text_h = 0;
    pango_layout_get_pixel_size(layout, &text_w, &text_h);

    double draw_x = x;
    double draw_y = y;

    if (max_width <= 0) {
        if (align == MS_ALIGN_CENTER) {
            draw_x = x - (text_w / 2.0);
        } else if (align == MS_ALIGN_RIGHT) {
            draw_x = x - text_w;
        }
    }

    cairo_save(cr);
    theme_set_source(cr, color);
    cairo_move_to(cr, draw_x, draw_y);
    pango_cairo_show_layout(cr, layout);
    cairo_restore(cr);

    g_object_unref(layout);
}

void font_measure_text(
    cairo_t *cr,
    const char *text,
    double size_pt,
    TextWeight weight,
    double letter_spacing,
    double *out_width,
    double *out_height)
{
    if (text == NULL || *text == '\0') {
        if (out_width) *out_width = 0;
        if (out_height) *out_height = 0;
        return;
    }

    PangoLayout *layout = create_layout(cr, text, size_pt, weight, letter_spacing, -1, MS_ALIGN_LEFT);
    int w = 0, h = 0;
    pango_layout_get_pixel_size(layout, &w, &h);
    if (out_width) *out_width = (double) w;
    if (out_height) *out_height = (double) h;
    g_object_unref(layout);
}
