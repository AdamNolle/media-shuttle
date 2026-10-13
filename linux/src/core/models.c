#include "ms_core.h"

#include <sys/stat.h>

static char *random_hex32(void)
{
    guint8 bytes[16];
    for (int i = 0; i < 16; i++) {
        bytes[i] = (guint8) g_random_int_range(0, 256);
    }

    GString *hex = g_string_new(NULL);
    for (int i = 0; i < 16; i++) {
        g_string_append_printf(hex, "%02x", bytes[i]);
    }
    return g_string_free(hex, FALSE);
}

TransferSession *ms_session_new(void)
{
    TransferSession *session = g_new0(TransferSession, 1);
    session->session_id = random_hex32();
    session->status = g_strdup("In progress");
    session->files = g_ptr_array_new_with_free_func(g_free);
    return session;
}

void ms_session_free(TransferSession *session)
{
    if (session == NULL) {
        return;
    }
    g_free(session->session_id);
    g_free(session->status);
    g_free(session->source_root);
    g_free(session->source_label);
    g_free(session->destination_root);
    g_ptr_array_free(session->files, TRUE);
    g_free(session);
}

void ms_media_item_free(MediaItem *item)
{
    if (item == NULL) {
        return;
    }
    g_free(item->source_path);
    g_free(item->file_name);
    g_free(item->extension);
    g_free(item);
}

void ms_card_info_free(CardInfo *card)
{
    if (card == NULL) {
        return;
    }
    g_free(card->root_path);
    g_free(card->volume_label);
    g_free(card->drive_type);
    g_free(card);
}

void ms_card_scan_free(CardScan *scan)
{
    if (scan == NULL) {
        return;
    }
    g_ptr_array_free(scan->media, TRUE);
    g_ptr_array_free(scan->unverifiable, TRUE);
    g_free(scan);
}

void ms_settings_free(AppSettings *settings)
{
    if (settings == NULL) {
        return;
    }
    g_free(settings->destination_root);
    g_free(settings->theme);
    g_free(settings);
}

void ms_wipe_result_free(WipeResult *result)
{
    if (result == NULL) {
        return;
    }
    g_ptr_array_free(result->protected_entries, TRUE);
    g_free(result);
}

void ms_transfer_result_free(TransferResult *result)
{
    if (result == NULL) {
        return;
    }
    g_free(result->session_file_path);
    /* The session is owned by the caller when it was passed in, so only the
     * result wrapper is released here. */
    g_free(result);
}

/* Erase eligibility: the session must be the verified one for this exact volume,
 * every remaining card file must be in it, and every recorded destination copy must
 * still exist at the size it was verified at. */
gboolean ms_session_eligible_for_erase(TransferSession *session, CardInfo *card, GPtrArray *media)
{
    if (session == NULL || card == NULL || media == NULL) {
        return FALSE;
    }

    if (g_ascii_strcasecmp(session->status, "Verified") != 0) {
        return FALSE;
    }

    char *session_root = ms_path_trim_separator(ms_path_full(session->source_root));
    char *card_root = ms_path_trim_separator(ms_path_full(card->root_path));
    gboolean same_root = strcmp(session_root, card_root) == 0;
    g_free(session_root);
    g_free(card_root);

    if (!same_root || session->source_volume_serial != card->volume_serial) {
        return FALSE;
    }

    if (session->files->len == 0 || session->files->len != media->len) {
        return FALSE;
    }

    GHashTable *records = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    for (guint index = 0; index < session->files->len; index++) {
        TransferRecord *record = g_ptr_array_index(session->files, index);
        char *key = ms_path_full(record->source_path);
        if (g_hash_table_contains(records, key)) {
            g_free(key);
            g_hash_table_destroy(records);
            return FALSE;
        }
        g_hash_table_insert(records, key, record);
    }

    gboolean eligible = TRUE;
    for (guint index = 0; index < media->len && eligible; index++) {
        MediaItem *item = g_ptr_array_index(media, index);
        char *key = ms_path_full(item->source_path);
        TransferRecord *record = g_hash_table_lookup(records, key);
        g_free(key);

        if (record == NULL || record->size != item->size) {
            eligible = FALSE;
            break;
        }

        struct stat info;
        if (stat(record->destination_path, &info) != 0 || (long long) info.st_size != record->size) {
            eligible = FALSE;
            break;
        }

        GError *error = NULL;
        if (!ms_ensure_destination_outside_source(record->destination_path, card->root_path, &error)) {
            g_clear_error(&error);
            eligible = FALSE;
            break;
        }
    }

    g_hash_table_destroy(records);
    return eligible;
}
