#include "ms_core.h"

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static gboolean error_started(GError **error)
{
    return error != NULL && *error != NULL;
}

static void validate_session(CardInfo *card, TransferSession *session, GError **error)
{
    if (session->files->len == 0) {
        g_set_error(error, MS_ERROR, 14, "Erase requires a verified transfer containing media files.");
        return;
    }
    if (g_ascii_strcasecmp(session->status, "Verified") != 0) {
        g_set_error(error, MS_ERROR, 14, "Erase is available only after a completed verified transfer.");
        return;
    }

    char *session_root = ms_path_trim_separator(ms_path_full(session->source_root));
    char *card_root = ms_path_trim_separator(ms_path_full(card->root_path));
    gboolean same = strcmp(session_root, card_root) == 0;
    g_free(session_root);
    g_free(card_root);

    if (!same) {
        g_set_error(error, MS_ERROR, 14, "The connected card does not match the verified transfer.");
        return;
    }

    if (session->source_volume_serial != 0 && card->volume_serial != 0 &&
        session->source_volume_serial != card->volume_serial) {
        g_set_error(error, MS_ERROR, 14, "The card volume ID does not match the verified transfer.");
        return;
    }
}

static void ensure_safe_child(const char *candidate, const char *root, GError **error)
{
    char *normalized_root = ms_path_trim_separator(ms_path_full(root));
    char *with_separator = g_strdup_printf("%s/", normalized_root);
    char *normalized_candidate = ms_path_full(candidate);

    if (!g_str_has_prefix(normalized_candidate, with_separator)) {
        g_set_error(error, MS_ERROR, 15, "Safety check rejected a path outside the selected card.");
    }

    g_free(normalized_root);
    g_free(with_separator);
    g_free(normalized_candidate);
}

static void delete_file_with_retry(const char *path, GError **error)
{
    for (int attempt = 0; attempt < 3; attempt++) {
        if (unlink(path) == 0) {
            return;
        }
        if (errno == ENOENT) {
            return;
        }
        g_usleep(100 * (attempt + 1) * 1000);
    }

    g_set_error(error, MS_ERROR, 16, "Could not delete %s.", ms_path_filename(path));
}

static int delete_entry(const char *path, const char *root, volatile gboolean *cancelled, GError **error)
{
    if (cancelled != NULL && *cancelled) {
        return 0;
    }

    ensure_safe_child(path, root, error);
    if (error_started(error)) {
        return 0;
    }

    struct stat info;
    if (lstat(path, &info) != 0) {
        return 0;
    }

    if (S_ISLNK(info.st_mode)) {
        unlink(path);
        return 0;
    }

    if (!S_ISDIR(info.st_mode)) {
        delete_file_with_retry(path, error);
        return error_started(error) ? 0 : 1;
    }

    int deleted = 0;
    DIR *handle = opendir(path);
    if (handle == NULL) {
        return 0;
    }

    struct dirent *entry;
    while ((entry = readdir(handle)) != NULL) {
        if (g_strcmp0(entry->d_name, ".") == 0 || g_strcmp0(entry->d_name, "..") == 0) {
            continue;
        }
        char *child = ms_path_join(path, entry->d_name);
        deleted += delete_entry(child, root, cancelled, error);
        g_free(child);
        if (error_started(error)) {
            break;
        }
    }
    closedir(handle);

    if (error_started(error)) {
        return deleted;
    }

    if (rmdir(path) != 0 && errno != ENOENT) {
        g_set_error(error, MS_ERROR, 16, "Could not remove %s.", ms_path_filename(path));
    }

    return deleted;
}

static void collect_entries(const char *path, GPtrArray *out)
{
    DIR *handle = opendir(path);
    if (handle == NULL) {
        return;
    }
    struct dirent *entry;
    while ((entry = readdir(handle)) != NULL) {
        if (g_strcmp0(entry->d_name, ".") == 0 || g_strcmp0(entry->d_name, "..") == 0) {
            continue;
        }
        g_ptr_array_add(out, ms_path_join(path, entry->d_name));
    }
    closedir(handle);
}

static void report(ProgressCallback progress, void *user_data, OperationPhase phase,
                   const char *current_item, int completed, int total,
                   long long processed, long long total_bytes,
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
    p.current_source_path = (char *) source_path;
    p.current_destination_folder = (char *) destination_folder;
    progress(&p, user_data);
}

WipeResult *ms_wipe(
    StateStore *store,
    AppLogger *logger,
    CardInfo *card,
    TransferSession *session,
    ProgressCallback progress,
    void *user_data,
    volatile gboolean *cancelled,
    GError **error)
{
    validate_session(card, session, error);
    if (error_started(error)) {
        return NULL;
    }

    if (g_strcmp0(card->drive_type, "Selected folder") == 0) {
        g_set_error(error, MS_ERROR, 17, "Erase is restricted to camera-card volumes, not selected folders.");
        return NULL;
    }

    if (!ms_ensure_no_links(card->root_path, error)) {
        return NULL;
    }
    if (!ms_ensure_destination_outside_source(session->destination_root, card->root_path, error)) {
        return NULL;
    }

    char *root = ms_path_full(card->root_path);
    if (!g_file_test(root, G_FILE_TEST_IS_DIR)) {
        g_set_error(error, MS_ERROR, 18, "The verified card is no longer connected.");
        g_free(root);
        return NULL;
    }

    /* A transfer only copies files the classifier recognises as camera media, so any
     * other user content on the card has no destination copy to verify against.
     * Deleting it anyway would lose it permanently, so fail closed. */
    CardScan *scan = ms_scan_card(root);
    if (scan->unverifiable->len > 0) {
        GString *names = g_string_new(NULL);
        guint shown = scan->unverifiable->len < 5 ? scan->unverifiable->len : 5;
        for (guint index = 0; index < shown; index++) {
            if (index > 0) {
                g_string_append(names, ", ");
            }
            g_string_append(names, ms_path_filename((char *) scan->unverifiable->pdata[index]));
        }
        g_set_error(error, MS_ERROR, 19,
                    "Erase blocked: %u file(s) on this card are not recognised camera media, "
                    "so no verified copy exists for them: %s. "
                    "Copy them off the card yourself before erasing.",
                    scan->unverifiable->len, names->str);
        g_string_free(names, TRUE);
        ms_card_scan_free(scan);
        g_free(root);
        return NULL;
    }

    GHashTable *records = g_hash_table_new_full(g_str_hash, g_str_equal, NULL, NULL);
    for (guint index = 0; index < session->files->len; index++) {
        TransferRecord *record = g_ptr_array_index(session->files, index);
        g_hash_table_insert(records, ms_path_full(record->source_path), record);
    }

    long long total_bytes = 0;
    for (guint index = 0; index < scan->media->len; index++) {
        total_bytes += ((MediaItem *) scan->media->pdata[index])->size;
    }

    long long processed_bytes = 0;
    int verified_files = 0;

    ms_logger_write(logger, "Re-verifying all remaining card media before erase", NULL);

    for (guint index = 0; index < scan->media->len; index++) {
        if (cancelled != NULL && *cancelled) {
            g_set_error(error, MS_ERROR, 10, "Erase cancelled.");
            break;
        }

        MediaItem *item = g_ptr_array_index(scan->media, index);
        TransferRecord *record = g_hash_table_lookup(records, ms_path_full(item->source_path));
        if (record == NULL) {
            g_set_error(error, MS_ERROR, 20,
                        "Erase blocked: %s was not part of the verified transfer. "
                        "Transfer the card again first.", item->file_name);
            break;
        }

        /* Each of these says what to do about it. "The destination copy changed size"
         * on its own leaves erase locked with nothing the card's owner can act on, and
         * the answer is the same every time: transfer again. */
        if (!ms_ensure_destination_outside_source(record->destination_path, card->root_path, error)) {
            break;
        }

        struct stat info;
        if (stat(record->destination_path, &info) != 0) {
            g_set_error(error, MS_ERROR, 21,
                        "Erase blocked: the destination copy of %s is missing. "
                        "Transfer this card again to restore it, then erase.", item->file_name);
            break;
        }
        if ((long long) info.st_size != record->size) {
            g_set_error(error, MS_ERROR, 22,
                        "Erase blocked: the destination copy of %s is no longer the size it was "
                        "verified at. Transfer this card again to re-verify it, then erase.",
                        item->file_name);
            break;
        }

        char *destination_folder = ms_relative_destination_folder(session->destination_root, record->destination_path);
        report(progress, user_data, PHASE_REVERIFYING, item->file_name, verified_files,
               (int) scan->media->len, processed_bytes, total_bytes, item->source_path, destination_folder);
        g_free(destination_folder);

        GError *hash_error = NULL;
        char *source_hash = ms_sha256_file(item->source_path, &hash_error);
        char *destination_hash = source_hash != NULL ? ms_sha256_file(record->destination_path, &hash_error) : NULL;

        if (source_hash == NULL || destination_hash == NULL) {
            g_clear_error(&hash_error);
            g_free(source_hash);
            g_free(destination_hash);
            g_set_error(error, MS_ERROR, 23, "Erase blocked: %s could not be hashed.", item->file_name);
            break;
        }

        if (g_ascii_strcasecmp(source_hash, record->sha256) != 0 ||
            g_ascii_strcasecmp(destination_hash, record->sha256) != 0) {
            g_set_error(error, MS_ERROR, 23,
                        "Erase blocked: %s no longer matches its verified copy. "
                        "Transfer this card again to re-verify it, then erase.", item->file_name);
            g_free(source_hash);
            g_free(destination_hash);
            break;
        }

        g_free(source_hash);
        g_free(destination_hash);

        processed_bytes += item->size;
        verified_files++;
    }

    if (!error_started(error) && !ms_session_eligible_for_erase(session, card, scan->media)) {
        g_set_error(error, MS_ERROR, 24,
                    "Erase blocked: the card contents or destination copies changed. Transfer again first.");
    }

    g_hash_table_destroy(records);

    if (error_started(error)) {
        ms_card_scan_free(scan);
        g_free(root);
        return NULL;
    }

    GPtrArray *root_entries = g_ptr_array_new_with_free_func(g_free);
    collect_entries(root, root_entries);

    int total_user_entries = 0;
    for (guint index = 0; index < root_entries->len; index++) {
        if (!ms_is_windows_managed_root_entry((char *) root_entries->pdata[index])) {
            total_user_entries++;
        }
    }

    int completed_entries = 0;
    int deleted_files = 0;
    GPtrArray *failures = g_ptr_array_new_with_free_func(g_free);
    GPtrArray *protected_entries = g_ptr_array_new_with_free_func(g_free);

    for (guint index = 0; index < root_entries->len; index++) {
        if (cancelled != NULL && *cancelled) {
            g_set_error(error, MS_ERROR, 10, "Erase cancelled.");
            break;
        }

        char *entry = (char *) root_entries->pdata[index];
        if (ms_is_windows_managed_root_entry(entry)) {
            g_ptr_array_add(protected_entries,
                            g_strdup(ms_path_filename(ms_path_trim_separator(entry))));
            continue;
        }

        /* Deletion has no byte total to measure against, so progress is counted in
         * entries and the byte figures are left at zero. Reporting the entry count as
         * a byte count made the readouts show "12 B" and "0 MB/s avg" during an erase. */
        report(progress, user_data, PHASE_ERASING,
               ms_path_filename(ms_path_trim_separator(entry)), completed_entries,
               total_user_entries > 0 ? total_user_entries : 1, 0, 0, NULL, NULL);

        GError *delete_error = NULL;
        deleted_files += delete_entry(entry, root, cancelled, &delete_error);
        if (delete_error != NULL) {
            g_ptr_array_add(failures, g_strdup_printf("%s: %s", ms_path_filename(entry), delete_error->message));
            g_clear_error(&delete_error);
        }
        completed_entries++;
    }

    if (!error_started(error)) {
        GPtrArray *remaining = g_ptr_array_new_with_free_func(g_free);
        collect_entries(root, remaining);

        int remaining_user_entries = 0;
        GString *detail = g_string_new(NULL);
        for (guint index = 0; index < remaining->len; index++) {
            if (ms_is_windows_managed_root_entry((char *) remaining->pdata[index])) {
                continue;
            }
            remaining_user_entries++;
            if (detail->len < 200 && remaining_user_entries <= 5) {
                if (detail->len > 0) {
                    g_string_append(detail, ", ");
                }
                g_string_append(detail, ms_path_filename((char *) remaining->pdata[index]));
            }
        }

        GPtrArray *remaining_media = ms_scan_media(root);

        if (failures->len > 0 || remaining_user_entries > 0 || remaining_media->len > 0) {
            GString *message = g_string_new(NULL);
            if (failures->len > 0) {
                for (guint index = 0; index < failures->len && index < 5; index++) {
                    if (index > 0) {
                        g_string_append(message, "; ");
                    }
                    g_string_append(message, (char *) failures->pdata[index]);
                }
            } else {
                g_string_append(message, detail->str);
            }
            g_set_error(error, MS_ERROR, 25,
                        "The card could not be completely erased. Remaining content: %s. "
                        "Check the card's write-protect switch and close apps using the card, "
                        "then try again.", message->str);
            g_string_free(message, TRUE);
        }

        g_string_free(detail, TRUE);
        g_ptr_array_free(remaining_media, TRUE);
        g_ptr_array_free(remaining, TRUE);
    }

    ms_card_scan_free(scan);

    if (error_started(error)) {
        g_ptr_array_free(failures, TRUE);
        g_ptr_array_free(protected_entries, TRUE);
        g_ptr_array_free(root_entries, TRUE);
        g_free(root);
        return NULL;
    }

    g_free(session->status);
    session->status = g_strdup("Erased");
    session->erased_utc = time(NULL);
    session->erased_file_count = deleted_files;

    ms_save_session(store, session, error);

    char *message = g_strdup_printf(
        "Card erase complete: %d files removed; only volume-management folders may remain",
        deleted_files);
    ms_logger_write(logger, message, NULL);
    g_free(message);

    report(progress, user_data, PHASE_COMPLETE, "Card contents erased",
           total_user_entries > 0 ? total_user_entries : 1,
           total_user_entries > 0 ? total_user_entries : 1, 0, 0, NULL, NULL);

    WipeResult *result = g_new0(WipeResult, 1);
    result->deleted_files = deleted_files;
    result->protected_entries = protected_entries;

    g_ptr_array_free(failures, TRUE);
    g_ptr_array_free(root_entries, TRUE);
    g_free(root);
    return result;
}
