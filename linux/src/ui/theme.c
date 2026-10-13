#include "theme.h"

#define C_HEX(rgb) { \
    ((double)(((rgb) >> 16) & 0xFF)) / 255.0, \
    ((double)(((rgb) >> 8) & 0xFF)) / 255.0, \
    ((double)((rgb) & 0xFF)) / 255.0, \
    1.0 \
}

#define C_RGBA(rgb, a) { \
    ((double)(((rgb) >> 16) & 0xFF)) / 255.0, \
    ((double)(((rgb) >> 8) & 0xFF)) / 255.0, \
    ((double)((rgb) & 0xFF)) / 255.0, \
    (a) \
}

static const Theme dark_theme = {
    .mode = MS_THEME_DARK,
    .window_bg = C_HEX(0x0B0B0C),
    .chrome_bg = C_HEX(0x101012),
    .content_bg = C_HEX(0x161618),
    .sidebar_bg = C_HEX(0x121214),
    .panel_bg = C_HEX(0x1A1A1D),
    .panel_footer_bg = C_HEX(0x17171A),

    .text_primary = C_HEX(0xF0F1F2),
    .text_bright = C_HEX(0xD6DADE),
    .text_secondary = C_HEX(0xB9BEC4),
    .text_muted = C_HEX(0x8B9198),
    .text_label = C_HEX(0x949AA1),

    .hairline = C_RGBA(0xFFFFFF, 0.12),
    .hairline_soft = C_RGBA(0xFFFFFF, 0.07),

    .speed_red = C_HEX(0xFF6A5E),
    .speed_red_fill = C_HEX(0xD33B34),
    .verified = C_HEX(0x5FD08A),
    .caution = C_HEX(0xE0A340),

    .primary_action_bg = C_HEX(0xD6DADE),
    .primary_action_fg = C_HEX(0x1B1B1E),
    .primary_action_border = C_HEX(0xD6DADE),
    .primary_action_hover_bg = C_HEX(0xF0F1F2),
    .primary_action_pressed_bg = C_HEX(0xB9BEC4),
    .primary_action_disabled_bg = C_HEX(0x343539),
    .primary_action_disabled_fg = C_HEX(0x8B9198),

    .media_jpeg = C_HEX(0xCFD3D8),
    .media_raw = C_HEX(0x8B9198),
    .media_other = C_HEX(0x5C6167),
    .media_video = C_HEX(0x3F434A),

    .banner_success_bg = C_HEX(0x202420),
    .banner_success_icon_bg = C_HEX(0x56B870),
    .banner_success_icon_fg = C_HEX(0x0E1C12),

    .shuttle_yellow = C_HEX(0xFFD016),
    .shuttle_card = C_HEX(0x3E4450),
    .shuttle_tyre = C_HEX(0x2F353F),
    .shuttle_glass = C_HEX(0x12151C),
    .shuttle_rim = C_HEX(0xC9CED6),
};

static const Theme light_theme = {
    .mode = MS_THEME_LIGHT,
    .window_bg = C_HEX(0xF0F0F2),
    .chrome_bg = C_HEX(0xE8E8EA),
    .content_bg = C_HEX(0xFFFFFF),
    .sidebar_bg = C_HEX(0xF7F7F8),
    .panel_bg = C_HEX(0xFBFBFC),
    .panel_footer_bg = C_HEX(0xF4F4F6),

    .text_primary = C_HEX(0x1B1B1E),
    .text_bright = C_HEX(0x2A2C30),
    .text_secondary = C_HEX(0x4A4E54),
    .text_muted = C_HEX(0x6D7279),
    .text_label = C_HEX(0x6D7279),

    .hairline = C_RGBA(0x000000, 0.12),
    .hairline_soft = C_RGBA(0x000000, 0.07),

    .speed_red = C_HEX(0xD33B34),
    .speed_red_fill = C_HEX(0xD33B34),
    .verified = C_HEX(0x2F9E5F),
    .caution = C_HEX(0xB7791F),

    .primary_action_bg = C_HEX(0x2A2C30),
    .primary_action_fg = C_HEX(0xFFFFFF),
    .primary_action_border = C_HEX(0x2A2C30),
    .primary_action_hover_bg = C_HEX(0x1B1B1E),
    .primary_action_pressed_bg = C_HEX(0x4A4E54),
    .primary_action_disabled_bg = C_HEX(0xE3E3E5),
    .primary_action_disabled_fg = C_HEX(0x6D7279),

    .media_jpeg = C_HEX(0x3F434A),
    .media_raw = C_HEX(0x6B7178),
    .media_other = C_HEX(0x9AA0A6),
    .media_video = C_HEX(0xC7CCD1),

    .banner_success_bg = C_HEX(0xF2F5F2),
    .banner_success_icon_bg = C_HEX(0x287A40),
    .banner_success_icon_fg = C_HEX(0xFFFFFF),

    .shuttle_yellow = C_HEX(0xF0B800),
    .shuttle_card = C_HEX(0x14161B),
    .shuttle_tyre = C_HEX(0x0E1015),
    .shuttle_glass = C_HEX(0x12151C),
    .shuttle_rim = C_HEX(0xC9CED6),
};

const Theme *theme_get(ThemeMode mode)
{
    return (mode == MS_THEME_LIGHT) ? &light_theme : &dark_theme;
}

void theme_set_source(cairo_t *cr, UiColor color)
{
    cairo_set_source_rgba(cr, color.r, color.g, color.b, color.a);
}

void theme_set_source_alpha(cairo_t *cr, UiColor color, double alpha_multiplier)
{
    cairo_set_source_rgba(cr, color.r, color.g, color.b, color.a * alpha_multiplier);
}
