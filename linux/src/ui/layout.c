#include "layout.h"
#include <stdlib.h>
#include <string.h>

UiState *ui_state_new_empty(void)
{
    UiState *s = g_new0(UiState, 1);
    s->window_width = 896.0;
    s->window_height = 832.0;
    s->theme_mode = MS_THEME_DARK;

    s->top_status_text = g_strdup("WAITING FOR MEDIA");
    s->status_tone = 0;
    s->card_connected = FALSE;
    s->card_label = g_strdup("No card connected");
    s->card_detail = g_strdup("Choose a source or insert a camera card.");
    s->card_stats = g_strdup("—");
    s->destination_path = g_strdup("~/Desktop/Camera");
    s->phase_text = g_strdup("STANDBY");
    s->percent_text = g_strdup("0%");
    s->stat_copied = g_strdup("—");
    s->stat_copied_sub = g_strdup("files");
    s->stat_safe = g_strdup("—");
    s->stat_safe_sub = g_strdup("re-verified");
    s->stat_processed = g_strdup("—");
    s->stat_processed_sub = g_strdup("idle");
    s->stat_throughput = g_strdup("—");
    s->stat_throughput_sub = g_strdup("idle");
    s->stat_elapsed = g_strdup("0:00");
    s->stat_elapsed_sub = g_strdup("min:sec");
    s->current_file_text = g_strdup("Waiting for camera media");
    s->primary_action_text = g_strdup("Scan for media");
    s->show_activity = TRUE;
    s->activity_log = g_ptr_array_new_with_free_func(g_free);
    s->erase_description = g_strdup("Locked until every remaining camera file has a verified destination copy.");

    s->settings_theme = g_strdup("Dark");
    s->settings_show_notifications = TRUE;
    s->settings_show_activity = TRUE;

    s->confirm_typed_phrase = g_strdup("");

    return s;
}

UiState *ui_state_new_preview(void)
{
    UiState *s = ui_state_new_empty();

    g_free(s->top_status_text);
    s->top_status_text = g_strdup("LEXAR · TRANSFER VERIFIED");
    s->status_tone = 1;

    s->card_connected = TRUE;
    g_free(s->card_label);
    s->card_label = g_strdup("LEXAR");
    g_free(s->card_detail);
    s->card_detail = g_strdup("/Volumes/LEXAR · Removable media");
    g_free(s->card_stats);
    s->card_stats = g_strdup("457 assets · 10.13 GB");
    s->count_jpeg = 418;
    s->count_raw = 39;
    s->count_other = 0;
    s->count_video = 0;

    s->banner_visible = TRUE;
    s->banner_title = g_strdup("Transfer verified — 457 files safe in the destination");
    s->banner_message = g_strdup("SHA-256 matched on every remaining camera file");
    s->banner_tone = 1;

    g_free(s->phase_text);
    s->phase_text = g_strdup("VERIFIED");
    g_free(s->percent_text);
    s->percent_text = g_strdup("100%");
    s->progress_fraction = 1.0;

    g_free(s->stat_copied);
    s->stat_copied = g_strdup("442");
    g_free(s->stat_safe);
    s->stat_safe = g_strdup("15");
    g_free(s->stat_processed);
    s->stat_processed = g_strdup("10.13 GB");
    g_free(s->stat_throughput);
    s->stat_throughput = g_strdup("78.7");
    g_free(s->stat_throughput_sub);
    s->stat_throughput_sub = g_strdup("MB/s avg");
    g_free(s->stat_elapsed);
    s->stat_elapsed = g_strdup("2:08");

    g_free(s->current_file_text);
    s->current_file_text = g_strdup("LAST · /Volumes/LEXAR/DCIM/100MSDCF/DSC00381.JPG → Photos/JPEGs");

    g_free(s->primary_action_text);
    s->primary_action_text = g_strdup("Transfer again");

    g_ptr_array_add(s->activity_log, g_strdup("3:38:24 PM  Verification complete — 457 files match by SHA-256."));
    g_ptr_array_add(s->activity_log, g_strdup("3:36:25 PM  Transfer started from /Volumes/LEXAR."));

    s->erase_unlocked = TRUE;
    g_free(s->erase_description);
    s->erase_description = g_strdup("Every remaining file on /Volumes/LEXAR has a verified copy · typed confirmation required");

    return s;
}

void ui_state_free(UiState *s)
{
    if (s == NULL) return;
    g_free(s->top_status_text);
    g_free(s->card_label);
    g_free(s->card_detail);
    g_free(s->card_stats);
    g_free(s->destination_path);
    g_free(s->banner_title);
    g_free(s->banner_message);
    g_free(s->phase_text);
    g_free(s->percent_text);
    g_free(s->stat_copied);
    g_free(s->stat_copied_sub);
    g_free(s->stat_safe);
    g_free(s->stat_safe_sub);
    g_free(s->stat_processed);
    g_free(s->stat_processed_sub);
    g_free(s->stat_throughput);
    g_free(s->stat_throughput_sub);
    g_free(s->stat_elapsed);
    g_free(s->stat_elapsed_sub);
    g_free(s->current_file_text);
    g_free(s->primary_action_text);
    if (s->activity_log) g_ptr_array_free(s->activity_log, TRUE);
    g_free(s->erase_description);
    g_free(s->confirm_typed_phrase);
    g_free(s->settings_theme);
    g_free(s);
}

static gboolean point_in_rect(double px, double py, double rx, double ry, double rw, double rh)
{
    return px >= rx && px <= rx + rw && py >= ry && py <= ry + rh;
}

int ui_layout_hit_test(const UiState *state, double px, double py, UiRect *out_rect)
{
    if (state == NULL) return UI_ID_NONE;

    /* If confirmation modal is open, modal captures clicks */
    if (state->confirm_erase_open) {
        double modal_w = 420;
        double modal_h = 260;
        double mx = (state->window_width - modal_w) / 2.0;
        double my = (state->window_height - modal_h) / 2.0;

        /* Cancel button */
        double btn_y = my + modal_h - 48;
        if (point_in_rect(px, py, mx + modal_w - 240, btn_y, 90, 34)) {
            if (out_rect) *out_rect = (UiRect){ mx + modal_w - 240, btn_y, 90, 34 };
            return UI_ID_CONFIRM_CANCEL_BTN;
        }
        /* Erase button */
        if (point_in_rect(px, py, mx + modal_w - 140, btn_y, 120, 34)) {
            if (out_rect) *out_rect = (UiRect){ mx + modal_w - 140, btn_y, 120, 34 };
            return UI_ID_CONFIRM_ERASE_BTN;
        }
        /* Checkbox */
        if (point_in_rect(px, py, mx + 20, my + 160, 20, 20)) {
            if (out_rect) *out_rect = (UiRect){ mx + 20, my + 160, 20, 20 };
            return UI_ID_CONFIRM_CHECKBOX;
        }
        /* Textbox */
        if (point_in_rect(px, py, mx + 20, my + 115, modal_w - 40, 34)) {
            if (out_rect) *out_rect = (UiRect){ mx + 20, my + 115, modal_w - 40, 34 };
            return UI_ID_CONFIRM_TEXTBOX;
        }
        return UI_ID_NONE;
    }

    /* If settings flyout is open */
    if (state->settings_open) {
        double flyout_w = 340;
        double fx = state->window_width - flyout_w - 12;
        double fy = 52;

        /* Settings toggle 1: auto transfer */
        if (point_in_rect(px, py, fx + flyout_w - 60, fy + 125, 40, 22)) {
            if (out_rect) *out_rect = (UiRect){ fx + flyout_w - 60, fy + 125, 40, 22 };
            return UI_ID_SETTINGS_TOGGLE_AUTO;
        }
        /* Settings toggle 2: date folders */
        if (point_in_rect(px, py, fx + flyout_w - 60, fy + 165, 40, 22)) {
            if (out_rect) *out_rect = (UiRect){ fx + flyout_w - 60, fy + 165, 40, 22 };
            return UI_ID_SETTINGS_TOGGLE_DATE;
        }
        /* Settings toggle 3: notifications */
        if (point_in_rect(px, py, fx + flyout_w - 60, fy + 205, 40, 22)) {
            if (out_rect) *out_rect = (UiRect){ fx + flyout_w - 60, fy + 205, 40, 22 };
            return UI_ID_SETTINGS_TOGGLE_NOTIF;
        }
        /* Settings toggle 4: activity */
        if (point_in_rect(px, py, fx + flyout_w - 60, fy + 245, 40, 22)) {
            if (out_rect) *out_rect = (UiRect){ fx + flyout_w - 60, fy + 245, 40, 22 };
            return UI_ID_SETTINGS_TOGGLE_ACTIVITY;
        }
        /* Settings toggle 5: startup */
        if (point_in_rect(px, py, fx + flyout_w - 60, fy + 285, 40, 22)) {
            if (out_rect) *out_rect = (UiRect){ fx + flyout_w - 60, fy + 285, 40, 22 };
            return UI_ID_SETTINGS_TOGGLE_STARTUP;
        }
        /* Settings Theme dropdown */
        if (point_in_rect(px, py, fx + 18, fy + 78, flyout_w - 36, 32)) {
            if (out_rect) *out_rect = (UiRect){ fx + 18, fy + 78, flyout_w - 36, 32 };
            return UI_ID_SETTINGS_THEME_COMBO;
        }
    }

    /* Header: settings button */
    double settings_x = (state->window_width >= 880.0) ? (state->window_width - 182.0) : (state->window_width - 38.0);
    if (point_in_rect(px, py, settings_x, 13, 24, 24)) {
        if (out_rect) *out_rect = (UiRect){ settings_x, 13, 24, 24 };
        return UI_ID_SETTINGS_BTN;
    }

    /* Sidebar buttons */
    /* Open card folder button: x=18, y=180, w=244, h=34 */
    if (point_in_rect(px, py, 18, 180, 244, 34)) {
        if (out_rect) *out_rect = (UiRect){ 18, 180, 244, 34 };
        return UI_ID_OPEN_CARD_BTN;
    }
    /* Destination Change button: x=18, y=457, w=119, h=34 */
    if (point_in_rect(px, py, 18, 457, 119, 34)) {
        if (out_rect) *out_rect = (UiRect){ 18, 457, 119, 34 };
        return UI_ID_CHANGE_DEST_BTN;
    }
    /* Destination Open button: x=143, y=457, w=119, h=34 */
    if (point_in_rect(px, py, 143, 457, 119, 34)) {
        if (out_rect) *out_rect = (UiRect){ 143, 457, 119, 34 };
        return UI_ID_OPEN_DEST_BTN;
    }

    /* Operations panel bounds */
    double op_x = 281.0;
    double op_w = state->window_width - op_x;

    /* Banner dismiss button */
    if (state->banner_visible) {
        double banner_x = op_x + 20.0;
        double banner_w = op_w - 40.0;
        double dismiss_x = banner_x + banner_w - 28.0;
        double dismiss_y = 66.0 + 11.0;
        if (point_in_rect(px, py, dismiss_x, dismiss_y, 24, 24)) {
            if (out_rect) *out_rect = (UiRect){ dismiss_x, dismiss_y, 24, 24 };
            return UI_ID_BANNER_DISMISS_BTN;
        }
    }

    /* THIS SESSION panel: y=146, h=248 */
    double sbox_x = op_x + 20.0;
    double sbox_w = op_w - 40.0;
    double sbox_h = 248.0;
    double sbox_y = state->banner_visible ? 146.0 : 66.0;

    /* Footer buttons within THIS SESSION: y = sbox_y + sbox_h - 48 + 8 = sbox_y + 208 */
    double footer_btn_y = sbox_y + sbox_h - 40.0;

    /* Primary action button ("Transfer again", "Scan for media") */
    double prim_w = 125.0;
    double prim_x = sbox_x + sbox_w - 134.0;
    if (point_in_rect(px, py, prim_x, footer_btn_y, prim_w, 34)) {
        if (out_rect) *out_rect = (UiRect){ prim_x, footer_btn_y, prim_w, 34 };
        return UI_ID_PRIMARY_ACTION_BTN;
    }

    /* Report button */
    double rep_w = 75.0;
    double rep_x = sbox_x + sbox_w - 215.0;
    if (point_in_rect(px, py, rep_x, footer_btn_y, rep_w, 34)) {
        if (out_rect) *out_rect = (UiRect){ rep_x, footer_btn_y, rep_w, 34 };
        return UI_ID_REPORT_BTN;
    }

    /* Erase panel */
    double ebox_x = sbox_x;
    double ebox_w = sbox_w;
    double ebox_y = (state->window_height >= 820.0) ? 696.0 : (state->window_height - 110.0);
    double erase_btn_w = 215.0;
    double erase_btn_x = ebox_x + ebox_w - 224.0;
    double erase_btn_y = ebox_y + 55.0;
    if (point_in_rect(px, py, erase_btn_x, erase_btn_y, erase_btn_w, 34)) {
        if (out_rect) *out_rect = (UiRect){ erase_btn_x, erase_btn_y, erase_btn_w, 34 };
        return UI_ID_ERASE_BTN;
    }

    return UI_ID_NONE;
}
