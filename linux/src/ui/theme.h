#ifndef MS_THEME_H
#define MS_THEME_H

#include <cairo.h>
#include <glib.h>

typedef enum {
    MS_THEME_DARK,
    MS_THEME_LIGHT
} ThemeMode;

typedef struct {
    double r, g, b, a;
} UiColor;

typedef struct {
    ThemeMode mode;

    UiColor window_bg;
    UiColor chrome_bg;
    UiColor content_bg;
    UiColor sidebar_bg;
    UiColor panel_bg;
    UiColor panel_footer_bg;

    UiColor text_primary;
    UiColor text_bright;
    UiColor text_secondary;
    UiColor text_muted;
    UiColor text_label;

    UiColor hairline;
    UiColor hairline_soft;

    UiColor speed_red;
    UiColor speed_red_fill;
    UiColor verified;
    UiColor caution;

    UiColor primary_action_bg;
    UiColor primary_action_fg;
    UiColor primary_action_border;
    UiColor primary_action_hover_bg;
    UiColor primary_action_pressed_bg;
    UiColor primary_action_disabled_bg;
    UiColor primary_action_disabled_fg;

    UiColor media_jpeg;
    UiColor media_raw;
    UiColor media_other;
    UiColor media_video;

    UiColor banner_success_bg;
    UiColor banner_success_icon_bg;
    UiColor banner_success_icon_fg;

    /* Shuttle bus mark colors */
    UiColor shuttle_yellow;
    UiColor shuttle_card;
    UiColor shuttle_tyre;
    UiColor shuttle_glass;
    UiColor shuttle_rim;
} Theme;

const Theme *theme_get(ThemeMode mode);
void theme_set_source(cairo_t *cr, UiColor color);
void theme_set_source_alpha(cairo_t *cr, UiColor color, double alpha_multiplier);

#endif /* MS_THEME_H */
