#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <cairo.h>
#include <glib.h>

#include "../src/ui/theme.h"
#include "../src/ui/font.h"
#include "../src/ui/layout.h"
#include "../src/ui/draw.h"

int main(int argc, char **argv)
{
    const char *out_path = "artifacts/ui-qa/linux-preview.png";
    ThemeMode mode = MS_THEME_DARK;
    gboolean is_preview = TRUE;
    gboolean show_settings = FALSE;
    gboolean show_confirm = FALSE;
    double width = 896.0;
    double height = 832.0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--out") == 0 && i + 1 < argc) {
            out_path = argv[++i];
        } else if (strcmp(argv[i], "--theme") == 0 && i + 1 < argc) {
            const char *t = argv[++i];
            if (g_ascii_strcasecmp(t, "light") == 0) mode = MS_THEME_LIGHT;
            else mode = MS_THEME_DARK;
        } else if (strcmp(argv[i], "--empty") == 0) {
            is_preview = FALSE;
        } else if (strcmp(argv[i], "--settings") == 0) {
            show_settings = TRUE;
        } else if (strcmp(argv[i], "--confirm") == 0) {
            show_confirm = TRUE;
        } else if (strcmp(argv[i], "--width") == 0 && i + 1 < argc) {
            width = atof(argv[++i]);
        } else if (strcmp(argv[i], "--height") == 0 && i + 1 < argc) {
            height = atof(argv[++i]);
        }
    }

    font_init("assets");

    UiState *state = is_preview ? ui_state_new_preview() : ui_state_new_empty();
    state->window_width = width;
    state->window_height = height;
    state->theme_mode = mode;
    state->settings_open = show_settings;
    state->confirm_erase_open = show_confirm;

    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, (int) width, (int) height);
    cairo_t *cr = cairo_create(surface);

    draw_view(cr, state, "assets");

    cairo_status_t status = cairo_surface_write_to_png(surface, out_path);
    if (status != CAIRO_STATUS_SUCCESS) {
        fprintf(stderr, "Failed to write PNG to %s: %s\n", out_path, cairo_status_to_string(status));
        cairo_destroy(cr);
        cairo_surface_destroy(surface);
        ui_state_free(state);
        return 1;
    }

    printf("Rendered offscreen UI to %s (%d x %d)\n", out_path, (int) width, (int) height);

    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    ui_state_free(state);

    return 0;
}
