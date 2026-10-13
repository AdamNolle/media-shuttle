#include "../src/core/ms_core.h"

#include <glib.h>
#include <glib/gstdio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int total_assertions = 0;

static void assert_true(gboolean condition, const char *description)
{
    total_assertions++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", description);
        exit(1);
    }
}

static void recursive_remove(const char *path)
{
    GDir *dir = g_dir_open(path, 0, NULL);
    if (dir == NULL) {
        g_remove(path);
        return;
    }
    const char *name;
    while ((name = g_dir_read_name(dir)) != NULL) {
        char *sub = g_build_filename(path, name, NULL);
        if (g_file_test(sub, G_FILE_TEST_IS_DIR)) {
            recursive_remove(sub);
        } else {
            g_remove(sub);
        }
        g_free(sub);
    }
    g_dir_close(dir);
    g_rmdir(path);
}

int main(void)
{
    char *test_root = g_build_filename(g_get_tmp_dir(), "media-shuttle-core-tests-XXXXXX", NULL);
    if (g_mkdtemp(test_root) == NULL) {
        fprintf(stderr, "Could not create temporary test directory.\n");
        return 1;
    }

    char *card_root = g_build_filename(test_root, "CARD", NULL);
    char *dest_root = g_build_filename(test_root, "Camera", NULL);
    char *state_root = g_build_filename(test_root, "State", NULL);

    char *dcim = g_build_filename(card_root, "DCIM", "100MSDCF", NULL);
    char *clip = g_build_filename(card_root, "PRIVATE", "M4ROOT", "CLIP", NULL);
    g_mkdir_with_parents(dcim, 0755);
    g_mkdir_with_parents(clip, 0755);
    g_mkdir_with_parents(dest_root, 0755);

    char *jpeg_path = g_build_filename(dcim, "DSC00001.JPG", NULL);
    char *raw_path = g_build_filename(dcim, "DSC00001.ARW", NULL);
    char *apple_double = g_build_filename(dcim, "._DSC00001.JPG", NULL);
    char *video_path = g_build_filename(clip, "C0001.MP4", NULL);
    char *index_xml = g_build_filename(card_root, "INDEX.XML", NULL);

    g_file_set_contents(jpeg_path, "jpeg-one", -1, NULL);
    g_file_set_contents(raw_path, "raw-one", -1, NULL);
    g_file_set_contents(apple_double, "metadata-not-photo", -1, NULL);
    g_file_set_contents(video_path, "video-one", -1, NULL);
    g_file_set_contents(index_xml, "metadata", -1, NULL);

    /* 1. Classification */
    MediaKind kind;
    assert_true(ms_try_classify(jpeg_path, &kind) && kind == MEDIA_JPEG, "JPEG classification");
    assert_true(ms_try_classify(raw_path, &kind) && kind == MEDIA_RAW, "RAW classification");
    assert_true(ms_try_classify(video_path, &kind) && kind == MEDIA_VIDEO, "Video classification");
    assert_true(!ms_try_classify(apple_double, &kind), "AppleDouble exclusion");

    const char *raw_samples[] = { "IMG.CR3", "IMG.CR2", "DSC.NEF", "DSCF.RAF", "P.ORF", "P.RW2", "X.PEF", "X.X3F" };
    for (guint i = 0; i < G_N_ELEMENTS(raw_samples); i++) {
        assert_true(ms_try_classify(raw_samples[i], &kind) && kind == MEDIA_RAW, "RAW extensions recognised");
    }
    assert_true(ms_try_classify("A001.BRAW", &kind) && kind == MEDIA_VIDEO, ".braw recognised as video");
    assert_true(ms_is_disposable_camera_artifact("INDEX.XML"), "Camera metadata is disposable");
    assert_true(ms_is_disposable_camera_artifact("GOPR0001.THM"), "Camera thumbnails are disposable");
    assert_true(!ms_is_disposable_camera_artifact("NOTES.PDF"), "Unknown user content is not disposable");

    /* 2. Presence Tracker */
    CardPresenceTracker *tracker = ms_presence_tracker_new();
    GPtrArray *active = g_ptr_array_new();
    g_ptr_array_add(active, card_root);

    assert_true(!ms_presence_observe(tracker, card_root, active), "Card mounted at startup is baseline");
    assert_true(!ms_presence_observe(tracker, card_root, active), "Continuously mounted card is not new insertion");

    GPtrArray *empty_active = g_ptr_array_new();
    assert_true(!ms_presence_observe(tracker, NULL, empty_active), "Removing a card reports no insertion");
    assert_true(ms_presence_observe(tracker, card_root, active), "Reinserting card is reported as new insertion");

    g_ptr_array_free(active, TRUE);
    g_ptr_array_free(empty_active, TRUE);
    ms_presence_tracker_free(tracker);

    /* 3. State store round-trip */
    StateStore *store = ms_state_store_new(state_root);
    AppLogger *logger = ms_logger_new(state_root);

    AppSettings *new_settings = g_new0(AppSettings, 1);
    new_settings->destination_root = g_strdup(dest_root);
    new_settings->auto_transfer = TRUE;
    new_settings->group_by_date = FALSE;
    new_settings->show_notifications = TRUE;
    new_settings->show_activity_log = FALSE;
    new_settings->theme = g_strdup("Dark");

    GError *error = NULL;
    assert_true(ms_settings_save(store, new_settings, &error), "Settings saved successfully");
    ms_settings_free(new_settings);

    AppSettings *loaded = ms_settings_load(store);
    assert_true(g_strcmp0(loaded->destination_root, dest_root) == 0, "Destination setting round trip");
    assert_true(g_strcmp0(loaded->theme, "Dark") == 0, "Theme setting round trip");
    assert_true(loaded->auto_transfer == TRUE, "AutoTransfer round trip");
    assert_true(loaded->show_activity_log == FALSE, "Activity log round trip");
    ms_settings_free(loaded);

    /* 4. Missing destination check */
    CardInfo card;
    memset(&card, 0, sizeof(card));
    card.root_path = card_root;
    card.volume_label = g_strdup("TEST CARD");
    card.volume_serial = 12345678;
    card.total_bytes = 64LL * 1024 * 1024;
    card.free_bytes = 48LL * 1024 * 1024;
    card.drive_type = g_strdup("Removable");

    char *missing_dest = g_build_filename(test_root, "MissingDest", NULL);
    GError *err = NULL;
    TransferResult *missing_res = ms_transfer(store, logger, &card, missing_dest, FALSE, NULL, NULL, NULL, &err);
    assert_true(missing_res == NULL && err != NULL, "Transfer rejects missing destination");
    g_clear_error(&err);
    g_free(missing_dest);

    /* 5. Transfer execution */
    TransferResult *res1 = ms_transfer(store, logger, &card, dest_root, FALSE, NULL, NULL, NULL, &error);
    if (res1 == NULL && error != NULL) {
        fprintf(stderr, "Transfer error details: %s\n", error->message);
    }
    assert_true(res1 != NULL && res1->session != NULL, "Transfer succeeded");
    assert_true(g_strcmp0(res1->session->status, "Verified") == 0, "Session status is Verified");
    assert_true(res1->session->copied_count == 3, "Copied count is 3");
    assert_true(res1->session->skipped_count == 0, "Skipped count is 0");

    char *dest_jpeg = g_build_filename(dest_root, "Photos", "JPEGs", "DSC00001.JPG", NULL);
    char *dest_raw = g_build_filename(dest_root, "Photos", "RAWs", "DSC00001.ARW", NULL);
    char *dest_video = g_build_filename(dest_root, "Videos", "C0001.MP4", NULL);
    char *dest_other_dir = g_build_filename(dest_root, "Photos", "Other", NULL);

    assert_true(g_file_test(dest_jpeg, G_FILE_TEST_EXISTS), "JPEG destination file exists");
    assert_true(g_file_test(dest_raw, G_FILE_TEST_EXISTS), "RAW destination file exists");
    assert_true(g_file_test(dest_video, G_FILE_TEST_EXISTS), "Video destination file exists");
    assert_true(!g_file_test(dest_other_dir, G_FILE_TEST_EXISTS), "No Other folder created when no other photos");

    /* 6. Duplicate transfer (no changes) */
    TransferResult *res2 = ms_transfer(store, logger, &card, dest_root, FALSE, NULL, NULL, NULL, &error);
    assert_true(res2 != NULL && res2->session != NULL, "Duplicate transfer run succeeded");
    assert_true(res2->session->copied_count == 0, "Duplicate rerun copies 0");
    assert_true(res2->session->skipped_count == 3, "Duplicate rerun skips 3");

    /* 7. Collision (modified content with same filename) */
    g_file_set_contents(jpeg_path, "jpeg-two", -1, NULL);
    TransferResult *res3 = ms_transfer(store, logger, &card, dest_root, FALSE, NULL, NULL, NULL, &error);
    assert_true(res3 != NULL && res3->session != NULL, "Collision transfer succeeded");
    assert_true(res3->session->copied_count == 1, "Collision transfer copies 1 changed file");
    char *collided_file = g_build_filename(dest_root, "Photos", "JPEGs", "DSC00001 (2).JPG", NULL);
    assert_true(g_file_test(collided_file, G_FILE_TEST_EXISTS), "Collided file uses numbered filename");
    g_free(collided_file);

    /* 8. Erase eligibility */
    GPtrArray *current_media = ms_scan_media(card_root);
    assert_true(ms_session_eligible_for_erase(res3->session, &card, current_media), "Session is eligible for erase");

    /* 9. Unknown format blocks erase */
    char *unknown_path = g_build_filename(dcim, "CLIP0001.XYZ", NULL);
    g_file_set_contents(unknown_path, "unknown format", -1, NULL);

    GError *wipe_err = NULL;
    WipeResult *blocked_wipe = ms_wipe(store, logger, &card, res3->session, NULL, NULL, NULL, &wipe_err);
    assert_true(blocked_wipe == NULL && wipe_err != NULL, "Erase blocked by unknown user format");
    g_clear_error(&wipe_err);
    g_remove(unknown_path);
    g_free(unknown_path);

    /* 10. Perform erase */
    WipeResult *wipe_res = ms_wipe(store, logger, &card, res3->session, NULL, NULL, NULL, &error);
    if (wipe_res == NULL && error != NULL) {
        fprintf(stderr, "Wipe error details: %s\n", error->message);
    }
    assert_true(wipe_res != NULL, "Erase succeeded");
    assert_true(wipe_res->deleted_files >= 3, "Erase deleted card files");
    ms_wipe_result_free(wipe_res);

    GPtrArray *post_media = ms_scan_media(card_root);
    assert_true(post_media->len == 0, "Post-erase media scan is empty");
    g_ptr_array_free(post_media, TRUE);

    g_ptr_array_free(current_media, TRUE);
    ms_transfer_result_free(res1);
    ms_transfer_result_free(res2);
    ms_transfer_result_free(res3);

    /* Cleanup */
    g_free(card.volume_label);
    g_free(card.drive_type);
    g_free(dest_jpeg);
    g_free(dest_raw);
    g_free(dest_video);
    g_free(dest_other_dir);
    g_free(jpeg_path);
    g_free(raw_path);
    g_free(apple_double);
    g_free(video_path);
    g_free(index_xml);
    g_free(dcim);
    g_free(clip);
    g_free(card_root);
    g_free(dest_root);
    g_free(state_root);

    ms_state_store_free(store);
    ms_logger_free(logger);

    recursive_remove(test_root);
    g_free(test_root);

    printf("PASS: %d core safety assertions passed successfully.\n", total_assertions);
    return 0;
}
