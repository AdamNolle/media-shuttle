#ifndef MS_APP_H
#define MS_APP_H

#include <gtk/gtk.h>
#include "../core/ms_core.h"
#include "layout.h"
#include "theme.h"

typedef struct {
    GtkApplication *app;
    GtkWidget *window;
    GtkWidget *drawing_area;

    UiState *ui_state;
    StateStore *store;
    AppLogger *logger;
    AppSettings *settings;
    CardPresenceTracker *presence;

    char *assets_dir;
    char *state_root;
    CardInfo *current_card;
    TransferSession *verified_session;

    /* Background operations */
    volatile gboolean is_busy;
    volatile gboolean cancel_requested;
    GThread *worker_thread;

    guint scan_timer_id;

    /* Mode flags */
    gboolean is_preview_mode;
    gboolean is_screenshot_mode;
    char *screenshot_out_path;
} AppContext;

AppContext *app_context_new(int argc, char **argv);
void app_context_free(AppContext *ctx);

int app_run(AppContext *ctx, int argc, char **argv);

#endif /* MS_APP_H */
