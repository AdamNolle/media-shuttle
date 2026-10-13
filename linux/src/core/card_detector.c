#include "ms_core.h"

#include <sys/stat.h>
#include <sys/statvfs.h>

/* The Linux counterpart of GetDiskFreeSpaceEx. statvfs answers for any directory,
 * including mount points, which is what the Windows comment about UNC shares and
 * directory mount points was protecting. */
gboolean ms_free_space(const char *directory, long long *available, long long *total, GError **error)
{
    struct statvfs info;
    if (statvfs(directory, &info) != 0) {
        g_set_error(error, MS_ERROR, 6, "The free space on the destination drive could not be read.");
        return FALSE;
    }

    if (available != NULL) {
        *available = (long long) info.f_bsize * (long long) info.f_bavail;
    }
    if (total != NULL) {
        *total = (long long) info.f_bsize * (long long) info.f_blocks;
    }
    return TRUE;
}

/* st_dev identifies the mount, which is the stable per-volume identity here.
 * statvfs f_fsid is not portable across filesystems, so it is not used. */
guint32 ms_volume_serial(const char *root_path)
{
    struct stat info;
    if (stat(root_path, &info) != 0) {
        return 0;
    }
    return (guint32) info.st_dev;
}

static gboolean has_camera_layout(const char *root)
{
    return g_file_test(ms_path_join(root, "DCIM"), G_FILE_TEST_IS_DIR) ||
           g_file_test(ms_path_join(root, "M4ROOT"), G_FILE_TEST_IS_DIR) ||
           g_file_test(ms_path_join(root, "PRIVATE"), G_FILE_TEST_IS_DIR);
}

static char *device_name_for(const char *mount_point)
{
    char *contents = NULL;
    if (!g_file_get_contents("/proc/mounts", &contents, NULL, NULL)) {
        return NULL;
    }

    char *result = NULL;
    char **lines = g_strsplit(contents, "\n", -1);
    for (int i = 0; lines[i] != NULL; i++) {
        char **parts = g_strsplit(lines[i], " ", 3);
        if (parts[0] != NULL && parts[1] != NULL && g_strcmp0(parts[1], mount_point) == 0 &&
            g_str_has_prefix(parts[0], "/dev/")) {
            result = g_strdup(parts[0]);
            g_strfreev(parts);
            break;
        }
        g_strfreev(parts);
    }
    g_strfreev(lines);
    g_free(contents);
    return result;
}

/* /sys/block/<disk>/removable reports 1 for card readers. Many readers report 0,
 * which is why candidacy is gated by the DCIM/M4ROOT/PRIVATE check instead. */
static char *drive_type_for(const char *mount_point)
{
    char *device = device_name_for(mount_point);
    if (device == NULL) {
        return g_strdup("Selected folder");
    }

    char *base = g_path_get_basename(device);
    char *disk = g_path_get_dirname(base);
    char *sys_path = g_strdup_printf("/sys/block/%s/removable", disk);

    gboolean removable = FALSE;
    char *value = NULL;
    if (g_file_get_contents(sys_path, &value, NULL, NULL)) {
        removable = g_strcmp0(g_strstrip(value), "1") == 0;
    }
    g_free(value);

    char *type = removable ? g_strdup("Removable") : g_strdup("Fixed");
    g_free(sys_path);
    g_free(disk);
    g_free(base);
    g_free(device);
    return type;
}

static char *label_for(const char *root)
{
    char *trimmed = ms_path_trim_separator(root);
    char *name = g_path_get_basename(trimmed);
    g_free(trimmed);

    if (name == NULL || name[0] == '\0' || g_strcmp0(name, "/") == 0) {
        g_free(name);
        return g_strdup("CAMERA MEDIA");
    }
    return name;
}

CardInfo *ms_get_selected_source(const char *path, GError **error)
{
    char *root = ms_path_full(path);
    if (!ms_ensure_no_links(root, error)) {
        g_free(root);
        return NULL;
    }
    if (!g_file_test(root, G_FILE_TEST_IS_DIR)) {
        g_set_error(error, MS_ERROR, 7, "The selected source folder is unavailable.");
        g_free(root);
        return NULL;
    }

    long long available = 0, total = 0;
    if (!ms_free_space(root, &available, &total, error)) {
        g_free(root);
        return NULL;
    }

    gboolean is_mount_point = g_strcmp0(root, "/") != 0 && device_name_for(root) != NULL;
    if (g_strcmp0(root, "/") == 0) {
        g_set_error(error, MS_ERROR, 8, "Choose a media folder or a camera card, rather than the system drive.");
        g_free(root);
        return NULL;
    }

    CardInfo *card = g_new0(CardInfo, 1);
    card->root_path = root;
    card->volume_label = is_mount_point ? label_for(root) : g_path_get_basename(root);
    if (card->volume_label == NULL || card->volume_label[0] == '\0') {
        g_free(card->volume_label);
        card->volume_label = g_strdup("CAMERA MEDIA");
    }
    card->volume_serial = ms_volume_serial(root);
    card->total_bytes = total;
    card->free_bytes = available;
    card->drive_type = is_mount_point ? drive_type_for(root) : g_strdup("Selected folder");
    return card;
}

gboolean ms_is_camera_card_volume(const char *path)
{
    char *root = ms_path_full(path);
    char *trimmed = ms_path_trim_separator(root);

    gboolean is_mount_point = g_strcmp0(trimmed, "/") != 0 && device_name_for(trimmed) != NULL;
    gboolean result = is_mount_point && has_camera_layout(trimmed);

    g_free(trimmed);
    g_free(root);
    return result;
}

static int compare_by_label(gconstpointer left, gconstpointer right)
{
    CardInfo *a = * (CardInfo **) left;
    CardInfo *b = * (CardInfo **) right;
    return g_ascii_strcasecmp(a->volume_label, b->volume_label);
}

GPtrArray *ms_get_candidates(const char *destination_root)
{
    GPtrArray *candidates = g_ptr_array_new_with_free_func((GFreeFunc) ms_card_info_free);

    char *destination_full = ms_path_trim_separator(ms_path_full(destination_root));
    char *destination_mount = g_path_get_dirname(destination_full);

    char *contents = NULL;
    if (g_file_get_contents("/proc/mounts", &contents, NULL, NULL)) {
        char **lines = g_strsplit(contents, "\n", -1);
        for (int i = 0; lines[i] != NULL; i++) {
            char **parts = g_strsplit(lines[i], " ", 3);
            if (parts[0] == NULL || parts[1] == NULL) {
                g_strfreev(parts);
                continue;
            }

            if (!g_str_has_prefix(parts[0], "/dev/")) {
                g_strfreev(parts);
                continue;
            }

            char *mount = g_strdup(parts[1]);
            if (g_strcmp0(mount, "/") == 0 || g_strcmp0(mount, destination_mount) == 0) {
                g_free(mount);
                g_strfreev(parts);
                continue;
            }

            if (!has_camera_layout(mount)) {
                g_free(mount);
                g_strfreev(parts);
                continue;
            }

            long long available = 0, total = 0;
            GError *error = NULL;
            if (ms_free_space(mount, &available, &total, &error)) {
                CardInfo *card = g_new0(CardInfo, 1);
                card->root_path = mount;
                card->volume_label = label_for(mount);
                card->volume_serial = ms_volume_serial(mount);
                card->total_bytes = total;
                card->free_bytes = available;
                card->drive_type = drive_type_for(mount);
                g_ptr_array_add(candidates, card);
            } else {
                g_clear_error(&error);
                g_free(mount);
            }

            g_strfreev(parts);
        }
        g_strfreev(lines);
        g_free(contents);
    }

    g_ptr_array_sort(candidates, compare_by_label);

    g_free(destination_mount);
    g_free(destination_full);
    return candidates;
}

CardPresenceTracker *ms_presence_tracker_new(void)
{
    CardPresenceTracker *tracker = g_new0(CardPresenceTracker, 1);
    tracker->seen = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    return tracker;
}

void ms_presence_tracker_free(CardPresenceTracker *tracker)
{
    if (tracker == NULL) {
        return;
    }
    g_hash_table_destroy(tracker->seen);
    g_free(tracker);
}

gboolean ms_presence_observe(CardPresenceTracker *tracker, const char *selected_root, GPtrArray *active_roots)
{
    GHashTable *active = g_hash_table_new_full(g_str_hash, g_str_equal, NULL, NULL);
    for (guint index = 0; index < active_roots->len; index++) {
        g_hash_table_add(active, (char *) active_roots->pdata[index]);
    }

    GPtrArray *stale = g_ptr_array_new();
    GHashTableIter iter;
    gpointer key;
    g_hash_table_iter_init(&iter, tracker->seen);
    while (g_hash_table_iter_next(&iter, &key, NULL)) {
        if (!g_hash_table_contains(active, key)) {
            g_ptr_array_add(stale, key);
        }
    }
    for (guint index = 0; index < stale->len; index++) {
        g_hash_table_remove(tracker->seen, stale->pdata[index]);
    }
    g_ptr_array_free(stale, TRUE);

    if (!tracker->baseline_established) {
        for (guint index = 0; index < active_roots->len; index++) {
            g_hash_table_add(tracker->seen, g_strdup((char *) active_roots->pdata[index]));
        }
        tracker->baseline_established = TRUE;
        g_hash_table_destroy(active);
        return FALSE;
    }

    gboolean result = selected_root != NULL && g_hash_table_add(tracker->seen, g_strdup(selected_root));
    g_hash_table_destroy(active);
    return result;
}
