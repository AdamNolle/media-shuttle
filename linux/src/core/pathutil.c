#include "ms_core.h"

#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>

GQuark quark_ms_error(void)
{
    static GQuark quark = 0;
    if (quark == 0) {
        quark = g_quark_from_static_string("media-shuttle-core");
    }
    return quark;
}

static char *normalize(const char *path)
{
    GString *out = g_string_new(NULL);
    const char *p = path;

    if (p == NULL || p[0] == '\0') {
        g_string_assign(out, "/");
        return g_string_free(out, FALSE);
    }

    if (p[0] != '/') {
        char *cwd = g_get_current_dir();
        g_string_assign(out, cwd);
        g_free(cwd);
    }

    /* Split on '/' and rebuild, resolving "." and ".." against the accumulated path. */
    GPtrArray *segments = g_ptr_array_new();
    const char *segment = p;
    while (*segment != '\0') {
        while (*segment == '/') {
            segment++;
        }
        if (*segment == '\0') {
            break;
        }
        const char *end = segment;
        while (*end != '\0' && *end != '/') {
            end++;
        }
        if (end - segment == 1 && segment[0] == '.') {
            segment = end;
            continue;
        }
        if (end - segment == 2 && segment[0] == '.' && segment[1] == '.') {
            if (segments->len > 0) {
                g_ptr_array_remove_index(segments, segments->len - 1);
            }
            segment = end;
            continue;
        }
        g_ptr_array_add(segments, g_strndup(segment, (gsize)(end - segment)));
        segment = end;
    }

    for (guint index = 0; index < segments->len; index++) {
        out = g_string_append_c(out, '/');
        out = g_string_append(out, (char *) segments->pdata[index]);
        g_free(segments->pdata[index]);
    }
    g_ptr_array_free(segments, TRUE);

    if (out->len == 0) {
        g_string_assign(out, "/");
    }
    return g_string_free(out, FALSE);
}

char *ms_path_full(const char *path)
{
    return normalize(path);
}

char *ms_path_join(const char *left, const char *right)
{
    if (right == NULL || right[0] == '\0') {
        return g_strdup(left);
    }
    if (right[0] == '/') {
        return g_strdup(right);
    }
    char *trimmed = ms_path_trim_separator(left);
    char *joined = g_strdup_printf("%s/%s", trimmed, right);
    g_free(trimmed);
    return joined;
}

char *ms_path_filename(const char *path)
{
    const char *trimmed = path;
    size_t length = strlen(trimmed);
    while (length > 0 && trimmed[length - 1] == '/') {
        length--;
    }
    if (length == 0) {
        return g_strdup("");
    }
    const char *slash = strrchr(trimmed, '/');
    if (slash == NULL) {
        return g_strdup(trimmed);
    }
    return g_strndup(slash + 1, length - (gsize)(slash - trimmed) - 1);
}

char *ms_path_extension(const char *path)
{
    char *name = ms_path_filename(path);
    const char *dot = strrchr(name, '.');
    char *extension = dot != NULL ? g_ascii_strdown(dot, -1) : g_strdup("");
    g_free(name);
    return extension;
}

char *ms_path_trim_separator(const char *path)
{
    size_t length = strlen(path);
    while (length > 1 && path[length - 1] == '/') {
        length--;
    }
    return g_strndup(path, length);
}

char *ms_path_relative(const char *root, const char *path)
{
    char *normalized_root = ms_path_trim_separator(ms_path_full(root));
    char *normalized_path = ms_path_full(path);
    char *directory = g_path_get_dirname(normalized_path);

    if (g_strcmp0(directory, normalized_root) == 0) {
        g_free(normalized_root);
        g_free(normalized_path);
        g_free(directory);
        return g_strdup("");
    }

    char *relative = NULL;
    if (g_str_has_prefix(directory, normalized_root)) {
        const char *rest = directory + strlen(normalized_root);
        while (*rest == '/') {
            rest++;
        }
        relative = g_strdup(rest);
    } else {
        relative = g_strdup(directory);
    }

    g_free(normalized_root);
    g_free(normalized_path);
    g_free(directory);
    return relative;
}

gboolean ms_path_is_same_or_child(const char *candidate, const char *parent)
{
    char *root = ms_path_trim_separator(ms_path_full(parent));
    char *path = ms_path_trim_separator(ms_path_full(candidate));

    gboolean match = g_strcmp0(path, root) == 0;
    if (!match) {
        char *with_separator = g_strdup_printf("%s/", root);
        match = g_str_has_prefix(path, with_separator);
        g_free(with_separator);
    }

    g_free(root);
    g_free(path);
    return match;
}

/* Check every existing ancestor: a category folder can be a symlink back to the card. */
gboolean ms_ensure_no_links(const char *path, GError **error)
{
    char *current = ms_path_full(path);

    for (;;) {
        struct stat info;
        if (lstat(current, &info) == 0 && S_ISLNK(info.st_mode)) {
            g_set_error(error, MS_ERROR, 1, "Choose a path without symbolic links or junctions.");
            g_free(current);
            return FALSE;
        }

        char *parent = g_path_get_dirname(current);
        if (g_strcmp0(parent, current) == 0) {
            g_free(parent);
            break;
        }
        g_free(current);
        current = parent;
    }

    g_free(current);
    return TRUE;
}

gboolean ms_ensure_destination_outside_source(const char *destination, const char *source, GError **error)
{
    if (ms_path_is_same_or_child(destination, source)) {
        g_set_error(error, MS_ERROR, 2, "The destination cannot be inside the selected source.");
        return FALSE;
    }
    if (!ms_ensure_no_links(source, error)) {
        return FALSE;
    }
    return ms_ensure_no_links(destination, error);
}

char *ms_relative_destination_folder(const char *destination_root, const char *destination_path)
{
    char *directory = g_path_get_dirname(destination_path);
    char *relative = ms_path_relative(destination_root, directory);
    g_free(directory);
    return relative;
}
