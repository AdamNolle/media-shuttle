#include "app.h"
#include "font.h"
#include "draw.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <unistd.h>
#include <sys/stat.h>

static char *find_assets_dir(const char *argv0)
{
    const char *candidates[] = {
        "assets",
        "linux/assets",
        "../assets",
        "../../assets",
        "/usr/share/media-shuttle/assets",
        "/usr/local/share/media-shuttle/assets"
    };

    for (size_t i = 0; i < G_N_ELEMENTS(candidates); i++) {
        char *probe = g_build_filename(candidates[i], "CascadiaMono.ttf", NULL);
        if (g_file_test(probe, G_FILE_TEST_EXISTS)) {
            g_free(probe);
            return g_strdup(candidates[i]);
        }
        g_free(probe);
    }

    if (argv0) {
        char *dir = g_path_get_dirname(argv0);
        char *probe = g_build_filename(dir, "assets", "CascadiaMono.ttf", NULL);
        if (g_file_test(probe, G_FILE_TEST_EXISTS)) {
            g_free(probe);
            char *ret = g_build_filename(dir, "assets", NULL);
            g_free(dir);
            return ret;
        }
        g_free(probe);
        g_free(dir);
    }

    return g_strdup("assets");
}

AppContext *app_context_new(int argc, char **argv)
{
    AppContext *ctx = g_new0(AppContext, 1);
    ctx->assets_dir = find_assets_dir(argc > 0 ? argv[0] : NULL);

    /* Command-line options */
    ctx->is_preview_mode = FALSE;
    ctx->is_screenshot_mode = FALSE;
    ctx->screenshot_out_path = NULL;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--screenshot") == 0) {
            ctx->is_screenshot_mode = TRUE;
            if (i + 1 < argc && argv[i + 1][0] != '-') {
                ctx->screenshot_out_path = g_strdup(argv[++i]);
            } else {
                ctx->screenshot_out_path = g_strdup("artifacts/ui-qa/linux-preview.png");
            }
        } else if (strcmp(argv[i], "--preview") == 0) {
            ctx->is_preview_mode = TRUE;
        }
    }

    /* State and storage directories */
    if (ctx->is_preview_mode || ctx->is_screenshot_mode) {
        ctx->state_root = g_build_filename(g_get_tmp_dir(), "MediaShuttle-VisualPreview", NULL);
    } else {
        ctx->state_root = g_build_filename(g_get_user_data_dir(), "media-shuttle", NULL);
    }
    g_mkdir_with_parents(ctx->state_root, 0755);

    ctx->store = ms_state_store_new(ctx->state_root);
    ctx->logger = ms_logger_new(ctx->state_root);
    ctx->presence = ms_presence_tracker_new();

    /* Load or init settings */
    ctx->settings = ms_settings_load(ctx->store);
    if (ctx->settings == NULL) {
        ctx->settings = g_new0(AppSettings, 1);
        char *desktop = g_build_filename(g_get_home_dir(), "Desktop", NULL);
        if (g_file_test(desktop, G_FILE_TEST_IS_DIR)) {
            ctx->settings->destination_root = g_build_filename(desktop, "Camera", NULL);
        } else {
            ctx->settings->destination_root = g_build_filename(g_get_home_dir(), "Camera", NULL);
        }
        g_free(desktop);
        ctx->settings->theme = g_strdup("Dark");
        ctx->settings->auto_transfer = FALSE;
        ctx->settings->group_by_date = FALSE;
        ctx->settings->show_notifications = TRUE;
        ctx->settings->show_activity_log = TRUE;
        ms_settings_save(ctx->store, ctx->settings, NULL);
    }

    /* Initialize UI state */
    if (ctx->is_preview_mode || ctx->is_screenshot_mode) {
        ctx->ui_state = ui_state_new_preview();
    } else {
        ctx->ui_state = ui_state_new_empty();
        g_free(ctx->ui_state->destination_path);
        ctx->ui_state->destination_path = g_strdup(ctx->settings->destination_root);
        ctx->ui_state->theme_mode = (g_ascii_strcasecmp(ctx->settings->theme, "Light") == 0) ? MS_THEME_LIGHT : MS_THEME_DARK;
        g_free(ctx->ui_state->settings_theme);
        ctx->ui_state->settings_theme = g_strdup(ctx->settings->theme);
        ctx->ui_state->settings_auto_transfer = ctx->settings->auto_transfer;
        ctx->ui_state->settings_group_by_date = ctx->settings->group_by_date;
        ctx->ui_state->settings_show_notifications = ctx->settings->show_notifications;
        ctx->ui_state->settings_show_activity = ctx->settings->show_activity_log;
        ctx->ui_state->show_activity = ctx->settings->show_activity_log;
    }

    font_init(ctx->assets_dir);

    return ctx;
}

void app_context_free(AppContext *ctx)
{
    if (ctx == NULL) return;
    if (ctx->scan_timer_id) g_source_remove(ctx->scan_timer_id);
    if (ctx->ui_state) ui_state_free(ctx->ui_state);
    if (ctx->settings) ms_settings_free(ctx->settings);
    if (ctx->store) ms_state_store_free(ctx->store);
    if (ctx->logger) ms_logger_free(ctx->logger);
    if (ctx->presence) ms_presence_tracker_free(ctx->presence);
    if (ctx->current_card) ms_card_info_free(ctx->current_card);
    if (ctx->verified_session) ms_session_free(ctx->verified_session);
    g_free(ctx->assets_dir);
    g_free(ctx->state_root);
    g_free(ctx->screenshot_out_path);
    g_free(ctx);
}

static void on_draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data)
{
    (void)area;
    AppContext *ctx = (AppContext *)user_data;
    ctx->ui_state->window_width = width;
    ctx->ui_state->window_height = height;
    draw_view(cr, ctx->ui_state, ctx->assets_dir);
}

static void on_motion(GtkEventControllerMotion *controller, double x, double y, gpointer user_data)
{
    (void)controller;
    AppContext *ctx = (AppContext *)user_data;
    UiRect rect;
    int hit_id = ui_layout_hit_test(ctx->ui_state, x, y, &rect);
    if (hit_id != ctx->ui_state->hovered_id) {
        ctx->ui_state->hovered_id = hit_id;
        gtk_widget_queue_draw(ctx->drawing_area);
    }

    if (hit_id == UI_ID_CONFIRM_TEXTBOX) {
        gtk_widget_set_cursor_from_name(ctx->drawing_area, "text");
    } else if (hit_id != UI_ID_NONE) {
        gtk_widget_set_cursor_from_name(ctx->drawing_area, "pointer");
    } else {
        gtk_widget_set_cursor_from_name(ctx->drawing_area, "default");
    }
}

static void on_leave(GtkEventControllerMotion *controller, gpointer user_data)
{
    (void)controller;
    AppContext *ctx = (AppContext *)user_data;
    if (ctx->ui_state->hovered_id != UI_ID_NONE) {
        ctx->ui_state->hovered_id = UI_ID_NONE;
        gtk_widget_queue_draw(ctx->drawing_area);
    }
    gtk_widget_set_cursor_from_name(ctx->drawing_area, "default");
}

/* Forward declarations for operations */
static void app_scan_sources(AppContext *ctx);
static void app_start_transfer(AppContext *ctx);
static void app_start_wipe(AppContext *ctx);
static void app_open_card_dialog(AppContext *ctx);
static void app_change_dest_dialog(AppContext *ctx);
static void app_open_dest_folder(AppContext *ctx);

static void on_click_pressed(GtkGestureClick *gesture, int n_press, double x, double y, gpointer user_data)
{
    (void)gesture;
    (void)n_press;
    AppContext *ctx = (AppContext *)user_data;
    UiRect rect;
    int hit_id = ui_layout_hit_test(ctx->ui_state, x, y, &rect);

    if (hit_id == UI_ID_NONE) {
        if (ctx->ui_state->settings_open) {
            ctx->ui_state->settings_open = FALSE;
            gtk_widget_queue_draw(ctx->drawing_area);
        }
        return;
    }

    switch (hit_id) {
        case UI_ID_SETTINGS_BTN:
            ctx->ui_state->settings_open = !ctx->ui_state->settings_open;
            gtk_widget_queue_draw(ctx->drawing_area);
            break;

        case UI_ID_SETTINGS_THEME_COMBO:
            if (ctx->ui_state->theme_mode == MS_THEME_DARK) {
                ctx->ui_state->theme_mode = MS_THEME_LIGHT;
                g_free(ctx->ui_state->settings_theme);
                ctx->ui_state->settings_theme = g_strdup("Light");
            } else {
                ctx->ui_state->theme_mode = MS_THEME_DARK;
                g_free(ctx->ui_state->settings_theme);
                ctx->ui_state->settings_theme = g_strdup("Dark");
            }
            g_free(ctx->settings->theme);
            ctx->settings->theme = g_strdup(ctx->ui_state->settings_theme);
            ms_settings_save(ctx->store, ctx->settings, NULL);
            gtk_widget_queue_draw(ctx->drawing_area);
            break;

        case UI_ID_SETTINGS_TOGGLE_AUTO:
            ctx->ui_state->settings_auto_transfer = !ctx->ui_state->settings_auto_transfer;
            ctx->settings->auto_transfer = ctx->ui_state->settings_auto_transfer;
            ms_settings_save(ctx->store, ctx->settings, NULL);
            gtk_widget_queue_draw(ctx->drawing_area);
            break;

        case UI_ID_SETTINGS_TOGGLE_DATE:
            ctx->ui_state->settings_group_by_date = !ctx->ui_state->settings_group_by_date;
            ctx->settings->group_by_date = ctx->ui_state->settings_group_by_date;
            ms_settings_save(ctx->store, ctx->settings, NULL);
            gtk_widget_queue_draw(ctx->drawing_area);
            break;

        case UI_ID_SETTINGS_TOGGLE_NOTIF:
            ctx->ui_state->settings_show_notifications = !ctx->ui_state->settings_show_notifications;
            ctx->settings->show_notifications = ctx->ui_state->settings_show_notifications;
            ms_settings_save(ctx->store, ctx->settings, NULL);
            gtk_widget_queue_draw(ctx->drawing_area);
            break;

        case UI_ID_SETTINGS_TOGGLE_ACTIVITY:
            ctx->ui_state->settings_show_activity = !ctx->ui_state->settings_show_activity;
            ctx->ui_state->show_activity = ctx->ui_state->settings_show_activity;
            ctx->settings->show_activity_log = ctx->ui_state->settings_show_activity;
            ms_settings_save(ctx->store, ctx->settings, NULL);
            gtk_widget_queue_draw(ctx->drawing_area);
            break;

        case UI_ID_SETTINGS_TOGGLE_STARTUP:
            ctx->ui_state->settings_start_with_system = !ctx->ui_state->settings_start_with_system;
            gtk_widget_queue_draw(ctx->drawing_area);
            break;

        case UI_ID_BANNER_DISMISS_BTN:
            ctx->ui_state->banner_visible = FALSE;
            gtk_widget_queue_draw(ctx->drawing_area);
            break;

        case UI_ID_OPEN_CARD_BTN:
            app_open_card_dialog(ctx);
            break;

        case UI_ID_CHANGE_DEST_BTN:
            app_change_dest_dialog(ctx);
            break;

        case UI_ID_OPEN_DEST_BTN:
            app_open_dest_folder(ctx);
            break;

        case UI_ID_PRIMARY_ACTION_BTN:
            if (ctx->is_busy) {
                ctx->cancel_requested = TRUE;
            } else if (ctx->ui_state->card_connected) {
                app_start_transfer(ctx);
            } else {
                app_scan_sources(ctx);
            }
            break;

        case UI_ID_ERASE_BTN:
            if (ctx->ui_state->erase_unlocked && !ctx->is_busy) {
                ctx->ui_state->confirm_erase_open = TRUE;
                g_free(ctx->ui_state->confirm_typed_phrase);
                ctx->ui_state->confirm_typed_phrase = g_strdup("");
                ctx->ui_state->confirm_checked = FALSE;
                gtk_widget_queue_draw(ctx->drawing_area);
            }
            break;

        case UI_ID_CONFIRM_CANCEL_BTN:
            ctx->ui_state->confirm_erase_open = FALSE;
            gtk_widget_queue_draw(ctx->drawing_area);
            break;

        case UI_ID_CONFIRM_CHECKBOX:
            ctx->ui_state->confirm_checked = !ctx->ui_state->confirm_checked;
            gtk_widget_queue_draw(ctx->drawing_area);
            break;

        case UI_ID_CONFIRM_ERASE_BTN:
            if (g_strcmp0(ctx->ui_state->confirm_typed_phrase, "ERASE EVERYTHING") == 0 &&
                ctx->ui_state->confirm_checked && !ctx->is_busy) {
                ctx->ui_state->confirm_erase_open = FALSE;
                app_start_wipe(ctx);
            }
            break;

        default:
            break;
    }
}

static gboolean on_key_pressed(GtkEventControllerKey *controller, guint keyval, guint keycode, GdkModifierType state, gpointer user_data)
{
    (void)controller;
    (void)keycode;
    AppContext *ctx = (AppContext *)user_data;

    if (ctx->ui_state->confirm_erase_open) {
        if (keyval == GDK_KEY_Escape) {
            ctx->ui_state->confirm_erase_open = FALSE;
            gtk_widget_queue_draw(ctx->drawing_area);
            return TRUE;
        } else if (keyval == GDK_KEY_BackSpace) {
            char *cur = ctx->ui_state->confirm_typed_phrase;
            size_t len = cur ? strlen(cur) : 0;
            if (len > 0) {
                cur[len - 1] = '\0';
                gtk_widget_queue_draw(ctx->drawing_area);
            }
            return TRUE;
        } else if (keyval == GDK_KEY_Return || keyval == GDK_KEY_KP_Enter) {
            if (g_strcmp0(ctx->ui_state->confirm_typed_phrase, "ERASE EVERYTHING") == 0 &&
                ctx->ui_state->confirm_checked && !ctx->is_busy) {
                ctx->ui_state->confirm_erase_open = FALSE;
                app_start_wipe(ctx);
                return TRUE;
            }
        } else {
            gunichar c = gdk_keyval_to_unicode(keyval);
            if (c >= 32 && c < 127) {
                char *cur = ctx->ui_state->confirm_typed_phrase;
                char ch = (char) g_ascii_toupper((char) c);
                char *next = g_strdup_printf("%s%c", cur ? cur : "", ch);
                g_free(ctx->ui_state->confirm_typed_phrase);
                ctx->ui_state->confirm_typed_phrase = next;
                gtk_widget_queue_draw(ctx->drawing_area);
                return TRUE;
            }
        }
    } else {
        if ((state & GDK_CONTROL_MASK) && (keyval == GDK_KEY_o || keyval == GDK_KEY_O)) {
            app_open_card_dialog(ctx);
            return TRUE;
        }
        if (keyval == GDK_KEY_Escape && ctx->ui_state->settings_open) {
            ctx->ui_state->settings_open = FALSE;
            gtk_widget_queue_draw(ctx->drawing_area);
            return TRUE;
        }
    }

    return FALSE;
}

/* Card Selection Dialog */
static void on_card_folder_finish(GObject *source, GAsyncResult *res, gpointer user_data)
{
    AppContext *ctx = (AppContext *)user_data;
    GtkFileDialog *dialog = GTK_FILE_DIALOG(source);
    GError *error = NULL;
    GFile *folder = gtk_file_dialog_select_folder_finish(dialog, res, &error);
    if (folder != NULL) {
        char *path = g_file_get_path(folder);
        if (path) {
            if (ctx->current_card) ms_card_info_free(ctx->current_card);
            ctx->current_card = ms_get_selected_source(path, NULL);
            app_scan_sources(ctx);
            g_free(path);
        }
        g_object_unref(folder);
    }
    if (error) g_error_free(error);
}

static void app_open_card_dialog(AppContext *ctx)
{
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, "Select Camera Card Folder");
    gtk_file_dialog_select_folder(dialog, GTK_WINDOW(ctx->window), NULL, on_card_folder_finish, ctx);
    g_object_unref(dialog);
}

/* Destination Selection Dialog */
static void on_dest_folder_finish(GObject *source, GAsyncResult *res, gpointer user_data)
{
    AppContext *ctx = (AppContext *)user_data;
    GtkFileDialog *dialog = GTK_FILE_DIALOG(source);
    GError *error = NULL;
    GFile *folder = gtk_file_dialog_select_folder_finish(dialog, res, &error);
    if (folder != NULL) {
        char *path = g_file_get_path(folder);
        if (path) {
            g_free(ctx->settings->destination_root);
            ctx->settings->destination_root = g_strdup(path);
            g_free(ctx->ui_state->destination_path);
            ctx->ui_state->destination_path = g_strdup(path);
            ms_settings_save(ctx->store, ctx->settings, NULL);
            gtk_widget_queue_draw(ctx->drawing_area);
            g_free(path);
        }
        g_object_unref(folder);
    }
    if (error) g_error_free(error);
}

static void app_change_dest_dialog(AppContext *ctx)
{
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, "Select Destination Folder");
    gtk_file_dialog_select_folder(dialog, GTK_WINDOW(ctx->window), NULL, on_dest_folder_finish, ctx);
    g_object_unref(dialog);
}

static void app_open_dest_folder(AppContext *ctx)
{
    if (ctx->ui_state->destination_path == NULL) return;
    char *quoted = g_shell_quote(ctx->ui_state->destination_path);
    char *cmd = g_strdup_printf("xdg-open %s >/dev/null 2>&1 &", quoted);
    int res = system(cmd);
    (void)res;
    g_free(cmd);
    g_free(quoted);
}

/* Polling & Source Scanning */
static void app_scan_sources(AppContext *ctx)
{
    if (ctx->is_busy) return;

    CardInfo *card = ctx->current_card;
    if (card == NULL) {
        GPtrArray *cands = ms_get_candidates(ctx->settings->destination_root);
        if (cands && cands->len > 0) {
            const char *first = g_ptr_array_index(cands, 0);
            card = ms_get_selected_source(first, NULL);
            ctx->current_card = card;
        }
        if (cands) g_ptr_array_unref(cands);
    }

    if (card != NULL) {
        CardScan *scan = ms_scan_card(card->root_path);
        ctx->ui_state->card_connected = TRUE;
        g_free(ctx->ui_state->card_label);
        ctx->ui_state->card_label = g_strdup(card->volume_label ? card->volume_label : "Camera Card");

        g_free(ctx->ui_state->card_detail);
        ctx->ui_state->card_detail = g_strdup_printf("%s · Removable media", card->root_path);

        int n_jpg = 0, n_raw = 0, n_vid = 0, n_oth = 0;
        long long total_bytes = 0;
        for (guint i = 0; i < scan->media->len; i++) {
            MediaItem *m = g_ptr_array_index(scan->media, i);
            total_bytes += m->size;
            if (m->kind == MEDIA_JPEG) n_jpg++;
            else if (m->kind == MEDIA_RAW) n_raw++;
            else if (m->kind == MEDIA_VIDEO) n_vid++;
            else n_oth++;
        }

        ctx->ui_state->count_jpeg = n_jpg;
        ctx->ui_state->count_raw = n_raw;
        ctx->ui_state->count_video = n_vid;
        ctx->ui_state->count_other = n_oth;

        g_free(ctx->ui_state->card_stats);
        double gb = total_bytes / (1024.0 * 1024.0 * 1024.0);
        ctx->ui_state->card_stats = g_strdup_printf("%u assets · %.2f GB", scan->media->len, gb);

        /* Check erase eligibility */
        if (ctx->verified_session) ms_session_free(ctx->verified_session);
        ctx->verified_session = ms_load_latest_verified_for_card(ctx->store, card);
        gboolean eligible = ms_session_eligible_for_erase(ctx->verified_session, card, scan->media);
        ctx->ui_state->erase_unlocked = eligible;
        g_free(ctx->ui_state->erase_description);
        if (eligible) {
            ctx->ui_state->erase_description = g_strdup_printf(
                "Every remaining file on %s has a verified copy · typed confirmation required", card->root_path);
        } else {
            ctx->ui_state->erase_description = g_strdup(
                "Locked until every remaining camera file has a verified destination copy.");
        }

        g_free(ctx->ui_state->primary_action_text);
        ctx->ui_state->primary_action_text = (ctx->verified_session != NULL) ? g_strdup("Transfer again") : g_strdup("Transfer now");

        ms_card_scan_free(scan);
    } else {
        ctx->ui_state->card_connected = FALSE;
        ctx->ui_state->erase_unlocked = FALSE;
        g_free(ctx->ui_state->card_label);
        ctx->ui_state->card_label = g_strdup("No card connected");
        g_free(ctx->ui_state->card_detail);
        ctx->ui_state->card_detail = g_strdup("Choose a source or insert a camera card.");
        g_free(ctx->ui_state->card_stats);
        ctx->ui_state->card_stats = g_strdup("—");
        ctx->ui_state->count_jpeg = 0;
        ctx->ui_state->count_raw = 0;
        ctx->ui_state->count_other = 0;
        ctx->ui_state->count_video = 0;
        g_free(ctx->ui_state->primary_action_text);
        ctx->ui_state->primary_action_text = g_strdup("Scan for media");
    }

    gtk_widget_queue_draw(ctx->drawing_area);
}

static gboolean on_scan_timer_tick(gpointer user_data)
{
    AppContext *ctx = (AppContext *)user_data;
    if (!ctx->is_busy && !ctx->is_preview_mode) {
        app_scan_sources(ctx);
    }
    return G_SOURCE_CONTINUE;
}

/* Background Transfer Worker */
typedef struct {
    AppContext *ctx;
    OperationProgress prog;
    double elapsed_sec;
} ProgressPayload;

static gboolean on_progress_ui(gpointer user_data)
{
    ProgressPayload *p = (ProgressPayload *)user_data;
    AppContext *ctx = p->ctx;

    /* Phase text */
    const char *phase_str = "STANDBY";
    switch (p->prog.phase) {
        case PHASE_SCANNING: phase_str = "SCANNING"; break;
        case PHASE_CHECKING_DUPLICATE: phase_str = "CHECKING"; break;
        case PHASE_COPYING: phase_str = "COPYING"; break;
        case PHASE_VERIFYING: phase_str = "VERIFYING"; break;
        case PHASE_REVERIFYING: phase_str = "RE-VERIFYING"; break;
        case PHASE_ERASING: phase_str = "ERASING"; break;
        case PHASE_COMPLETE: phase_str = "COMPLETE"; break;
        case PHASE_CANCELLED: phase_str = "CANCELLED"; break;
        case PHASE_ERROR: phase_str = "ERROR"; break;
        default: break;
    }
    g_free(ctx->ui_state->phase_text);
    ctx->ui_state->phase_text = g_strdup(phase_str);

    /* Progress fraction & percent */
    double fraction = 0.0;
    if (p->prog.total_bytes > 0) {
        fraction = (double)p->prog.processed_bytes / (double)p->prog.total_bytes;
    } else if (p->prog.total_files > 0) {
        fraction = (double)p->prog.completed_files / (double)p->prog.total_files;
    }
    if (fraction > 1.0) fraction = 1.0;
    ctx->ui_state->progress_fraction = fraction;
    g_free(ctx->ui_state->percent_text);
    ctx->ui_state->percent_text = g_strdup_printf("%d%%", (int)(fraction * 100.0));

    /* Metrics */
    g_free(ctx->ui_state->stat_copied);
    ctx->ui_state->stat_copied = g_strdup_printf("%d", p->prog.copied_files);

    g_free(ctx->ui_state->stat_safe);
    ctx->ui_state->stat_safe = g_strdup_printf("%d", p->prog.skipped_files);

    double mb_proc = p->prog.processed_bytes / (1024.0 * 1024.0);
    g_free(ctx->ui_state->stat_processed);
    if (mb_proc >= 1000.0) {
        ctx->ui_state->stat_processed = g_strdup_printf("%.2f GB", mb_proc / 1024.0);
    } else {
        ctx->ui_state->stat_processed = g_strdup_printf("%.1f MB", mb_proc);
    }

    if (p->elapsed_sec > 0.5) {
        double mbps = mb_proc / p->elapsed_sec;
        g_free(ctx->ui_state->stat_throughput);
        ctx->ui_state->stat_throughput = g_strdup_printf("%.1f", mbps);
    }

    int mins = (int)p->elapsed_sec / 60;
    int secs = (int)p->elapsed_sec % 60;
    g_free(ctx->ui_state->stat_elapsed);
    ctx->ui_state->stat_elapsed = g_strdup_printf("%d:%02d", mins, secs);

    if (p->prog.current_item) {
        g_free(ctx->ui_state->current_file_text);
        ctx->ui_state->current_file_text = g_strdup_printf("NOW · %s", p->prog.current_item);
    }

    gtk_widget_queue_draw(ctx->drawing_area);

    g_free(p->prog.current_item);
    g_free(p->prog.current_source_path);
    g_free(p->prog.current_destination_folder);
    g_free(p);
    return G_SOURCE_REMOVE;
}

typedef struct {
    AppContext *ctx;
    time_t start_time;
} WorkerContext;

static void transfer_progress_cb(const OperationProgress *prog, void *user_data)
{
    WorkerContext *wc = (WorkerContext *)user_data;
    ProgressPayload *p = g_new0(ProgressPayload, 1);
    p->ctx = wc->ctx;
    p->prog = *prog;
    if (prog->current_item) p->prog.current_item = g_strdup(prog->current_item);
    if (prog->current_source_path) p->prog.current_source_path = g_strdup(prog->current_source_path);
    if (prog->current_destination_folder) p->prog.current_destination_folder = g_strdup(prog->current_destination_folder);
    p->elapsed_sec = difftime(time(NULL), wc->start_time);
    g_idle_add(on_progress_ui, p);
}

static gboolean on_queue_draw_idle(gpointer user_data)
{
    GtkWidget *widget = (GtkWidget *)user_data;
    gtk_widget_queue_draw(widget);
    return G_SOURCE_REMOVE;
}

static gpointer transfer_thread_func(gpointer user_data)
{
    WorkerContext *wc = (WorkerContext *)user_data;
    AppContext *ctx = wc->ctx;

    GError *error = NULL;
    TransferResult *res = ms_transfer(
        ctx->store,
        ctx->logger,
        ctx->current_card,
        ctx->settings->destination_root,
        ctx->settings->group_by_date,
        transfer_progress_cb,
        wc,
        &ctx->cancel_requested,
        &error
    );

    if (res != NULL && res->session != NULL && g_strcmp0(res->session->status, "Verified") == 0) {
        g_idle_add(on_queue_draw_idle, ctx->drawing_area);
        ctx->ui_state->banner_visible = TRUE;
        g_free(ctx->ui_state->banner_title);
        ctx->ui_state->banner_title = g_strdup_printf(
            "Transfer verified — %d files safe in the destination", res->session->total_files);
        g_free(ctx->ui_state->banner_message);
        ctx->ui_state->banner_message = g_strdup("SHA-256 matched on every remaining camera file");
        ctx->ui_state->banner_tone = 1;

        g_free(ctx->ui_state->phase_text);
        ctx->ui_state->phase_text = g_strdup("VERIFIED");
        ctx->ui_state->status_tone = 1;

        if (ctx->verified_session) ms_session_free(ctx->verified_session);
        ctx->verified_session = res->session;
        res->session = NULL; /* Transfer ownership */

        /* Activity log */
        time_t now = time(NULL);
        struct tm tm_now;
        localtime_r(&now, &tm_now);
        char time_buf[64];
        strftime(time_buf, sizeof(time_buf), "%I:%M:%S %p", &tm_now);
        char *log_entry = g_strdup_printf("%s  Verification complete — %d files match by SHA-256.",
            time_buf, ctx->verified_session->total_files);
        g_ptr_array_insert(ctx->ui_state->activity_log, 0, log_entry);

        if (ctx->settings->show_notifications) {
            char *ncmd = g_strdup_printf("notify-send 'Media Shuttle' 'Transfer verified: %d files match by SHA-256' >/dev/null 2>&1 &",
                ctx->verified_session->total_files);
            int nres = system(ncmd);
            (void)nres;
            g_free(ncmd);
        }
    } else if (error) {
        ctx->ui_state->banner_visible = TRUE;
        g_free(ctx->ui_state->banner_title);
        ctx->ui_state->banner_title = g_strdup("Transfer failed");
        g_free(ctx->ui_state->banner_message);
        ctx->ui_state->banner_message = g_strdup(error->message);
        ctx->ui_state->banner_tone = 3;
        ctx->ui_state->status_tone = 3;
        g_error_free(error);
    }

    if (res) ms_transfer_result_free(res);

    ctx->is_busy = FALSE;
    ctx->cancel_requested = FALSE;
    ctx->ui_state->is_transferring = FALSE;
    g_free(ctx->ui_state->primary_action_text);
    ctx->ui_state->primary_action_text = g_strdup("Transfer again");

    app_scan_sources(ctx);

    g_free(wc);
    return NULL;
}

static void app_start_transfer(AppContext *ctx)
{
    if (ctx->is_busy || ctx->current_card == NULL) return;

    ctx->is_busy = TRUE;
    ctx->cancel_requested = FALSE;
    ctx->ui_state->is_transferring = TRUE;
    g_free(ctx->ui_state->primary_action_text);
    ctx->ui_state->primary_action_text = g_strdup("Cancel transfer");

    WorkerContext *wc = g_new0(WorkerContext, 1);
    wc->ctx = ctx;
    wc->start_time = time(NULL);

    ctx->worker_thread = g_thread_new("transfer", transfer_thread_func, wc);
    g_thread_unref(ctx->worker_thread);
}

/* Background Wipe Worker */
static gpointer wipe_thread_func(gpointer user_data)
{
    WorkerContext *wc = (WorkerContext *)user_data;
    AppContext *ctx = wc->ctx;

    GError *error = NULL;
    WipeResult *res = ms_wipe(
        ctx->store,
        ctx->logger,
        ctx->current_card,
        ctx->verified_session,
        transfer_progress_cb,
        wc,
        &ctx->cancel_requested,
        &error
    );

    if (res != NULL) {
        ctx->ui_state->banner_visible = TRUE;
        g_free(ctx->ui_state->banner_title);
        ctx->ui_state->banner_title = g_strdup("Card erased successfully");
        g_free(ctx->ui_state->banner_message);
        ctx->ui_state->banner_message = g_strdup_printf("%d files deleted cleanly.", res->deleted_files);
        ctx->ui_state->banner_tone = 1;

        time_t now = time(NULL);
        struct tm tm_now;
        localtime_r(&now, &tm_now);
        char time_buf[64];
        strftime(time_buf, sizeof(time_buf), "%I:%M:%S %p", &tm_now);
        char *log_entry = g_strdup_printf("%s  Erase complete — %d files deleted.", time_buf, res->deleted_files);
        g_ptr_array_insert(ctx->ui_state->activity_log, 0, log_entry);

        ms_wipe_result_free(res);
    } else if (error) {
        ctx->ui_state->banner_visible = TRUE;
        g_free(ctx->ui_state->banner_title);
        ctx->ui_state->banner_title = g_strdup("Erase failed");
        g_free(ctx->ui_state->banner_message);
        ctx->ui_state->banner_message = g_strdup(error->message);
        ctx->ui_state->banner_tone = 3;
        g_error_free(error);
    }

    ctx->is_busy = FALSE;
    ctx->cancel_requested = FALSE;
    app_scan_sources(ctx);

    g_free(wc);
    return NULL;
}

static void app_start_wipe(AppContext *ctx)
{
    if (ctx->is_busy || ctx->current_card == NULL || ctx->verified_session == NULL) return;

    ctx->is_busy = TRUE;
    ctx->cancel_requested = FALSE;

    WorkerContext *wc = g_new0(WorkerContext, 1);
    wc->ctx = ctx;
    wc->start_time = time(NULL);

    ctx->worker_thread = g_thread_new("wipe", wipe_thread_func, wc);
    g_thread_unref(ctx->worker_thread);
}

/* GTK Application Activate */
static void on_app_activate(GtkApplication *app, gpointer user_data)
{
    AppContext *ctx = (AppContext *)user_data;

    ctx->window = gtk_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(ctx->window),
        ctx->is_preview_mode ? "Media Shuttle — Visual Preview" : "Media Shuttle");
    gtk_window_set_default_size(GTK_WINDOW(ctx->window), 896, 832);

    /* Drawing area */
    ctx->drawing_area = gtk_drawing_area_new();
    gtk_drawing_area_set_content_width(GTK_DRAWING_AREA(ctx->drawing_area), 896);
    gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(ctx->drawing_area), 832);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(ctx->drawing_area), on_draw, ctx, NULL);
    gtk_window_set_child(GTK_WINDOW(ctx->window), ctx->drawing_area);

    /* Gesture / Controller setup */
    GtkGesture *click = gtk_gesture_click_new();
    g_signal_connect(click, "pressed", G_CALLBACK(on_click_pressed), ctx);
    gtk_widget_add_controller(ctx->drawing_area, GTK_EVENT_CONTROLLER(click));

    GtkEventController *motion = gtk_event_controller_motion_new();
    g_signal_connect(motion, "motion", G_CALLBACK(on_motion), ctx);
    g_signal_connect(motion, "leave", G_CALLBACK(on_leave), ctx);
    gtk_widget_add_controller(ctx->drawing_area, motion);

    GtkEventController *key = gtk_event_controller_key_new();
    g_signal_connect(key, "key-pressed", G_CALLBACK(on_key_pressed), ctx);
    gtk_widget_add_controller(GTK_WIDGET(ctx->window), key);

    /* Start card presence scanner timer (every 2s) */
    if (!ctx->is_preview_mode) {
        app_scan_sources(ctx);
        ctx->scan_timer_id = g_timeout_add_seconds(2, on_scan_timer_tick, ctx);
    }

    gtk_window_present(GTK_WINDOW(ctx->window));
}

static const GOptionEntry app_entries[] = {
    { "preview", 0, 0, G_OPTION_ARG_NONE, NULL, "Run in visual preview / reference mode", NULL },
    { "screenshot", 0, 0, G_OPTION_ARG_STRING, NULL, "Render preview PNG offscreen", "FILE" },
    { "theme", 0, 0, G_OPTION_ARG_STRING, NULL, "Force specific theme (dark/light)", "THEME" },
    { NULL }
};

int app_run(AppContext *ctx, int argc, char **argv)
{
    if (ctx->is_screenshot_mode) {
        /* Headless offscreen render directly to PNG */
        double width = 896.0;
        double height = 832.0;

        cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, (int)width, (int)height);
        cairo_t *cr = cairo_create(surface);

        draw_view(cr, ctx->ui_state, ctx->assets_dir);

        cairo_status_t status = cairo_surface_write_to_png(surface, ctx->screenshot_out_path);
        cairo_destroy(cr);
        cairo_surface_destroy(surface);

        if (status != CAIRO_STATUS_SUCCESS) {
            fprintf(stderr, "Failed to write screenshot to %s: %s\n",
                ctx->screenshot_out_path, cairo_status_to_string(status));
            return 1;
        }

        printf("Screenshot successfully rendered to %s\n", ctx->screenshot_out_path);
        return 0;
    }

    ctx->app = gtk_application_new("com.mediashuttle.MediaShuttle", G_APPLICATION_NON_UNIQUE);
    g_application_add_main_option_entries(G_APPLICATION(ctx->app), app_entries);
    g_signal_connect(ctx->app, "activate", G_CALLBACK(on_app_activate), ctx);

    int status = g_application_run(G_APPLICATION(ctx->app), argc, argv);
    g_object_unref(ctx->app);
    return status;
}
