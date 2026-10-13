/* State store — settings and session records.
 *
 * The JSON shape matches what the Windows and macOS apps write (PascalCase keys,
 * indented, ISO-8601 timestamps, enum names as strings), so a state folder moved
 * between platforms still reads. Writes go through a temp file and a rename, which
 * is what keeps a session record from being half-written when a transfer is killed.
 */
#include "ms_core.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static char *iso8601_utc(time_t when)
{
    if (when == 0) {
        return g_strdup("null");
    }
    struct tm broken;
    gmtime_r(&when, &broken);
    return g_strdup_printf("\"%04d-%02d-%02dT%02d:%02d:%02d+00:00\"",
                           broken.tm_year + 1900, broken.tm_mon + 1, broken.tm_mday,
                           broken.tm_hour, broken.tm_min, broken.tm_sec);
}

static void write_escaped(GString *out, const char *value)
{
    g_string_append_c(out, '"');
    for (const char *p = value; *p != '\0'; p++) {
        switch (*p) {
            case '"': g_string_append(out, "\\\""); break;
            case '\\': g_string_append(out, "\\\\"); break;
            case '\n': g_string_append(out, "\\n"); break;
            case '\r': g_string_append(out, "\\r"); break;
            case '\t': g_string_append(out, "\\t"); break;
            default:
                if ((unsigned char) *p < 0x20) {
                    g_string_append_printf(out, "\\u%04x", (unsigned char) *p);
                } else {
                    g_string_append_c(out, *p);
                }
        }
    }
    g_string_append_c(out, '"');
}

static char *session_json(TransferSession *session)
{
    GString *out = g_string_new("{\n");

    g_string_append_printf(out, "  \"SessionId\": ");
    write_escaped(out, session->session_id);
    g_string_append(out, ",\n");

    g_string_append_printf(out, "  \"StartedUtc\": %s,\n", iso8601_utc(session->started_utc));
    g_string_append_printf(out, "  \"CompletedUtc\": %s,\n", iso8601_utc(session->completed_utc));
    g_string_append_printf(out, "  \"ErasedUtc\": %s,\n", iso8601_utc(session->erased_utc));

    g_string_append(out, "  \"Status\": ");
    write_escaped(out, session->status);
    g_string_append(out, ",\n");

    g_string_append(out, "  \"SourceRoot\": ");
    write_escaped(out, session->source_root);
    g_string_append(out, ",\n");

    g_string_append(out, "  \"SourceLabel\": ");
    write_escaped(out, session->source_label);
    g_string_append(out, ",\n");

    g_string_append_printf(out, "  \"SourceVolumeSerial\": %u,\n", session->source_volume_serial);

    g_string_append(out, "  \"DestinationRoot\": ");
    write_escaped(out, session->destination_root);
    g_string_append(out, ",\n");

    g_string_append_printf(out, "  \"TotalFiles\": %d,\n", session->total_files);
    g_string_append_printf(out, "  \"TotalBytes\": %lld,\n", session->total_bytes);
    g_string_append_printf(out, "  \"CopiedCount\": %d,\n", session->copied_count);
    g_string_append_printf(out, "  \"SkippedCount\": %d,\n", session->skipped_count);
    g_string_append_printf(out, "  \"ErasedFileCount\": %d,\n", session->erased_file_count);

    g_string_append(out, "  \"Files\": [");
    for (guint index = 0; index < session->files->len; index++) {
        TransferRecord *record = g_ptr_array_index(session->files, index);
        g_string_append_printf(out, "%s\n    {", index == 0 ? "\n" : ",");
        g_string_append(out, "      \"SourcePath\": ");
        write_escaped(out, record->source_path);
        g_string_append(out, ",\n      \"DestinationPath\": ");
        write_escaped(out, record->destination_path);
        g_string_append(out, ",\n      \"Sha256\": ");
        write_escaped(out, record->sha256);
        g_string_append_printf(out, ",\n      \"Size\": %lld,\n", record->size);
        g_string_append(out, "      \"Kind\": ");
        write_escaped(out, ms_kind_name(record->kind));
        g_string_append_printf(out, "\n    }");
    }
    g_string_append_printf(out, "%s\n  ]\n}", session->files->len == 0 ? "" : "\n");

    return g_string_free(out, FALSE);
}

static char *settings_json(AppSettings *settings)
{
    GString *out = g_string_new("{\n");
    g_string_append_printf(out, "  \"AutoTransfer\": %s,\n", settings->auto_transfer ? "true" : "false");
    g_string_append_printf(out, "  \"GroupByDate\": %s,\n", settings->group_by_date ? "true" : "false");
    g_string_append_printf(out, "  \"ShowNotifications\": %s,\n", settings->show_notifications ? "true" : "false");
    g_string_append_printf(out, "  \"ShowActivityLog\": %s,\n", settings->show_activity_log ? "true" : "false");
    g_string_append(out, "  \"DestinationRoot\": ");
    write_escaped(out, settings->destination_root);
    g_string_append(out, ",\n  \"Theme\": ");
    write_escaped(out, settings->theme);
    g_string_append(out, "\n}");
    return g_string_free(out, FALSE);
}

static gboolean save_atomic(const char *path, const char *contents, GError **error)
{
    char *directory = g_path_get_dirname(path);
    if (g_mkdir_with_parents(directory, 0755) != 0) {
        g_set_error(error, MS_ERROR, 4, "Could not create %s.", directory);
        g_free(directory);
        return FALSE;
    }
    g_free(directory);

    char *temporary = g_strdup_printf("%s.tmp-%08x%08x%08x%08x", path,
                                      g_random_int(), g_random_int(), g_random_int(), g_random_int());

    int fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    if (fd < 0) {
        g_set_error(error, MS_ERROR, 4, "Could not write %s.", temporary);
        g_free(temporary);
        return FALSE;
    }

    ssize_t written = write(fd, contents, strlen(contents));
    fsync(fd);
    close(fd);

    if (written < 0 || rename(temporary, path) != 0) {
        g_set_error(error, MS_ERROR, 4, "Could not save %s.", path);
        unlink(temporary);
        g_free(temporary);
        return FALSE;
    }

    g_free(temporary);
    return TRUE;
}

StateStore *ms_state_store_new(const char *root_path)
{
    StateStore *store = g_new0(StateStore, 1);
    store->root_path = ms_path_full(root_path);
    store->sessions_path = ms_path_join(store->root_path, "sessions");
    store->settings_path = ms_path_join(store->root_path, "settings.json");
    g_mkdir_with_parents(store->sessions_path, 0755);
    return store;
}

void ms_state_store_free(StateStore *store)
{
    if (store == NULL) {
        return;
    }
    g_free(store->root_path);
    g_free(store->sessions_path);
    g_free(store->settings_path);
    g_free(store);
}

char *ms_session_file_path(StateStore *store, TransferSession *session)
{
    struct tm broken;
    gmtime_r(&session->started_utc, &broken);
    return g_strdup_printf("%s/%04d%02d%02d-%02d%02d%02d-%s.json",
                           store->sessions_path,
                           broken.tm_year + 1900, broken.tm_mon + 1, broken.tm_mday,
                           broken.tm_hour, broken.tm_min, broken.tm_sec,
                           (session->session_id != NULL && strlen(session->session_id) >= 6)
                               ? session->session_id
                               : "000000");
}

char *ms_save_session(StateStore *store, TransferSession *session, GError **error)
{
    char *path = ms_session_file_path(store, session);
    char *json = session_json(session);
    if (!save_atomic(path, json, error)) {
        g_free(json);
        g_free(path);
        return NULL;
    }
    g_free(json);
    return path;
}

gboolean ms_settings_save(StateStore *store, AppSettings *settings, GError **error)
{
    char *json = settings_json(settings);
    gboolean saved = save_atomic(store->settings_path, json, error);
    g_free(json);
    return saved;
}

/* Minimal JSON reader: enough to read back the settings and session documents this
 * app writes, and tolerant of the Windows app's formatting. */
static const char *skip_ws(const char *p)
{
    while (*p == ' ' || *p == '\n' || *p == '\t' || *p == '\r') {
        p++;
    }
    return p;
}

static const char *read_string(const char *p, char **out)
{
    p = skip_ws(p);
    if (*p != '"') {
        return NULL;
    }
    p++;
    GString *value = g_string_new(NULL);
    while (*p != '\0' && *p != '"') {
        if (*p == '\\') {
            p++;
            switch (*p) {
                case 'n': g_string_append_c(value, '\n'); break;
                case 'r': g_string_append_c(value, '\r'); break;
                case 't': g_string_append_c(value, '\t'); break;
                case 'u': p += 4; break;
                default: g_string_append_c(value, *p);
            }
            p++;
            continue;
        }
        g_string_append_c(value, *p);
        p++;
    }
    if (*p != '"') {
        g_string_free(value, TRUE);
        return NULL;
    }
    *out = g_string_free(value, FALSE);
    return p + 1;
}

static time_t parse_iso8601(const char *value)
{
    int year, month, day, hour, minute, second;
    if (sscanf(value, "%d-%d-%dT%d:%d:%d", &year, &month, &day, &hour, &minute, &second) != 6) {
        return 0;
    }
    struct tm broken = {0};
    broken.tm_year = year - 1900;
    broken.tm_mon = month - 1;
    broken.tm_mday = day;
    broken.tm_hour = hour;
    broken.tm_min = minute;
    broken.tm_sec = second;
    return timegm(&broken);
}

AppSettings *ms_settings_load(StateStore *store)
{
    AppSettings *settings = g_new0(AppSettings, 1);
    settings->show_notifications = TRUE;
    settings->show_activity_log = TRUE;
    settings->theme = g_strdup("System");
    settings->destination_root = g_strdup("");

    char *contents = NULL;
    if (!g_file_get_contents(store->settings_path, &contents, NULL, NULL)) {
        return settings;
    }

    const char *p = contents;
    p = skip_ws(p);
    if (*p == '{') {
        p++;
    }
    while (*p != '\0') {
        p = skip_ws(p);
        if (*p == '}') {
            break;
        }
        if (*p != '"') {
            break;
        }
        char *key = NULL;
        p = read_string(p, &key);
        if (p == NULL || key == NULL) {
            break;
        }
        p = skip_ws(p);
        if (*p != ':') {
            g_free(key);
            break;
        }
        p = skip_ws(p + 1);

        if (*p == 't' || *p == 'f') {
            gboolean value = (*p == 't');
            p = (*p == 't') ? (p + 4) : (p + 5);
            if (g_strcmp0(key, "AutoTransfer") == 0) settings->auto_transfer = value;
            else if (g_strcmp0(key, "GroupByDate") == 0) settings->group_by_date = value;
            else if (g_strcmp0(key, "ShowNotifications") == 0) settings->show_notifications = value;
            else if (g_strcmp0(key, "ShowActivityLog") == 0) settings->show_activity_log = value;
        } else if (*p == '"') {
            char *value = NULL;
            p = read_string(p, &value);
            if (value == NULL) {
                g_free(key);
                break;
            }
            if (g_strcmp0(key, "DestinationRoot") == 0) {
                g_free(settings->destination_root);
                settings->destination_root = value;
            } else if (g_strcmp0(key, "Theme") == 0) {
                g_free(settings->theme);
                settings->theme = value;
            } else {
                g_free(value);
            }
        }
        g_free(key);

        p = skip_ws(p);
        if (*p == ',') {
            p++;
        } else {
            break;
        }
    }

    g_free(contents);
    return settings;
}

/* Read one session document. Returns NULL when the document is unreadable so the
 * caller can keep walking the sessions folder. */
TransferSession *ms_parse_session(const char *contents);

TransferSession *ms_load_latest_verified_for_card(StateStore *store, CardInfo *card)
{
    GPtrArray *files = g_ptr_array_new_with_free_func(g_free);
    GDir *directory = g_dir_open(store->sessions_path, 0, NULL);
    if (directory == NULL) {
        g_ptr_array_free(files, TRUE);
        return NULL;
    }

    const char *name;
    while ((name = g_dir_read_name(directory)) != NULL) {
        if (!g_str_has_suffix(name, ".json")) {
            continue;
        }
        g_ptr_array_add(files, ms_path_join(store->sessions_path, name));
    }
    g_dir_close(directory);

    /* Order by modification time, newest first, matching the Windows store. */
    for (guint i = 0; i < files->len; i++) {
        for (guint j = i + 1; j < files->len; j++) {
            struct stat a, b;
            if (stat((char *) files->pdata[i], &a) != 0 || stat((char *) files->pdata[j], &b) != 0) {
                continue;
            }
            if (b.st_mtime > a.st_mtime) {
                char *swap = files->pdata[i];
                files->pdata[i] = files->pdata[j];
                files->pdata[j] = swap;
            }
        }
    }

    TransferSession *result = NULL;
    for (guint index = 0; index < files->len; index++) {
        char *contents = NULL;
        if (!g_file_get_contents((char *) files->pdata[index], &contents, NULL, NULL)) {
            continue;
        }

        TransferSession *session = ms_parse_session(contents);
        g_free(contents);
        if (session == NULL) {
            continue;
        }

        char *session_root = ms_path_trim_separator(ms_path_full(session->source_root));
        char *card_root = ms_path_trim_separator(ms_path_full(card->root_path));
        gboolean same_root = strcmp(session_root, card_root) == 0;
        g_free(session_root);
        g_free(card_root);

        if (!same_root || (session->source_volume_serial != 0 && card->volume_serial != 0 &&
                           session->source_volume_serial != card->volume_serial)) {
            ms_session_free(session);
            continue;
        }

        if (g_ascii_strcasecmp(session->status, "Verified") == 0 && session->files->len > 0) {
            result = session;
        } else {
            ms_session_free(session);
        }
        break;
    }

    g_ptr_array_free(files, TRUE);
    return result;
}

/* --- minimal JSON value model, enough to read back what this app writes --- */

typedef enum { JSON_NULL, JSON_BOOL, JSON_STRING, JSON_NUMBER, JSON_ARRAY, JSON_OBJECT } JsonType;

typedef struct {
    JsonType type;
    char *string;
    double number;
    gboolean boolean;
    GHashTable *object;   /* char* key -> JsonValue* */
    GPtrArray *array;     /* JsonValue* */
} JsonValue;

static void json_value_free(JsonValue *value)
{
    if (value == NULL) {
        return;
    }
    g_free(value->string);
    if (value->object != NULL) {
        g_hash_table_destroy(value->object);
    }
    if (value->array != NULL) {
        g_ptr_array_free(value->array, TRUE);
    }
    g_free(value);
}

static const char *parse_value(const char *p, JsonValue **out);

static const char *parse_object(const char *p, JsonValue **out)
{
    JsonValue *value = g_new0(JsonValue, 1);
    value->type = JSON_OBJECT;
    value->object = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, (GFreeFunc) json_value_free);

    p = skip_ws(p);
    if (*p != '{') {
        json_value_free(value);
        return NULL;
    }
    p = skip_ws(p + 1);
    if (*p == '}') {
        *out = value;
        return p + 1;
    }

    for (;;) {
        char *key = NULL;
        p = read_string(p, &key);
        if (key == NULL) {
            json_value_free(value);
            return NULL;
        }
        p = skip_ws(p);
        if (*p != ':') {
            g_free(key);
            json_value_free(value);
            return NULL;
        }
        JsonValue *child = NULL;
        p = parse_value(skip_ws(p + 1), &child);
        if (child == NULL) {
            g_free(key);
            json_value_free(value);
            return NULL;
        }
        g_hash_table_insert(value->object, key, child);

        p = skip_ws(p);
        if (*p == ',') {
            p = skip_ws(p + 1);
            continue;
        }
        if (*p == '}') {
            *out = value;
            return p + 1;
        }
        json_value_free(value);
        return NULL;
    }
}

static const char *parse_array(const char *p, JsonValue **out)
{
    JsonValue *value = g_new0(JsonValue, 1);
    value->type = JSON_ARRAY;
    value->array = g_ptr_array_new_with_free_func((GFreeFunc) json_value_free);

    p = skip_ws(p);
    if (*p != '[') {
        json_value_free(value);
        return NULL;
    }
    p = skip_ws(p + 1);
    if (*p == ']') {
        *out = value;
        return p + 1;
    }

    for (;;) {
        JsonValue *child = NULL;
        p = parse_value(skip_ws(p), &child);
        if (child == NULL) {
            json_value_free(value);
            return NULL;
        }
        g_ptr_array_add(value->array, child);

        p = skip_ws(p);
        if (*p == ',') {
            p = skip_ws(p + 1);
            continue;
        }
        if (*p == ']') {
            *out = value;
            return p + 1;
        }
        json_value_free(value);
        return NULL;
    }
}

static const char *parse_value(const char *p, JsonValue **out)
{
    p = skip_ws(p);
    JsonValue *value = g_new0(JsonValue, 1);

    switch (*p) {
        case '{':
            return parse_object(p, out);
        case '[':
            return parse_array(p, out);
        case '"': {
            char *string = NULL;
            const char *end = read_string(p, &string);
            if (end == NULL) {
                json_value_free(value);
                return NULL;
            }
            value->type = JSON_STRING;
            value->string = string;
            *out = value;
            return end;
        }
        case 't':
            value->type = JSON_BOOL;
            value->boolean = TRUE;
            *out = value;
            return p + 4;
        case 'f':
            value->type = JSON_BOOL;
            value->boolean = FALSE;
            *out = value;
            return p + 5;
        case 'n':
            value->type = JSON_NULL;
            *out = value;
            return p + 4;
        default: {
            char *end = NULL;
            double number = g_ascii_strtod(p, &end);
            if (end == p) {
                json_value_free(value);
                return NULL;
            }
            value->type = JSON_NUMBER;
            value->number = number;
            *out = value;
            return end;
        }
    }
}

const char *ms_kind_name(MediaKind kind)
{
    switch (kind) {
        case MEDIA_RAW: return "Raw";
        case MEDIA_OTHER_PHOTO: return "OtherPhoto";
        case MEDIA_VIDEO: return "Video";
        case MEDIA_JPEG:
        default: return "Jpeg";
    }
}

MediaKind ms_kind_from_name(const char *name)
{
    if (g_strcmp0(name, "Raw") == 0) return MEDIA_RAW;
    if (g_strcmp0(name, "OtherPhoto") == 0) return MEDIA_OTHER_PHOTO;
    if (g_strcmp0(name, "Video") == 0) return MEDIA_VIDEO;
    return MEDIA_JPEG;
}

static JsonValue *json_obj_get(JsonValue *obj, const char *key)
{
    if (obj == NULL || obj->type != JSON_OBJECT || obj->object == NULL) {
        return NULL;
    }
    return g_hash_table_lookup(obj->object, key);
}

static char *json_string_value(JsonValue *object, const char *key)
{
    JsonValue *value = json_obj_get(object, key);
    if (value == NULL || value->type != JSON_STRING || value->string == NULL) {
        return g_strdup("");
    }
    return g_strdup(value->string);
}

TransferSession *ms_parse_session(const char *contents)
{
    JsonValue *root = NULL;
    if (parse_value(contents, &root) == NULL || root == NULL || root->type != JSON_OBJECT) {
        json_value_free(root);
        return NULL;
    }

    TransferSession *session = ms_session_new();
    g_free(session->session_id);
    session->session_id = json_string_value(root, "SessionId");
    g_free(session->status);
    session->status = json_string_value(root, "Status");
    g_free(session->source_root);
    session->source_root = json_string_value(root, "SourceRoot");
    g_free(session->source_label);
    session->source_label = json_string_value(root, "SourceLabel");
    g_free(session->destination_root);
    session->destination_root = json_string_value(root, "DestinationRoot");

    JsonValue *started = json_obj_get(root, "StartedUtc");
    if (started != NULL && started->type == JSON_STRING) {
        session->started_utc = parse_iso8601(started->string);
    }
    JsonValue *completed = json_obj_get(root, "CompletedUtc");
    if (completed != NULL && completed->type == JSON_STRING) {
        session->completed_utc = parse_iso8601(completed->string);
    }
    JsonValue *erased = json_obj_get(root, "ErasedUtc");
    if (erased != NULL && erased->type == JSON_STRING) {
        session->erased_utc = parse_iso8601(erased->string);
    }

    JsonValue *serial = json_obj_get(root, "SourceVolumeSerial");
    if (serial != NULL && serial->type == JSON_NUMBER) {
        session->source_volume_serial = (guint32) serial->number;
    }
    JsonValue *total_files = json_obj_get(root, "TotalFiles");
    if (total_files != NULL && total_files->type == JSON_NUMBER) {
        session->total_files = (int) total_files->number;
    }
    JsonValue *total_bytes = json_obj_get(root, "TotalBytes");
    if (total_bytes != NULL && total_bytes->type == JSON_NUMBER) {
        session->total_bytes = (long long) total_bytes->number;
    }
    JsonValue *copied = json_obj_get(root, "CopiedCount");
    if (copied != NULL && copied->type == JSON_NUMBER) {
        session->copied_count = (int) copied->number;
    }
    JsonValue *skipped = json_obj_get(root, "SkippedCount");
    if (skipped != NULL && skipped->type == JSON_NUMBER) {
        session->skipped_count = (int) skipped->number;
    }
    JsonValue *erased_count = json_obj_get(root, "ErasedFileCount");
    if (erased_count != NULL && erased_count->type == JSON_NUMBER) {
        session->erased_file_count = (int) erased_count->number;
    }

    JsonValue *files = json_obj_get(root, "Files");
    if (files != NULL && files->type == JSON_ARRAY) {
        for (guint index = 0; index < files->array->len; index++) {
            JsonValue *record = g_ptr_array_index(files->array, index);
            if (record == NULL || record->type != JSON_OBJECT) {
                continue;
            }

            TransferRecord *entry = g_new0(TransferRecord, 1);
            entry->source_path = json_string_value(record, "SourcePath");
            entry->destination_path = json_string_value(record, "DestinationPath");
            entry->sha256 = json_string_value(record, "Sha256");
            JsonValue *size = json_obj_get(record, "Size");
            entry->size = (size != NULL && size->type == JSON_NUMBER) ? (long long) size->number : 0;
            char *kind_str = json_string_value(record, "Kind");
            entry->kind = ms_kind_from_name(kind_str);
            g_free(kind_str);
            g_ptr_array_add(session->files, entry);
        }
    }

    json_value_free(root);
    return session;
}
