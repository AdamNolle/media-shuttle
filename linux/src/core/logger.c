#include "ms_core.h"

#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* A transfer logs a line per file, and the app is meant to sit in the tray for
 * months, so the log has to be bounded. One rollover keeps the previous run's
 * history available for diagnosing a transfer without letting the folder grow
 * without end. */
static const long long MAXIMUM_BYTES = 2LL * 1024 * 1024;

AppLogger *ms_logger_new(const char *state_root)
{
    AppLogger *logger = g_new0(AppLogger, 1);
    char *root = ms_path_full(state_root);
    g_mkdir_with_parents(root, 0755);
    logger->log_path = ms_path_join(root, "app.log");
    logger->previous_log_path = ms_path_join(root, "app.previous.log");
    g_free(root);
    return logger;
}

void ms_logger_free(AppLogger *logger)
{
    if (logger == NULL) {
        return;
    }
    g_free(logger->log_path);
    g_free(logger->previous_log_path);
    g_free(logger);
}

static void roll_over_if_oversized(AppLogger *logger)
{
    struct stat info;
    if (stat(logger->log_path, &info) == 0 && info.st_size >= MAXIMUM_BYTES) {
        /* Logging must never take down the operation it is describing. */
        if (rename(logger->log_path, logger->previous_log_path) != 0) {
            return;
        }
    }
}

gboolean ms_logger_write(AppLogger *logger, const char *message, GError **error)
{
    roll_over_if_oversized(logger);

    time_t now = time(NULL);
    struct tm broken;
    localtime_r(&now, &broken);

    char timestamp[40];
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%dT%H:%M:%S%z", &broken);

    char *line = g_strdup_printf("%s  %s\n", timestamp, message);

    int fd = open(logger->log_path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
    if (fd < 0) {
        g_set_error(error, MS_ERROR, 5, "Could not open the log.");
        g_free(line);
        return FALSE;
    }

    ssize_t written = write(fd, line, strlen(line));
    close(fd);
    g_free(line);

    if (written < 0) {
        g_set_error(error, MS_ERROR, 5, "Could not write to the log.");
        return FALSE;
    }
    return TRUE;
}
