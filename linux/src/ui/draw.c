#include "draw.h"
#include "font.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

static void draw_fill_rect(cairo_t *cr, double x, double y, double w, double h, UiColor color)
{
    cairo_save(cr);
    theme_set_source(cr, color);
    cairo_rectangle(cr, x, y, w, h);
    cairo_fill(cr);
    cairo_restore(cr);
}

static void draw_hairline_h(cairo_t *cr, double x, double y, double w, UiColor color)
{
    draw_fill_rect(cr, x, y, w, 1.0, color);
}

static void draw_hairline_v(cairo_t *cr, double x, double y, double h, UiColor color)
{
    draw_fill_rect(cr, x, y, 1.0, h, color);
}

static void draw_box_border(cairo_t *cr, double x, double y, double w, double h, UiColor border_color)
{
    cairo_save(cr);
    theme_set_source(cr, border_color);
    cairo_set_line_width(cr, 1.0);
    cairo_rectangle(cr, x + 0.5, y + 0.5, w - 1.0, h - 1.0);
    cairo_stroke(cr);
    cairo_restore(cr);
}

static void draw_button(
    cairo_t *cr,
    double x, double y, double w, double h,
    const char *label,
    gboolean is_primary,
    gboolean is_destructive,
    gboolean is_disabled,
    gboolean is_hovered,
    const Theme *theme)
{
    UiColor bg, border, fg;

    if (is_disabled) {
        bg = theme->primary_action_disabled_bg;
        border = theme->hairline;
        fg = theme->primary_action_disabled_fg;
    } else if (is_destructive) {
        bg = theme->panel_bg;
        border = theme->speed_red;
        fg = theme->speed_red;
    } else if (is_primary) {
        bg = is_hovered ? theme->primary_action_hover_bg : theme->primary_action_bg;
        border = theme->primary_action_border;
        fg = theme->primary_action_fg;
    } else {
        bg = theme->panel_bg;
        border = theme->hairline;
        fg = theme->text_bright;
    }

    draw_fill_rect(cr, x, y, w, h, bg);
    draw_box_border(cr, x, y, w, h, border);

    if (is_hovered && !is_disabled) {
        draw_fill_rect(cr, x, y, w, h, (UiColor){ 1, 1, 1, 0.07 });
    }

    TextWeight weight = (is_primary || is_destructive) ? MS_WEIGHT_SEMIBOLD : MS_WEIGHT_MEDIUM;
    font_draw_text(cr, label, x + (w / 2.0), y + 9.0, 13.0, weight, fg, 0.0, w, MS_ALIGN_CENTER);
}

/* Vector Media Shuttle logo (SD card shuttle bus) */
static void draw_shuttle_mark(cairo_t *cr, double x, double y, double size, const Theme *theme)
{
    double design_w = 840.0;
    double scale = size / design_w;

    cairo_save(cr);
    cairo_translate(cr, x, y);
    cairo_scale(cr, scale, scale);

    /* Card silhouette with rounded chamfer */
    cairo_save(cr);
    theme_set_source(cr, theme->shuttle_card);
    cairo_set_line_width(cr, 40.0);
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);

    cairo_move_to(cr, 20, 20);
    cairo_line_to(cr, 690, 20);
    cairo_line_to(cr, 820, 150);
    cairo_line_to(cr, 820, 434);
    cairo_line_to(cr, 20, 434);
    cairo_close_path(cr);
    cairo_stroke_preserve(cr);
    cairo_fill(cr);
    cairo_restore(cr);

    /* Yellow shuttle body */
    cairo_save(cr);
    theme_set_source(cr, theme->shuttle_yellow);
    /* rounded rect x=46, y=46, w=512, h=362, r=54 */
    double bx = 46, by = 46, bw = 512, bh = 362, br = 54;
    cairo_new_sub_path(cr);
    cairo_arc(cr, bx + bw - br, by + br, br, -M_PI/2, 0);
    cairo_arc(cr, bx + bw - br, by + bh - br, br, 0, M_PI/2);
    cairo_arc(cr, bx + br, by + bh - br, br, M_PI/2, M_PI);
    cairo_arc(cr, bx + br, by + br, br, M_PI, 3*M_PI/2);
    cairo_close_path(cr);
    cairo_fill(cr);
    cairo_restore(cr);

    /* Windows */
    cairo_save(cr);
    theme_set_source(cr, theme->shuttle_glass);
    double win_x[] = { 80, 237, 394 };
    for (int i = 0; i < 3; i++) {
        double wx = win_x[i], wy = 80, ww = 130, wh = 128, wr = 14;
        cairo_new_sub_path(cr);
        cairo_arc(cr, wx + ww - wr, wy + wr, wr, -M_PI/2, 0);
        cairo_arc(cr, wx + ww - wr, wy + wh - wr, wr, 0, M_PI/2);
        cairo_arc(cr, wx + wr, wy + wh - wr, wr, M_PI/2, M_PI);
        cairo_arc(cr, wx + wr, wy + wr, wr, M_PI, 3*M_PI/2);
        cairo_close_path(cr);
        cairo_fill(cr);
    }

    /* Driver window */
    cairo_set_line_width(cr, 22.0);
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
    cairo_move_to(cr, 602, 80);
    cairo_line_to(cr, 692, 80);
    cairo_line_to(cr, 748, 136);
    cairo_line_to(cr, 748, 208);
    cairo_line_to(cr, 602, 208);
    cairo_close_path(cr);
    cairo_stroke_preserve(cr);
    cairo_fill(cr);

    /* Lower glass stripe */
    double sx = 80, sy = 278, sw = 444, sh = 20, sr = 10;
    cairo_new_sub_path(cr);
    cairo_arc(cr, sx + sw - sr, sy + sr, sr, -M_PI/2, 0);
    cairo_arc(cr, sx + sw - sr, sy + sh - sr, sr, 0, M_PI/2);
    cairo_arc(cr, sx + sr, sy + sh - sr, sr, M_PI/2, M_PI);
    cairo_arc(cr, sx + sr, sy + sr, sr, M_PI, 3*M_PI/2);
    cairo_close_path(cr);
    cairo_fill(cr);

    /* Wheels */
    double wheels[] = { 188, 686 };
    for (int i = 0; i < 2; i++) {
        theme_set_source(cr, theme->shuttle_tyre);
        cairo_arc(cr, wheels[i], 440, 84, 0, 2*M_PI);
        cairo_fill(cr);

        theme_set_source(cr, theme->shuttle_rim);
        cairo_arc(cr, wheels[i], 440, 42, 0, 2*M_PI);
        cairo_fill(cr);
    }
    cairo_restore(cr);

    cairo_restore(cr);
}

/* Gear icon for settings */
static void draw_gear_icon(cairo_t *cr, double cx, double cy, double r, UiColor color)
{
    cairo_save(cr);
    theme_set_source(cr, color);
    cairo_set_line_width(cr, 1.5);

    /* Outer gear teeth */
    int teeth = 8;
    for (int i = 0; i < teeth; i++) {
        double angle = i * (2 * M_PI / teeth);
        double x1 = cx + (r * 0.7) * cos(angle);
        double y1 = cy + (r * 0.7) * sin(angle);
        double x2 = cx + (r * 1.1) * cos(angle);
        double y2 = cy + (r * 1.1) * sin(angle);
        cairo_move_to(cr, x1, y1);
        cairo_line_to(cr, x2, y2);
        cairo_stroke(cr);
    }

    /* Outer circle ring */
    cairo_arc(cr, cx, cy, r * 0.8, 0, 2 * M_PI);
    cairo_stroke(cr);

    /* Inner hole */
    cairo_arc(cr, cx, cy, r * 0.35, 0, 2 * M_PI);
    cairo_stroke(cr);

    cairo_restore(cr);
}

/* Checkmark icon */
static void draw_checkmark(cairo_t *cr, double x, double y, double size, UiColor color)
{
    cairo_save(cr);
    theme_set_source(cr, color);
    cairo_set_line_width(cr, 2.0);
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_SQUARE);
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_MITER);

    cairo_move_to(cr, x + size * 0.2, y + size * 0.5);
    cairo_line_to(cr, x + size * 0.45, y + size * 0.75);
    cairo_line_to(cr, x + size * 0.85, y + size * 0.25);
    cairo_stroke(cr);
    cairo_restore(cr);
}

/* Close 'x' icon */
static void draw_cross(cairo_t *cr, double x, double y, double size, UiColor color)
{
    cairo_save(cr);
    theme_set_source(cr, color);
    cairo_set_line_width(cr, 1.5);
    cairo_move_to(cr, x, y);
    cairo_line_to(cr, x + size, y + size);
    cairo_move_to(cr, x + size, y);
    cairo_line_to(cr, x, y + size);
    cairo_stroke(cr);
    cairo_restore(cr);
}

/* SD Card Artwork */
static void draw_card_artwork(cairo_t *cr, double x, double y, double w, double h, const char *assets_dir, const Theme *theme)
{
    cairo_surface_t *img = NULL;
    const char *paths[] = {
        assets_dir ? g_build_filename(assets_dir, "ReferenceCard.png", NULL) : NULL,
        g_build_filename("linux", "assets", "ReferenceCard.png", NULL),
        g_build_filename("assets", "ReferenceCard.png", NULL),
        g_build_filename("windows", "src", "MediaShuttle", "Assets", "ReferenceCard.png", NULL)
    };

    for (guint i = 0; i < G_N_ELEMENTS(paths); i++) {
        if (paths[i] != NULL && g_file_test(paths[i], G_FILE_TEST_EXISTS)) {
            img = cairo_image_surface_create_from_png(paths[i]);
            if (cairo_surface_status(img) == CAIRO_STATUS_SUCCESS) {
                break;
            }
            cairo_surface_destroy(img);
            img = NULL;
        }
    }

    for (guint i = 0; i < G_N_ELEMENTS(paths); i++) {
        g_free((char *) paths[i]);
    }

    if (img != NULL) {
        cairo_save(cr);
        double iw = cairo_image_surface_get_width(img);
        double ih = cairo_image_surface_get_height(img);
        cairo_translate(cr, x, y);
        cairo_scale(cr, w / iw, h / ih);
        cairo_set_source_surface(cr, img, 0, 0);
        cairo_paint(cr);
        cairo_restore(cr);
        cairo_surface_destroy(img);
        return;
    }

    /* Fallback vector SD card */
    cairo_save(cr);
    theme_set_source(cr, theme->panel_bg);
    cairo_move_to(cr, x, y);
    cairo_line_to(cr, x + w - 10, y);
    cairo_line_to(cr, x + w, y + 10);
    cairo_line_to(cr, x + w, y + h);
    cairo_line_to(cr, x, y + h);
    cairo_close_path(cr);
    cairo_fill_preserve(cr);
    theme_set_source(cr, theme->hairline);
    cairo_set_line_width(cr, 1.0);
    cairo_stroke(cr);

    /* Gold contact pins */
    theme_set_source(cr, (UiColor){ 0.85, 0.70, 0.20, 1.0 });
    for (int i = 0; i < 7; i++) {
        cairo_rectangle(cr, x + 6 + (i * 5), y + 6, 3, 10);
        cairo_fill(cr);
    }
    cairo_restore(cr);
}

/* Square toggle switch matching design-qa.md */
static void draw_square_toggle(cairo_t *cr, double x, double y, gboolean is_on, const Theme *theme)
{
    double track_w = 40.0;
    double track_h = 20.0;
    double knob_size = 14.0;
    double knob_margin = 3.0;

    UiColor track_color = is_on ? theme->speed_red : theme->panel_bg;
    UiColor knob_color = is_on ? (UiColor){ 1, 1, 1, 1 } : theme->text_muted;

    /* Square track */
    draw_fill_rect(cr, x, y, track_w, track_h, track_color);
    draw_box_border(cr, x, y, track_w, track_h, theme->hairline);

    /* Square knob */
    double knob_x = is_on ? (x + track_w - knob_size - knob_margin) : (x + knob_margin);
    double knob_y = y + knob_margin;
    draw_fill_rect(cr, knob_x, knob_y, knob_size, knob_size, knob_color);
}

void draw_view(cairo_t *cr, const UiState *state, const char *assets_dir)
{
    if (state == NULL) return;

    const Theme *theme = theme_get(state->theme_mode);
    double W = state->window_width;
    double H = state->window_height;

    /* 1. Main Background */
    draw_fill_rect(cr, 0, 0, W, H, theme->content_bg);

    /* 2. Header Bar (0, 0, W, 48) */
    draw_fill_rect(cr, 0, 0, W, 48, theme->chrome_bg);
    draw_hairline_h(cr, 0, 47, W, theme->hairline);

    /* Header Logo */
    draw_shuttle_mark(cr, 20.0, 16.0, 24.0, theme);

    /* Header App Name */
    font_draw_text(cr, "MEDIA SHUTTLE", 50.0, 16.0, 13.0, MS_WEIGHT_SEMIBOLD, theme->text_primary, 0.110, -1, MS_ALIGN_LEFT);

    /* Status Pill (x=180, y=14, h=20) */
    double pill_x = 180.0;
    double pill_y = 14.0;
    double text_w = 0, text_h = 0;
    font_measure_text(cr, state->top_status_text, 12.0, MS_WEIGHT_REGULAR, 0.074, &text_w, &text_h);
    double pill_w = text_w + 22.0;
    double pill_h = 20.0;

    draw_fill_rect(cr, pill_x, pill_y, pill_w, pill_h, theme->panel_bg);
    draw_box_border(cr, pill_x, pill_y, pill_w, pill_h, theme->hairline);

    /* Status Dot (5x5) */
    UiColor dot_color = theme->text_muted;
    if (state->status_tone == 1) dot_color = theme->verified;
    else if (state->status_tone == 2) dot_color = theme->caution;
    else if (state->status_tone == 3) dot_color = theme->speed_red;
    draw_fill_rect(cr, pill_x + 7.0, pill_y + 7.5, 5.0, 5.0, dot_color);

    /* Status Text */
    font_draw_text(cr, state->top_status_text, pill_x + 18.0, pill_y + 3.0, 12.0, MS_WEIGHT_REGULAR, theme->text_secondary, 0.074, -1, MS_ALIGN_LEFT);

    /* Settings Button (right side of header, x=714 in 896 width) */
    double settings_x = (W >= 880.0) ? (W - 182.0) : (W - 38.0);
    double settings_y = 13.0;
    draw_gear_icon(cr, settings_x + 11.0, settings_y + 11.0, 7.0, theme->text_muted);

    /* 3. Sidebar (Source Panel) (0, 48, 280, H - 48) */
    double side_w = 280.0;
    draw_fill_rect(cr, 0, 48, side_w, H - 48, theme->sidebar_bg);
    draw_hairline_v(cr, side_w, 48, H - 48, theme->hairline);

    /* Section: SOURCE */
    font_draw_text(cr, "SOURCE", 18.0, 66.0, 11.0, MS_WEIGHT_MEDIUM, theme->text_label, 0.110, -1, MS_ALIGN_LEFT);

    /* Card Icon (48x64) at (18, 94) */
    draw_card_artwork(cr, 18.0, 94.0, 48.0, 64.0, assets_dir, theme);

    /* Card Details */
    font_draw_text(cr, state->card_label, 78.0, 94.0, 16.0, MS_WEIGHT_SEMIBOLD, theme->text_primary, 0.0, side_w - 90.0, MS_ALIGN_LEFT);
    font_draw_text(cr, state->card_detail, 78.0, 118.0, 12.0, MS_WEIGHT_REGULAR, theme->text_muted, 0.0, side_w - 90.0, MS_ALIGN_LEFT);
    font_draw_text(cr, state->card_stats, 78.0, 138.0, 12.0, MS_WEIGHT_REGULAR, theme->text_muted, 0.0, side_w - 90.0, MS_ALIGN_LEFT);

    /* "Open card folder…" Button at (18, 180, 244, 34) */
    draw_button(cr, 18.0, 180.0, side_w - 36.0, 34.0, "Open card folder…", FALSE, FALSE, FALSE, state->hovered_id == UI_ID_OPEN_CARD_BTN, theme);

    /* Hairline Separator at y=229 */
    draw_hairline_h(cr, 18.0, 229.0, side_w - 36.0, theme->hairline);

    /* Section: CARD CONTENTS at y=248 */
    font_draw_text(cr, "CARD CONTENTS", 18.0, 248.0, 11.0, MS_WEIGHT_MEDIUM, theme->text_label, 0.110, -1, MS_ALIGN_LEFT);

    /* Segmented Bar at y=270, height=6 */
    double bar_x = 18.0;
    double bar_y = 270.0;
    double bar_w = side_w - 36.0;
    double bar_h = 6.0;
    draw_fill_rect(cr, bar_x, bar_y, bar_w, bar_h, theme->hairline_soft);

    int total_counts = state->count_jpeg + state->count_raw + state->count_other + state->count_video;
    if (total_counts > 0) {
        double seg_jpeg_w = (state->count_jpeg / (double)total_counts) * bar_w;
        double seg_raw_w = (state->count_raw / (double)total_counts) * bar_w;
        double cur_bx = bar_x;
        if (seg_jpeg_w > 0) {
            draw_fill_rect(cr, cur_bx, bar_y, seg_jpeg_w - 1.0, bar_h, theme->media_jpeg);
            cur_bx += seg_jpeg_w;
        }
        if (seg_raw_w > 0) {
            draw_fill_rect(cr, cur_bx, bar_y, seg_raw_w - 1.0, bar_h, theme->media_raw);
            cur_bx += seg_raw_w;
        }
    }

    /* Category Count Rows at y=295, 317, 339, 361 */
    struct {
        const char *name;
        int count;
        UiColor color;
        double y;
    } cats[] = {
        { "JPEG", state->count_jpeg, theme->media_jpeg, 295.0 },
        { "RAW", state->count_raw, theme->media_raw, 317.0 },
        { "OTHER", state->count_other, theme->media_other, 339.0 },
        { "VIDEO", state->count_video, theme->media_video, 361.0 }
    };

    for (int i = 0; i < 4; i++) {
        draw_fill_rect(cr, 18.0, cats[i].y + 3.0, 7.0, 7.0, cats[i].color);
        font_draw_text(cr, cats[i].name, 32.0, cats[i].y, 12.0, MS_WEIGHT_REGULAR, theme->text_secondary, 0.0, -1, MS_ALIGN_LEFT);

        char count_str[32];
        if (cats[i].count > 0) {
            snprintf(count_str, sizeof(count_str), "%d", cats[i].count);
        } else {
            snprintf(count_str, sizeof(count_str), "—");
        }
        font_draw_text(cr, count_str, bar_x + bar_w, cats[i].y, 12.0, MS_WEIGHT_SEMIBOLD, theme->text_bright, 0.0, -1, MS_ALIGN_RIGHT);
    }

    /* Hairline Separator at y=391 */
    draw_hairline_h(cr, 18.0, 391.0, side_w - 36.0, theme->hairline);

    /* Section: DESTINATION at y=409 */
    font_draw_text(cr, "DESTINATION", 18.0, 409.0, 11.0, MS_WEIGHT_MEDIUM, theme->text_label, 0.110, -1, MS_ALIGN_LEFT);
    font_draw_text(cr, state->destination_path, 18.0, 432.0, 13.0, MS_WEIGHT_MEDIUM, theme->text_bright, 0.0, side_w - 36.0, MS_ALIGN_LEFT);

    /* Change / Open Buttons at y=457 */
    double half_btn_w = (side_w - 36.0 - 6.0) / 2.0;
    draw_button(cr, 18.0, 457.0, half_btn_w, 34.0, "Change", FALSE, FALSE, FALSE, state->hovered_id == UI_ID_CHANGE_DEST_BTN, theme);
    draw_button(cr, 18.0 + half_btn_w + 6.0, 457.0, half_btn_w, 34.0, "Open", FALSE, FALSE, FALSE, state->hovered_id == UI_ID_OPEN_DEST_BTN, theme);

    /* Folder Structure Preview at y=504 */
    const char *folders[] = { "Photos/JPEGs", "Photos/RAWs", "Photos/Other", "Videos" };
    for (int i = 0; i < 4; i++) {
        font_draw_text(cr, folders[i], 18.0, 504.0 + (i * 18.0), 12.0, MS_WEIGHT_REGULAR, theme->text_muted, 0.0, -1, MS_ALIGN_LEFT);
    }

    /* 4. Operations Panel (281, 48, W - 281, H - 48) */
    double op_x = 281.0;
    double op_w = W - op_x;
    double cur_y = 66.0;

    /* Status Banner at y=66..116 (h=50) */
    if (state->banner_visible) {
        double banner_x = op_x + 20.0;
        double banner_w = op_w - 40.0;
        double banner_h = 50.0;

        draw_fill_rect(cr, banner_x, cur_y, banner_w, banner_h, theme->banner_success_bg);
        draw_box_border(cr, banner_x, cur_y, banner_w, banner_h, theme->hairline);

        /* Green accent vertical strip */
        draw_fill_rect(cr, banner_x, cur_y, 3.0, banner_h, theme->verified);

        /* Icon box (14x14) */
        draw_fill_rect(cr, banner_x + 12.0, cur_y + 11.0, 14.0, 14.0, theme->banner_success_icon_bg);
        draw_checkmark(cr, banner_x + 12.0, cur_y + 11.0, 14.0, theme->banner_success_icon_fg);

        /* Title & Message */
        font_draw_text(cr, state->banner_title, banner_x + 35.0, cur_y + 8.0, 14.5, MS_WEIGHT_SEMIBOLD, theme->text_primary, 0.0, banner_w - 70.0, MS_ALIGN_LEFT);
        font_draw_text(cr, state->banner_message, banner_x + 35.0, cur_y + 28.0, 12.0, MS_WEIGHT_REGULAR, theme->text_secondary, 0.0, banner_w - 70.0, MS_ALIGN_LEFT);

        /* Dismiss 'x' button */
        draw_cross(cr, banner_x + banner_w - 20.0, cur_y + 19.0, 10.0, theme->text_muted);

        cur_y = 146.0; /* align with measured y=146 */
    } else {
        cur_y = 66.0;
    }

    /* "THIS SESSION" Box (y=146, h=248) */
    double sbox_x = op_x + 20.0;
    double sbox_w = op_w - 40.0;
    double sbox_h = 248.0;

    draw_fill_rect(cr, sbox_x, cur_y, sbox_w, sbox_h, theme->panel_bg);
    draw_box_border(cr, sbox_x, cur_y, sbox_w, sbox_h, theme->hairline);

    /* Section Header: padding 9, 8 */
    font_draw_text(cr, "THIS SESSION", sbox_x + 9.0, cur_y + 8.0, 11.0, MS_WEIGHT_MEDIUM, theme->text_label, 0.110, -1, MS_ALIGN_LEFT);
    font_draw_text(cr, state->phase_text, sbox_x + sbox_w - 55.0, cur_y + 8.0, 11.0, MS_WEIGHT_MEDIUM, theme->text_label, 0.110, -1, MS_ALIGN_RIGHT);
    font_draw_text(cr, state->percent_text, sbox_x + sbox_w - 9.0, cur_y + 7.0, 12.0, MS_WEIGHT_SEMIBOLD, theme->text_primary, 0.0, -1, MS_ALIGN_RIGHT);

    /* Segmented progress bar at y=cur_y+29..33 (h=4) */
    double pbar_y = cur_y + 29.0;
    double pbar_w = sbox_w - 18.0;
    draw_fill_rect(cr, sbox_x + 9.0, pbar_y, pbar_w, 4.0, theme->hairline_soft);

    int num_segments = 60;
    double seg_step = pbar_w / num_segments;
    int filled_segments = (int) (state->progress_fraction * num_segments);
    for (int i = 0; i < filled_segments; i++) {
        draw_fill_rect(cr, sbox_x + 9.0 + (i * seg_step), pbar_y, seg_step - 1.0, 4.0, theme->verified);
    }

    /* Hairline between header and metrics at y=187 */
    double metrics_y = cur_y + 41.0;
    draw_hairline_h(cr, sbox_x, metrics_y, sbox_w, theme->hairline);

    /* Metrics Grid: 5 equal columns, h=158 */
    double col_w = sbox_w / 5.0;
    double metrics_h = 158.0;

    struct {
        const char *label;
        const char *val;
        const char *sub;
    } metrics[] = {
        { "COPIED", state->stat_copied, state->stat_copied_sub },
        { "ALREADY SAFE", state->stat_safe, state->stat_safe_sub },
        { "PROCESSED", state->stat_processed, state->stat_processed_sub },
        { "THROUGHPUT", state->stat_throughput, state->stat_throughput_sub },
        { "ELAPSED", state->stat_elapsed, state->stat_elapsed_sub }
    };

    for (int i = 0; i < 5; i++) {
        double cx = sbox_x + (i * col_w);
        if (i > 0) {
            draw_hairline_v(cr, cx, metrics_y, metrics_h, theme->hairline);
        }
        font_draw_text(cr, metrics[i].label, cx + 9.0, metrics_y + 10.0, 11.0, MS_WEIGHT_MEDIUM, theme->text_label, 0.110, col_w - 18.0, MS_ALIGN_LEFT);
        font_draw_text(cr, metrics[i].val, cx + 9.0, metrics_y + 98.0, 20.0, MS_WEIGHT_SEMIBOLD, theme->text_primary, 0.0, col_w - 18.0, MS_ALIGN_LEFT);
        font_draw_text(cr, metrics[i].sub, cx + 9.0, metrics_y + 130.0, 12.0, MS_WEIGHT_REGULAR, theme->text_muted, 0.0, col_w - 18.0, MS_ALIGN_LEFT);
    }

    /* Session Footer Row at y=345..394 (h=49) */
    double footer_y = metrics_y + metrics_h;
    double footer_h = sbox_h - (footer_y - cur_y);
    draw_fill_rect(cr, sbox_x, footer_y, sbox_w, footer_h, theme->panel_footer_bg);
    draw_hairline_h(cr, sbox_x, footer_y, sbox_w, theme->hairline);

    font_draw_text(cr, state->current_file_text, sbox_x + 9.0, footer_y + 16.0, 12.0, MS_WEIGHT_REGULAR, theme->text_muted, 0.0, sbox_w - 230.0, MS_ALIGN_LEFT);

    /* Footer Buttons at footer_y + 8 (h=34) */
    draw_button(cr, sbox_x + sbox_w - 215.0, footer_y + 8.0, 75.0, 34.0, "Report", FALSE, FALSE, !state->report_enabled, state->hovered_id == UI_ID_REPORT_BTN, theme);
    draw_button(cr, sbox_x + sbox_w - 134.0, footer_y + 8.0, 125.0, 34.0, state->primary_action_text, TRUE, FALSE, FALSE, state->hovered_id == UI_ID_PRIMARY_ACTION_BTN, theme);

    /* "ACTIVITY" Section at y=412 */
    double act_header_y = 412.0;
    if (state->show_activity) {
        font_draw_text(cr, "ACTIVITY", sbox_x, act_header_y, 11.0, MS_WEIGHT_MEDIUM, theme->text_label, 0.110, -1, MS_ALIGN_LEFT);
        draw_hairline_h(cr, sbox_x + 72.0, act_header_y + 7.0, sbox_w - 72.0, theme->hairline);

        double act_y = act_header_y + 22.0;
        if (state->activity_log != NULL) {
            for (guint i = 0; i < state->activity_log->len && i < 4; i++) {
                const char *entry = g_ptr_array_index(state->activity_log, i);
                font_draw_text(cr, entry, sbox_x, act_y + (i * 26.0), 12.5, MS_WEIGHT_REGULAR, theme->text_secondary, 0.0, sbox_w, MS_ALIGN_LEFT);
                draw_hairline_h(cr, sbox_x, act_y + (i * 26.0) + 21.0, sbox_w, theme->hairline_soft);
            }
        }
    }

    /* "Erase Card" Box anchored at y=696..800 (h=104) */
    double ebox_x = sbox_x;
    double ebox_w = sbox_w;
    double ebox_y = (H >= 820.0) ? 696.0 : (H - 110.0);
    double ebox_h = 104.0;

    draw_fill_rect(cr, ebox_x, ebox_y, ebox_w, ebox_h, theme->panel_bg);
    draw_box_border(cr, ebox_x, ebox_y, ebox_w, ebox_h, theme->hairline);

    /* Title + Badge */
    font_draw_text(cr, "Erase card", ebox_x + 9.0, ebox_y + 14.0, 14.5, MS_WEIGHT_SEMIBOLD, theme->text_primary, 0.0, -1, MS_ALIGN_LEFT);

    const char *badge_text = state->erase_unlocked ? "UNLOCKED" : "LOCKED";
    UiColor badge_color = state->erase_unlocked ? theme->speed_red : theme->text_muted;
    double badge_x = ebox_x + 98.0;
    double badge_y = ebox_y + 13.0;
    draw_box_border(cr, badge_x, badge_y, 72.0, 20.0, badge_color);
    font_draw_text(cr, badge_text, badge_x + 36.0, badge_y + 3.0, 11.0, MS_WEIGHT_MEDIUM, badge_color, 0.110, -1, MS_ALIGN_CENTER);

    /* Description */
    font_draw_text(cr, state->erase_description, ebox_x + 9.0, ebox_y + 46.0, 12.0, MS_WEIGHT_REGULAR, theme->text_muted, 0.0, ebox_w - 240.0, MS_ALIGN_LEFT);

    /* Erase Button at y = ebox_y + 55, h=34 */
    draw_button(cr, ebox_x + ebox_w - 224.0, ebox_y + 55.0, 215.0, 34.0, "Erase everything on card", FALSE, TRUE, !state->erase_unlocked, state->hovered_id == UI_ID_ERASE_BTN, theme);

    /* 5. Settings Flyout Overlay (if open) */
    if (state->settings_open) {
        double flyout_w = 340.0;
        double flyout_h = 360.0;
        double fx = W - flyout_w - 14.0;
        double fy = 52.0;

        /* Flyout drop shadow and box */
        draw_fill_rect(cr, fx + 2.0, fy + 2.0, flyout_w, flyout_h, (UiColor){ 0, 0, 0, 0.4 });
        draw_fill_rect(cr, fx, fy, flyout_w, flyout_h, theme->panel_bg);
        draw_box_border(cr, fx, fy, flyout_w, flyout_h, theme->hairline);

        font_draw_text(cr, "Settings", fx + 18.0, fy + 16.0, 16.0, MS_WEIGHT_SEMIBOLD, theme->text_primary, 0.0, -1, MS_ALIGN_LEFT);
        font_draw_text(cr, "Transfer behavior and appearance", fx + 18.0, fy + 38.0, 11.5, MS_WEIGHT_REGULAR, theme->text_muted, 0.0, -1, MS_ALIGN_LEFT);

        font_draw_text(cr, "APPEARANCE", fx + 18.0, fy + 62.0, 10.5, MS_WEIGHT_MEDIUM, theme->text_label, 0.110, -1, MS_ALIGN_LEFT);

        /* Theme Combobox */
        double combo_y = fy + 78.0;
        draw_fill_rect(cr, fx + 18.0, combo_y, flyout_w - 36.0, 32.0, theme->chrome_bg);
        draw_box_border(cr, fx + 18.0, combo_y, flyout_w - 36.0, 32.0, theme->hairline);
        char theme_str[64];
        snprintf(theme_str, sizeof(theme_str), "%s", state->settings_theme ? state->settings_theme : "Dark");
        font_draw_text(cr, theme_str, fx + 28.0, combo_y + 8.0, 12.0, MS_WEIGHT_REGULAR, theme->text_primary, 0.0, -1, MS_ALIGN_LEFT);

        draw_hairline_h(cr, fx + 18.0, fy + 120.0, flyout_w - 36.0, theme->hairline);

        /* 5 Toggles */
        struct {
            const char *title;
            gboolean on;
            double y;
        } toggles[] = {
            { "Automatic transfer", state->settings_auto_transfer, fy + 132.0 },
            { "Date folders", state->settings_group_by_date, fy + 172.0 },
            { "Completion notifications", state->settings_show_notifications, fy + 212.0 },
            { "Activity log", state->settings_show_activity, fy + 252.0 },
            { "Start with system", state->settings_start_with_system, fy + 292.0 }
        };

        for (int i = 0; i < 5; i++) {
            font_draw_text(cr, toggles[i].title, fx + 18.0, toggles[i].y + 4.0, 12.5, MS_WEIGHT_REGULAR, theme->text_bright, 0.0, -1, MS_ALIGN_LEFT);
            draw_square_toggle(cr, fx + flyout_w - 58.0, toggles[i].y, toggles[i].on, theme);
        }
    }

    /* 6. Erase Confirmation Modal Dialog (if open) */
    if (state->confirm_erase_open) {
        /* Backdrop */
        draw_fill_rect(cr, 0, 0, W, H, (UiColor){ 0, 0, 0, 0.65 });

        double modal_w = 420.0;
        double modal_h = 260.0;
        double mx = (W - modal_w) / 2.0;
        double my = (H - modal_h) / 2.0;

        draw_fill_rect(cr, mx, my, modal_w, modal_h, theme->panel_bg);
        draw_box_border(cr, mx, my, modal_w, modal_h, theme->hairline);

        font_draw_text(cr, "Erase camera card", mx + 20.0, my + 18.0, 16.0, MS_WEIGHT_SEMIBOLD, theme->text_primary, 0.0, -1, MS_ALIGN_LEFT);
        font_draw_text(cr, "Type ERASE EVERYTHING to confirm deleting all files.", mx + 20.0, my + 44.0, 12.0, MS_WEIGHT_REGULAR, theme->text_muted, 0.0, modal_w - 40.0, MS_ALIGN_LEFT);

        /* Text Input Box */
        double input_y = my + 80.0;
        draw_fill_rect(cr, mx + 20.0, input_y, modal_w - 40.0, 34.0, theme->chrome_bg);
        draw_box_border(cr, mx + 20.0, input_y, modal_w - 40.0, 34.0, theme->hairline);
        const char *phrase = state->confirm_typed_phrase ? state->confirm_typed_phrase : "";
        font_draw_text(cr, phrase, mx + 28.0, input_y + 9.0, 13.0, MS_WEIGHT_REGULAR, theme->text_primary, 0.0, -1, MS_ALIGN_LEFT);

        /* Checkbox */
        double check_y = my + 130.0;
        draw_fill_rect(cr, mx + 20.0, check_y, 16.0, 16.0, theme->chrome_bg);
        draw_box_border(cr, mx + 20.0, check_y, 16.0, 16.0, theme->hairline);
        if (state->confirm_checked) {
            draw_checkmark(cr, mx + 21.0, check_y + 1.0, 14.0, theme->speed_red);
        }
        font_draw_text(cr, "I understand all files will be permanently deleted", mx + 44.0, check_y + 1.0, 11.5, MS_WEIGHT_REGULAR, theme->text_bright, 0.0, -1, MS_ALIGN_LEFT);

        /* Dialog Buttons */
        double dbtn_y = my + modal_h - 48.0;
        gboolean can_proceed = (strcmp(phrase, "ERASE EVERYTHING") == 0) && state->confirm_checked;

        draw_button(cr, mx + modal_w - 220.0, dbtn_y, 85.0, 34.0, "Cancel", FALSE, FALSE, FALSE, state->hovered_id == UI_ID_CONFIRM_CANCEL_BTN, theme);
        draw_button(cr, mx + modal_w - 125.0, dbtn_y, 105.0, 34.0, "Erase card", FALSE, TRUE, !can_proceed, state->hovered_id == UI_ID_CONFIRM_ERASE_BTN, theme);
    }
}
