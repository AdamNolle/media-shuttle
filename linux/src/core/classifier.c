#include "ms_core.h"

#include <dirent.h>
#include <sys/stat.h>

/* Anything a camera can write has to appear in one of these four sets. A format
 * missing here is not merely unsupported: the file is never copied, yet erase
 * would still delete it. Erase is guarded separately by the disposable set, so
 * the two lists must be read together.
 */
static GHashTable *raw_extensions;
static GHashTable *jpeg_extensions;
static GHashTable *other_photo_extensions;
static GHashTable *video_extensions;
static GHashTable *disposable_extensions;
static GHashTable *disposable_names;
static GHashTable *scan_excluded_directories;

static GHashTable *build_set(const char *const *values, guint count)
{
    GHashTable *set = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    for (guint index = 0; index < count; index++) {
        g_hash_table_add(set, g_ascii_strdown(values[index], -1));
    }
    return set;
}

#define SET(name, ...)                                                                    \
    {                                                                                     \
        static const char *const values[] = { __VA_ARGS__ };                              \
        name = build_set(values, G_N_ELEMENTS(values));                                   \
    }

static void ensure_sets(void)
{
    if (raw_extensions != NULL) {
        return;
    }

    SET(raw_extensions,
        ".arw", ".sr2", ".srf", ".dng", ".raw", ".cr2", ".cr3", ".crw", ".nef", ".nrw",
        ".raf", ".orf", ".rw2", ".rwl", ".pef", ".ptx", ".srw", ".x3f", ".3fr", ".fff",
        ".iiq", ".cap", ".eip", ".mef", ".mos", ".mrw", ".erf", ".dcr", ".kdc", ".k25",
        ".gpr", ".ari");

    SET(jpeg_extensions, ".jpg", ".jpeg", ".jpe");

    SET(other_photo_extensions,
        ".heif", ".heic", ".hif", ".avif", ".jxl", ".tif", ".tiff", ".png", ".bmp",
        ".gif", ".webp", ".jp2", ".j2k", ".psd");

    SET(video_extensions,
        ".mp4", ".m4v", ".mov", ".mxf", ".braw", ".r3d", ".mts", ".m2ts", ".m2t", ".ts",
        ".mod", ".tod", ".avi", ".mkv", ".webm", ".wmv", ".asf", ".mpg", ".mpeg", ".m2v",
        ".vob", ".3gp", ".3g2", ".insv", ".lrv", ".dv");

    /* Housekeeping a camera or an operating system writes for itself. Erase may
     * remove these without a verified destination copy; everything else on the
     * card blocks erase instead. */
    SET(disposable_extensions,
        ".thm", ".ctg", ".cpi", ".mpl", ".bdm", ".bdmv", ".clpi", ".mpls", ".inp", ".ind",
        ".int", ".tdt", ".tid", ".modd", ".moff", ".bnp", ".pmp", ".xml", ".xmp", ".dat",
        ".bin", ".db", ".ini", ".inf", ".log", ".txt", ".sec", ".info", ".mdt", ".osd",
        ".mtd", ".pck", ".fpr", ".set", ".sav", ".idx", ".map", ".tmp", ".bup", ".ifo");

    SET(disposable_names, ".ds_store", "thumbs.db", "desktop.ini", "autorun.inf");

    SET(scan_excluded_directories,
        "$recycle.bin", "system volume information", ".fseventsd", ".spotlight-v100",
        ".trashes");
}

gboolean ms_try_classify(const char *path, MediaKind *out_kind)
{
    ensure_sets();

    char *name = ms_path_filename(path);
    if (g_str_has_prefix(name, "._")) {
        g_free(name);
        if (out_kind != NULL) {
            *out_kind = MEDIA_JPEG;
        }
        return FALSE;
    }

    char *extension = g_ascii_strdown(strrchr(name, '.') != NULL ? strrchr(name, '.') : "", -1);

    if (g_hash_table_contains(raw_extensions, extension)) {
        *out_kind = MEDIA_RAW;
    } else if (g_hash_table_contains(jpeg_extensions, extension)) {
        *out_kind = MEDIA_JPEG;
    } else if (g_hash_table_contains(other_photo_extensions, extension)) {
        *out_kind = MEDIA_OTHER_PHOTO;
    } else if (g_hash_table_contains(video_extensions, extension)) {
        *out_kind = MEDIA_VIDEO;
    } else {
        g_free(name);
        g_free(extension);
        return FALSE;
    }

    g_free(name);
    g_free(extension);
    return TRUE;
}

gboolean ms_is_disposable_camera_artifact(const char *path)
{
    ensure_sets();

    char *name = ms_path_filename(path);
    char *lower = g_ascii_strdown(name, -1);

    gboolean disposable = g_str_has_prefix(lower, "._") || g_hash_table_contains(disposable_names, lower);
    if (!disposable) {
        char *extension = g_ascii_strdown(strrchr(name, '.') != NULL ? strrchr(name, '.') : "", -1);
        disposable = g_hash_table_contains(disposable_extensions, extension);
        g_free(extension);
    }

    g_free(name);
    g_free(lower);
    return disposable;
}

const char *ms_destination_folder(MediaKind kind)
{
    switch (kind) {
        case MEDIA_JPEG:
            return "Photos/JPEGs";
        case MEDIA_RAW:
            return "Photos/RAWs";
        case MEDIA_OTHER_PHOTO:
            return "Photos/Other";
        case MEDIA_VIDEO:
            return "Videos";
        default:
            return NULL;
    }
}

gboolean ms_is_windows_managed_root_entry(const char *path)
{
    char *name = ms_path_filename(path);
    gboolean managed = g_ascii_strcasecmp(name, "$RECYCLE.BIN") == 0 ||
                       g_ascii_strcasecmp(name, "System Volume Information") == 0;
    g_free(name);
    return managed;
}

static int compare_paths(gconstpointer left, gconstpointer right)
{
    return strcmp((const char *) left, (const char *) right);
}

/* Walks the card once and splits what it finds into media to copy and content
 * erase must never delete. Callers that need both use this rather than two walks —
 * a full card is tens of thousands of entries and the UI rescans every couple of
 * seconds. Nothing is skipped by attribute: cameras mark their databases hidden,
 * and erase has to account for every one of them.
 */
CardScan *ms_scan_card(const char *root_path)
{
    ensure_sets();

    CardScan *scan = g_new0(CardScan, 1);
    scan->media = g_ptr_array_new_with_free_func((GDestroyNotify) ms_media_item_free);
    scan->unverifiable = g_ptr_array_new_with_free_func(g_free);

    char *normalized_root = ms_path_trim_separator(ms_path_full(root_path));

    GPtrArray *pending = g_ptr_array_new_with_free_func(g_free);
    g_ptr_array_add(pending, g_strdup(normalized_root));

    while (pending->len > 0) {
        char *directory = g_ptr_array_steal_index(pending, pending->len - 1);

        DIR *handle = opendir(directory);
        if (handle == NULL) {
            g_free(directory);
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
                char *lower = g_ascii_strdown(entry->d_name, -1);
                gboolean excluded = g_strcmp0(directory, normalized_root) == 0 &&
                                    g_hash_table_contains(scan_excluded_directories, lower);
                g_free(lower);
                if (!excluded) {
                    g_ptr_array_add(pending, full);
                } else {
                    g_free(full);
                }
                continue;
            }

            if (!S_ISREG(info.st_mode)) {
                g_free(full);
                continue;
            }

            MediaKind kind;
            if (!ms_try_classify(full, &kind)) {
                if (!ms_is_disposable_camera_artifact(full)) {
                    g_ptr_array_add(scan->unverifiable, full);
                } else {
                    g_free(full);
                }
                continue;
            }

            MediaItem *item = g_new0(MediaItem, 1);
            item->source_path = full;
            item->file_name = ms_path_filename(full);
            item->extension = g_ascii_strdown(strrchr(full, '.') != NULL ? strrchr(full, '.') : "", -1);
            item->size = (long long) info.st_size;
            item->last_write_utc = info.st_mtime;
            item->kind = kind;
            g_ptr_array_add(scan->media, item);
        }

        closedir(handle);
        g_free(directory);
    }

    g_ptr_array_free(pending, TRUE);
    g_ptr_array_sort(scan->media, compare_paths);
    g_ptr_array_sort(scan->unverifiable, compare_paths);
    g_free(normalized_root);

    return scan;
}

GPtrArray *ms_scan_media(const char *root_path)
{
    CardScan *scan = ms_scan_card(root_path);
    GPtrArray *media = scan->media;
    scan->media = NULL;
    g_ptr_array_free(scan->unverifiable, TRUE);
    g_free(scan);
    return media;
}
