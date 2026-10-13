#ifndef MS_LAYOUT_H
#define MS_LAYOUT_H

#include <glib.h>
#include "theme.h"

enum {
    UI_ID_NONE = 0,
    UI_ID_SETTINGS_BTN,
    UI_ID_OPEN_CARD_BTN,
    UI_ID_CHANGE_DEST_BTN,
    UI_ID_OPEN_DEST_BTN,
    UI_ID_BANNER_DISMISS_BTN,
    UI_ID_REPORT_BTN,
    UI_ID_CANCEL_BTN,
    UI_ID_PRIMARY_ACTION_BTN,
    UI_ID_ERASE_BTN,

    /* Settings flyout */
    UI_ID_SETTINGS_THEME_COMBO,
    UI_ID_SETTINGS_TOGGLE_AUTO,
    UI_ID_SETTINGS_TOGGLE_DATE,
    UI_ID_SETTINGS_TOGGLE_NOTIF,
    UI_ID_SETTINGS_TOGGLE_ACTIVITY,
    UI_ID_SETTINGS_TOGGLE_STARTUP,

    /* Erase confirmation dialog */
    UI_ID_CONFIRM_CANCEL_BTN,
    UI_ID_CONFIRM_ERASE_BTN,
    UI_ID_CONFIRM_CHECKBOX,
    UI_ID_CONFIRM_TEXTBOX
};

typedef struct {
    double x, y, width, height;
} UiRect;

typedef struct {
    /* Dimensions */
    double window_width;
    double window_height;

    /* Theme */
    ThemeMode theme_mode;

    /* Header */
    char *top_status_text;
    int status_tone;       /* 0 = neutral, 1 = verified/green, 2 = caution/yellow, 3 = error/red */
    gboolean settings_open;

    /* Source panel */
    gboolean card_connected;
    char *card_label;
    char *card_detail;
    char *card_stats;
    int count_jpeg;
    int count_raw;
    int count_other;
    int count_video;
    char *destination_path;
    gboolean destination_missing;

    /* Operations panel: Banner */
    gboolean banner_visible;
    char *banner_title;
    char *banner_message;
    int banner_tone;       /* 0 = info, 1 = success, 2 = warning, 3 = error */

    /* This Session */
    char *phase_text;
    char *percent_text;
    double progress_fraction;
    char *stat_copied;
    char *stat_copied_sub;
    char *stat_safe;
    char *stat_safe_sub;
    char *stat_processed;
    char *stat_processed_sub;
    char *stat_throughput;
    char *stat_throughput_sub;
    char *stat_elapsed;
    char *stat_elapsed_sub;

    /* Footer */
    char *current_file_text;
    gboolean report_enabled;
    gboolean is_transferring;
    char *primary_action_text;

    /* Activity */
    gboolean show_activity;
    GPtrArray *activity_log;

    /* Erase Card */
    gboolean erase_unlocked;
    char *erase_description;

    /* Erase confirmation modal */
    gboolean confirm_erase_open;
    char *confirm_typed_phrase;
    gboolean confirm_checked;

    /* Settings flyout options */
    char *settings_theme;
    gboolean settings_auto_transfer;
    gboolean settings_group_by_date;
    gboolean settings_show_notifications;
    gboolean settings_show_activity;
    gboolean settings_start_with_system;

    /* Interactive state */
    int hovered_id;
    int pressed_id;
} UiState;

UiState *ui_state_new_preview(void);
UiState *ui_state_new_empty(void);
void ui_state_free(UiState *state);

int ui_layout_hit_test(const UiState *state, double x, double y, UiRect *out_rect);

#endif /* MS_LAYOUT_H */
