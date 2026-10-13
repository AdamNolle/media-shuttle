#include "ms_core.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define BUFFER_SIZE (1024 * 1024)
static const char PARTIAL_MARKER[] = ".partial-";

static gboolean error_started(GError **error)
{
    return error != NULL && *error != NULL;
}

static char *random_hex32_local(void)
{
    GString *hex = g_string_new(NULL);
    for (int i = 0; i < 16; i++) {
        g_string_append_printf(hex, "%02x", g_random_int_range(0, 256));
    }
    return g_string_free(hex, FALSE);
}

static gboolean is_hex_digit(char c)
{
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

static gboolean is_owned_partial(const char *path)
{
    char *name = ms_path_filename(path);

    /* Only files this app created are removed: the marker must be followed by a full
     * 32-character identifier. "keep.partial-draft" is somebody's file. */
    const char *marker = strstr(name, PARTIAL_MARKER);
    if (marker == NULL) {
        g_free(name);
        return FALSE;
    }

    const char *identifier = marker + strlen(PARTIAL_MARKER);
    if (strlen(identifier) != 32) {
        g_free(name);
        return FALSE;
    }

    for (const char *p = identifier; *p != '\0'; p++) {
        if (!is_hex_digit(*p)) {
            g_free(name);
            return FALSE;
        }
    }

    g_free(name);
    return TRUE;
}

static void cleanup_partials(const char *destination_root)
{
    GPtrArray *pending = g_ptr_array_new_with_free_func(g_free);
    g_ptr_array_add(pending, g_strdup(destination_root));

    while (pending->len > 0) {
        char *directory = g_ptr_array_index(pending, pending->len - 1);
        g_ptr_array_remove_index(pending, pending->len - 1);

        DIR *handle = opendir(directory);
        if (handle == NULL) {
            /* A single unreadable folder anywhere under the destination must not
             * throw out of the enumeration and fail the whole transfer before it
             * starts. */
            continue;
        }

        struct dirent *entry;
        while ((entry = readdir(handle)) != NULL) {
            if (g_strcmp0(entry->d_name, ".") == 0 || g_strcmp0(entry->d_name, "..") == 0) {
                continue;
            }

            char *full = ms_path_join(directory, entry->d_name);
            struct stat info;
            if (lstat(full, &info) != 0) {
                g_free(full);
                continue;
            }
            if (S_ISLNK(info.st_mode)) {
                g_free(full);
                continue;
            }
            if (S_ISDIR(info.st_mode)) {
                g_ptr_array_add(pending, full);
                continue;
            }
            if (strstr(entry->d_name, PARTIAL_MARKER) != NULL && is_owned_partial(full)) {
                unlink(full);
            }
            g_free(full);
        }
        closedir(handle);
    }

    g_ptr_array_free(pending, TRUE);
}

static char *unique_path(const char *directory, const char *file_name)
{
    const char *dot = strrchr(file_name, '.');
    char *base = dot != NULL ? g_strndup(file_name, (gsize)(dot - file_name)) : g_strdup(file_name);
    char *extension = dot != NULL ? g_strdup(dot) : g_strdup("");

    for (int number = 2; ; number++) {
        char *candidate = g_strdup_printf("%s/%s (%d)%s", directory, base, number, extension);
        if (!g_file_test(candidate, G_FILE_TEST_EXISTS)) {
            g_free(base);
            g_free(extension);
            return candidate;
        }
        g_free(candidate);
    }
}

static void report(ProgressCallback progress, void *user_data, OperationPhase phase,
                   const char *current_item, int completed, int total,
                   long long processed, long long total_bytes,
                   int copied, int skipped,
                   const char *source_path, const char *destination_folder)
{
    if (progress == NULL) {
        return;
    }

    OperationProgress p = {0};
    p.phase = phase;
    p.current_item = (char *) current_item;
    p.completed_files = completed;
    p.total_files = total;
    p.processed_bytes = processed;
    p.total_bytes = total_bytes;
    p.copied_files = copied;
    p.skipped_files = skipped;
    p.current_source_path = (char *) source_path;
    p.current_destination_folder = (char *) destination_folder;
    progress(&p, user_data);
}

/* Creates a category folder only for the kinds this card actually holds. Creating
 * all four up front left an empty Photos/Other next to every transfer of a card
 * with no other-format photos, which reads as a category that failed rather than
 * one that was never needed. */
static void ensure_destination_folders(const char *destination_root, GPtrArray *media)
{
    gboolean seen[4] = {FALSE, FALSE, FALSE, FALSE};

    for (guint index = 0; index < media->len; index++) {
        MediaItem *item = g_ptr_array_index(media, index);
        if (seen[item->kind]) {
            continue;
        }
        seen[item->kind] = TRUE;

        char *folder = ms_path_join(destination_root, ms_destination_folder(item->kind));
        GError *error = NULL;
        if (ms_ensure_no_links(folder, &error)) {
            g_mkdir_with_parents(folder, 0755);
        }
        g_clear_error(&error);
        g_free(folder);
    }
}

static char *date_folder(MediaItem *item)
{
    struct tm broken;
    localtime_r(&item->last_write_utc, &broken);
    return g_strdup_printf("%04d-%02d-%02d", broken.tm_year + 1900, broken.tm_mon + 1, broken.tm_mday);
}

static char *copy_and_verify(
    AppLogger *logger,
    MediaItem *item,
    const char *destination_path,
    int total_files,
    int completed_files,
    long long total_bytes,
    long long *processed_bytes,
    TransferSession *session,
    ProgressCallback progress,
    void *user_data,
    volatile gboolean *cancelled,
    GError **error)
{
    char *temporary = g_strdup_printf("%s%s%s", destination_path, PARTIAL_MARKER, random_hex32_local());

    int source_fd = open(item->source_path, O_RDONLY | O_CLOEXEC);
    if (source_fd < 0) {
        g_set_error(error, MS_ERROR, 9, "Could not open %s.", item->file_name);
        g_free(temporary);
        return NULL;
    }

    int destination_fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    if (destination_fd < 0) {
        g_set_error(error, MS_ERROR, 9, "Could not create %s.", temporary);
        close(source_fd);
        g_free(temporary);
        return NULL;
    }

    char *copy_message = g_strdup_printf("Copying %s", item->file_name);
    ms_logger_write(logger, copy_message, NULL);
    g_free(copy_message);

    Sha256Stream *stream = ms_sha256_stream_new();
    static guint8 buffer[BUFFER_SIZE];
    long long copied_bytes = 0;
    ssize_t bytes_read;

    while ((bytes_read = read(source_fd, buffer, BUFFER_SIZE)) > 0) {
        copied_bytes += bytes_read;
        ms_sha256_stream_update(stream, buffer, (gsize) bytes_read);

        if (write(destination_fd, buffer, (gsize) bytes_read) != (ssize_t) bytes_read) {
            g_set_error(error, MS_ERROR, 9, "Could not write %s.", item->file_name);
            break;
        }

        long long next = *processed_bytes + bytes_read;
        *processed_bytes = next;
        report(progress, user_data, PHASE_COPYING, item->file_name, completed_files, total_files,
               next, total_bytes, session->copied_count, session->skipped_count,
               item->source_path, ms_relative_destination_folder(session->destination_root, destination_path));

        if (cancelled != NULL && *cancelled) {
            break;
        }
    }

    fsync(destination_fd);
    close(source_fd);
    close(destination_fd);

    char *source_hash = ms_sha256_stream_hex(stream);
    ms_sha256_stream_free(stream);

    if (error_started(error)) {
        unlink(temporary);
        g_free(source_hash);
        g_free(temporary);
        return NULL;
    }

    if (cancelled != NULL && *cancelled) {
        unlink(temporary);
        g_free(source_hash);
        g_free(temporary);
        g_set_error(error, MS_ERROR, 10, "Transfer cancelled.");
        return NULL;
    }

    /* Both hashes are taken from the bytes that were actually copied, so a file the
     * camera was still writing when the scan sized it passes verification and is then
     * recorded against the stale size. Erase compares the destination against that
     * recorded size and refuses the card — permanently, and with no explanation the
     * card's owner can act on. Catch the change here instead, while re-scanning and
     * transferring again still fixes it. */
    if (copied_bytes != item->size) {
        g_set_error(error, MS_ERROR, 9,
                    "%s changed while it was being copied. Re-scan the card and transfer again.",
                    item->file_name);
        unlink(temporary);
        g_free(source_hash);
        g_free(temporary);
        return NULL;
    }

    struct timespec times[2];
    times[0].tv_sec = item->last_write_utc;
    times[1].tv_sec = item->last_write_utc;
    utimensat(AT_FDCWD, temporary, times, 0);

    report(progress, user_data, PHASE_VERIFYING, item->file_name, completed_files, total_files,
           *processed_bytes, total_bytes, session->copied_count, session->skipped_count,
           item->source_path, ms_relative_destination_folder(session->destination_root, destination_path));

    GError *hash_error = NULL;
    char *destination_hash = ms_sha256_file(temporary, &hash_error);
    if (destination_hash == NULL) {
        g_clear_error(&hash_error);
        g_free(source_hash);
        unlink(temporary);
        g_free(temporary);
        return NULL;
    }

    if (g_ascii_strcasecmp(source_hash, destination_hash) != 0) {
        g_set_error(error, MS_ERROR, 9, "SHA-256 verification failed for %s.", item->file_name);
        g_free(source_hash);
        g_free(destination_hash);
        unlink(temporary);
        g_free(temporary);
        return NULL;
    }

    if (rename(temporary, destination_path) != 0) {
        g_set_error(error, MS_ERROR, 9, "Could not publish %s.", item->file_name);
        g_free(source_hash);
        g_free(destination_hash);
        unlink(temporary);
        g_free(temporary);
        return NULL;
    }

    char *verified_message = g_strdup_printf("Verified %s", item->file_name);
    ms_logger_write(logger, verified_message, NULL);
    g_free(verified_message);

    g_free(destination_hash);
    g_free(temporary);
    return source_hash;
}

TransferResult *ms_transfer(
    StateStore *store,
    AppLogger *logger,
    CardInfo *card,
    const char *destination_root,
    gboolean group_by_date,
    ProgressCallback progress,
    void *user_data,
    volatile gboolean *cancelled,
    GError **error)
{
    char *destination = ms_path_full(destination_root);

    if (!ms_ensure_destination_outside_source(destination, card->root_path, error)) {
        g_free(destination);
        return NULL;
    }

    if (!g_file_test(destination, G_FILE_TEST_IS_DIR)) {
        g_set_error(error, MS_ERROR, 11, "Destination is missing: %s", destination);
        g_free(destination);
        return NULL;
    }

    cleanup_partials(destination);

    report(progress, user_data, PHASE_SCANNING, "Scanning card", 0, 0, 0, 0, 0, 0, NULL, NULL);

    char *scan_message = g_strdup_printf("Scanning %s for camera media", card->root_path);
    ms_logger_write(logger, scan_message, NULL);
    g_free(scan_message);

    GPtrArray *media = ms_scan_media(card->root_path);
    if (media->len == 0) {
        g_set_error(error, MS_ERROR, 12, "No supported photos or videos were found on this card.");
        g_ptr_array_free(media, TRUE);
        g_free(destination);
        return NULL;
    }

    long long total_bytes = 0;
    for (guint index = 0; index < media->len; index++) {
        total_bytes += ((MediaItem *) media->pdata[index])->size;
    }

    long long available = 0;
    if (!ms_free_space(destination, &available, NULL, error)) {
        g_ptr_array_free(media, TRUE);
        g_free(destination);
        return NULL;
    }

    const long long reserve = 1024LL * 1024LL * 1024LL;
    if (available < total_bytes + reserve) {
        g_set_error(error, MS_ERROR, 13,
                    "Not enough free space. Keep at least the card size plus 1 GB available.");
        g_ptr_array_free(media, TRUE);
        g_free(destination);
        return NULL;
    }

    ensure_destination_folders(destination, media);

    TransferSession *session = ms_session_new();
    session->started_utc = time(NULL);
    session->source_root = g_strdup(card->root_path);
    session->source_label = g_strdup(card->volume_label);
    session->source_volume_serial = card->volume_serial;
    session->destination_root = g_strdup(destination);
    session->total_files = (int) media->len;
    session->total_bytes = total_bytes;

    long long processed_bytes = 0;
    int completed_files = 0;

    for (guint index = 0; index < media->len; index++) {
        if (cancelled != NULL && *cancelled) {
            g_set_error(error, MS_ERROR, 10, "Transfer cancelled.");
            break;
        }

        MediaItem *item = g_ptr_array_index(media, index);
        char *folder = ms_path_join(destination, ms_destination_folder(item->kind));
        if (group_by_date) {
            char *dated = ms_path_join(folder, date_folder(item));
            g_free(folder);
            folder = dated;
        }

        GError *folder_error = NULL;
        if (!ms_ensure_no_links(folder, &folder_error)) {
            g_propagate_error(error, folder_error);
            g_free(folder);
            break;
        }
        g_mkdir_with_parents(folder, 0755);

        char *destination_path = ms_path_join(folder, item->file_name);
        GError *link_error = NULL;
        if (!ms_ensure_no_links(destination_path, &link_error)) {
            g_propagate_error(error, link_error);
            g_free(destination_path);
            g_free(folder);
            break;
        }

        char *hash = NULL;
        gboolean skipped = FALSE;

        struct stat info;
        if (stat(destination_path, &info) == 0 && (long long) info.st_size == item->size) {
            report(progress, user_data, PHASE_CHECKING_DUPLICATE, item->file_name, completed_files,
                   (int) media->len, processed_bytes, total_bytes, session->copied_count,
                   session->skipped_count, item->source_path,
                   ms_relative_destination_folder(session->destination_root, destination_path));

            GError *hash_error = NULL;
            char *source_hash = ms_sha256_file(item->source_path, &hash_error);
            char *destination_hash = source_hash != NULL ? ms_sha256_file(destination_path, &hash_error) : NULL;

            if (source_hash != NULL && destination_hash != NULL &&
                g_ascii_strcasecmp(source_hash, destination_hash) == 0) {
                hash = g_strdup(source_hash);
                skipped = TRUE;
                session->skipped_count++;
                processed_bytes += item->size;

                char *message = g_strdup_printf("Verified existing %s", item->file_name);
                ms_logger_write(logger, message, NULL);
                g_free(message);
            } else {
                char *collision = unique_path(folder, item->file_name);
                hash = copy_and_verify(logger, item, collision, (int) media->len, completed_files,
                                       total_bytes, &processed_bytes, session, progress, user_data,
                                       cancelled, error);
                if (hash != NULL) {
                    g_free(destination_path);
                    destination_path = collision;
                } else {
                    g_free(collision);
                }
            }

            g_free(source_hash);
            g_free(destination_hash);
            g_clear_error(&hash_error);
        } else {
            char *target = g_file_test(destination_path, G_FILE_TEST_EXISTS)
                ? unique_path(folder, item->file_name)
                : g_strdup(destination_path);

            hash = copy_and_verify(logger, item, target, (int) media->len, completed_files,
                                   total_bytes, &processed_bytes, session, progress, user_data,
                                   cancelled, error);

            if (hash != NULL && g_strcmp0(target, destination_path) != 0) {
                /* A collision was published under a different name; record that one. */
                g_free(destination_path);
                destination_path = target;
            } else {
                g_free(target);
            }
        }

        if (hash == NULL) {
            g_free(destination_path);
            g_free(folder);
            break;
        }

        if (!skipped) {
            session->copied_count++;
        }
        completed_files++;

        report(progress, user_data, PHASE_VERIFYING, item->file_name, completed_files, (int) media->len,
               processed_bytes, total_bytes, session->copied_count, session->skipped_count,
               item->source_path, ms_relative_destination_folder(session->destination_root, destination_path));

        TransferRecord *record = g_new0(TransferRecord, 1);
        record->source_path = g_strdup(item->source_path);
        record->destination_path = g_strdup(destination_path);
        record->sha256 = g_strdup(hash);
        record->size = item->size;
        record->kind = item->kind;
        g_ptr_array_add(session->files, record);

        g_free(hash);
        g_free(destination_path);
        g_free(folder);
    }

    g_ptr_array_free(media, TRUE);
    g_free(destination);

    if (error_started(error)) {
        ms_session_free(session);
        return NULL;
    }

    g_free(session->status);
    session->status = g_strdup("Verified");
    session->completed_utc = time(NULL);

    char *session_file = ms_save_session(store, session, error);
    if (session_file == NULL) {
        ms_session_free(session);
        return NULL;
    }

    char *message = g_strdup_printf("Transfer verified: %d copied, %d already safe",
                                    session->copied_count, session->skipped_count);
    ms_logger_write(logger, message, NULL);
    g_free(message);

    report(progress, user_data, PHASE_COMPLETE, "Transfer verified",
           session->total_files, session->total_files, session->total_bytes, session->total_bytes,
           session->copied_count, session->skipped_count, NULL, NULL);

    TransferResult *result = g_new0(TransferResult, 1);
    result->session = session;
    result->session_file_path = session_file;
    return result;
}
