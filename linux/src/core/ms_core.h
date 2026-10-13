/* Media Shuttle core — Linux port of windows/src/MediaShuttle.Core.
 *
 * The safety contract is unchanged: a copy is only published when the card copy
 * and the destination copy hash to the same SHA-256, and erase stays locked until
 * every remaining file on the card has a verified destination copy.
 *
 * Two things differ from the Windows original by necessity:
 *   - path identity is case-sensitive, which is the native Linux semantic
 *   - volume identity comes from statvfs()/st_dev rather than kernel32
 */
#ifndef MS_CORE_H
#define MS_CORE_H

#include <glib.h>
#include <time.h>

G_BEGIN_DECLS

#define MS_ERROR quark_ms_error()

typedef struct StateStore StateStore;
typedef struct AppLogger AppLogger;
typedef struct CardPresenceTracker CardPresenceTracker;

typedef enum {
    MEDIA_JPEG,
    MEDIA_RAW,
    MEDIA_OTHER_PHOTO,
    MEDIA_VIDEO
} MediaKind;

typedef enum {
    PHASE_IDLE,
    PHASE_SCANNING,
    PHASE_CHECKING_DUPLICATE,
    PHASE_COPYING,
    PHASE_VERIFYING,
    PHASE_REVERIFYING,
    PHASE_ERASING,
    PHASE_COMPLETE,
    PHASE_CANCELLED,
    PHASE_ERROR
} OperationPhase;

typedef struct {
    char *source_path;
    char *file_name;
    char *extension;
    long long size;
    time_t last_write_utc;
    MediaKind kind;
} MediaItem;

typedef struct {
    GPtrArray *media;          /* MediaItem*, sorted by source path */
    GPtrArray *unverifiable;   /* char*, paths erase must not delete */
} CardScan;

typedef struct {
    char *root_path;
    char *volume_label;
    guint32 volume_serial;
    long long total_bytes;
    long long free_bytes;
    char *drive_type;
} CardInfo;

typedef struct {
    char *source_path;
    char *destination_path;
    char *sha256;
    long long size;
    MediaKind kind;
} TransferRecord;

typedef struct {
    char *session_id;
    time_t started_utc;
    time_t completed_utc;      /* 0 when unset */
    time_t erased_utc;         /* 0 when unset */
    char *status;
    char *source_root;
    char *source_label;
    guint32 source_volume_serial;
    char *destination_root;
    int total_files;
    long long total_bytes;
    int copied_count;
    int skipped_count;
    int erased_file_count;
    GPtrArray *files;          /* TransferRecord* */
} TransferSession;

typedef struct {
    OperationPhase phase;
    char *current_item;
    int completed_files;
    int total_files;
    long long processed_bytes;
    long long total_bytes;
    int copied_files;
    int skipped_files;
    char *current_source_path;
    char *current_destination_folder;
} OperationProgress;

typedef struct {
    gboolean auto_transfer;
    gboolean group_by_date;
    gboolean show_notifications;
    gboolean show_activity_log;
    char *destination_root;
    char *theme;
} AppSettings;

typedef struct {
    TransferSession *session;
    char *session_file_path;
} TransferResult;

typedef struct {
    int deleted_files;
    GPtrArray *protected_entries;   /* char* */
} WipeResult;

typedef void (*ProgressCallback)(const OperationProgress *progress, void *user_data);

GQuark quark_ms_error(void);

const char *ms_kind_name(MediaKind kind);
MediaKind ms_kind_from_name(const char *name);

TransferSession *ms_session_new(void);
void ms_session_free(TransferSession *session);
void ms_media_item_free(MediaItem *item);
void ms_card_info_free(CardInfo *card);
void ms_card_scan_free(CardScan *scan);
void ms_settings_free(AppSettings *settings);
void ms_wipe_result_free(WipeResult *result);
void ms_transfer_result_free(TransferResult *result);
void ms_state_store_free(StateStore *store);
void ms_logger_free(AppLogger *logger);
void ms_presence_tracker_free(CardPresenceTracker *tracker);

TransferSession *ms_parse_session(const char *contents);

/* Path helpers */
char *ms_path_full(const char *path);
char *ms_path_join(const char *left, const char *right);
char *ms_path_filename(const char *path);
char *ms_path_extension(const char *path);
char *ms_path_trim_separator(const char *path);
char *ms_path_relative(const char *root, const char *path);
gboolean ms_path_is_same_or_child(const char *candidate, const char *parent);
gboolean ms_ensure_no_links(const char *path, GError **error);
gboolean ms_ensure_destination_outside_source(const char *destination, const char *source, GError **error);
char *ms_relative_destination_folder(const char *destination_root, const char *destination_path);

/* Classifier */
gboolean ms_try_classify(const char *path, MediaKind *out_kind);
CardScan *ms_scan_card(const char *root_path);
GPtrArray *ms_scan_media(const char *root_path);
gboolean ms_is_disposable_camera_artifact(const char *path);
const char *ms_destination_folder(MediaKind kind);
gboolean ms_is_windows_managed_root_entry(const char *path);

/* Hashing */
char *ms_sha256_hex(const void *data, gsize length);
char *ms_sha256_file(const char *path, GError **error);

typedef struct Sha256Stream Sha256Stream;
Sha256Stream *ms_sha256_stream_new(void);
void ms_sha256_stream_update(Sha256Stream *stream, const void *data, gsize length);
char *ms_sha256_stream_hex(Sha256Stream *stream);
void ms_sha256_stream_free(Sha256Stream *stream);

/* State and logging */
struct StateStore {
    char *root_path;
    char *sessions_path;
    char *settings_path;
};

StateStore *ms_state_store_new(const char *root_path);
AppSettings *ms_settings_load(StateStore *store);
gboolean ms_settings_save(StateStore *store, AppSettings *settings, GError **error);
char *ms_session_file_path(StateStore *store, TransferSession *session);
char *ms_save_session(StateStore *store, TransferSession *session, GError **error);
TransferSession *ms_load_latest_verified_for_card(StateStore *store, CardInfo *card);

struct AppLogger {
    char *log_path;
    char *previous_log_path;
};

AppLogger *ms_logger_new(const char *state_root);
gboolean ms_logger_write(AppLogger *logger, const char *message, GError **error);

/* Card detection */
CardInfo *ms_get_selected_source(const char *path, GError **error);
gboolean ms_is_camera_card_volume(const char *path);
GPtrArray *ms_get_candidates(const char *destination_root);
guint32 ms_volume_serial(const char *root_path);

struct CardPresenceTracker {
    GHashTable *seen;          /* char* roots, owned */
    gboolean baseline_established;
};

CardPresenceTracker *ms_presence_tracker_new(void);
gboolean ms_presence_observe(CardPresenceTracker *tracker, const char *selected_root, GPtrArray *active_roots);

/* Operations */
TransferResult *ms_transfer(
    StateStore *store,
    AppLogger *logger,
    CardInfo *card,
    const char *destination_root,
    gboolean group_by_date,
    ProgressCallback progress,
    void *user_data,
    volatile gboolean *cancelled,
    GError **error);

WipeResult *ms_wipe(
    StateStore *store,
    AppLogger *logger,
    CardInfo *card,
    TransferSession *session,
    ProgressCallback progress,
    void *user_data,
    volatile gboolean *cancelled,
    GError **error);

gboolean ms_session_eligible_for_erase(TransferSession *session, CardInfo *card, GPtrArray *media);

/* Free space for a directory (the Linux counterpart of GetDiskFreeSpaceEx). */
gboolean ms_free_space(const char *directory, long long *available, long long *total, GError **error);

G_END_DECLS

#endif /* MS_CORE_H */
