/* SHA-256 — the verification primitive the whole safety contract rests on.
 * Kept in-house so the app has no runtime crypto dependency.
 *
 * The round constants and initial state are generated from the fractional parts of
 * the cube roots and square roots of the first 64 primes, exactly as FIPS 180-4
 * defines them. Generating them here rather than pasting a 64-entry table means a
 * mistyped constant cannot silently produce wrong hashes: the test suite checks the
 * FIPS vector ("abc" -> ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad)
 * and fails if the table is wrong.
 */
#include "ms_core.h"

#include <fcntl.h>
#include <math.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    guint32 state[8];
    guint64 bit_length;
    guint8 buffer[64];
    gsize buffer_used;
} Sha256;

static guint32 round_constants[64];
static guint32 initial_state[8];

static gboolean is_prime(int value)
{
    if (value < 2) {
        return FALSE;
    }
    for (int candidate = 2; candidate * candidate <= value; candidate++) {
        if (value % candidate == 0) {
            return FALSE;
        }
    }
    return TRUE;
}

static guint32 fractional_part_scaled(long double value)
{
    long double fraction = value - floorl(value);
    return (guint32) (fraction * 4294967296.0L);
}

static void ensure_constants(void)
{
    if (round_constants[0] != 0) {
        return;
    }

    int found = 0;
    int index = 0;
    while (found < 64) {
        if (is_prime(index)) {
            round_constants[found] = fractional_part_scaled(cbrtl((long double) index));
            if (found < 8) {
                initial_state[found] = fractional_part_scaled(sqrtl((long double) index));
            }
            found++;
        }
        index++;
    }
}

static guint32 rotr(guint32 value, guint bits)
{
    return (value >> bits) | (value << (32 - bits));
}

static void sha256_init(Sha256 *sha)
{
    ensure_constants();
    for (int i = 0; i < 8; i++) {
        sha->state[i] = initial_state[i];
    }
    sha->bit_length = 0;
    sha->buffer_used = 0;
}

static void sha256_compress(Sha256 *sha, const guint8 *block)
{
    guint32 w[64];
    for (int i = 0; i < 16; i++) {
        w[i] = ((guint32) block[i * 4] << 24) | ((guint32) block[i * 4 + 1] << 16) |
               ((guint32) block[i * 4 + 2] << 8) | (guint32) block[i * 4 + 3];
    }
    for (int i = 16; i < 64; i++) {
        guint32 s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        guint32 s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }

    guint32 a = sha->state[0], b = sha->state[1], c = sha->state[2], d = sha->state[3];
    guint32 e = sha->state[4], f = sha->state[5], g = sha->state[6], h = sha->state[7];

    for (int i = 0; i < 64; i++) {
        guint32 s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        guint32 ch = (e & f) ^ ((~e) & g);
        guint32 temp1 = h + s1 + ch + round_constants[i] + w[i];
        guint32 s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        guint32 maj = (a & b) ^ (a & c) ^ (b & c);
        guint32 temp2 = s0 + maj;
        h = g; g = f; f = e; e = d + temp1;
        d = c; c = b; b = a; a = temp1 + temp2;
    }

    sha->state[0] += a; sha->state[1] += b; sha->state[2] += c; sha->state[3] += d;
    sha->state[4] += e; sha->state[5] += f; sha->state[6] += g; sha->state[7] += h;
}

static void sha256_update(Sha256 *sha, const guint8 *data, gsize length)
{
    sha->bit_length += (guint64) length * 8;
    while (length > 0) {
        gsize take = 64 - sha->buffer_used;
        if (take > length) {
            take = length;
        }
        memcpy(sha->buffer + sha->buffer_used, data, take);
        sha->buffer_used += take;
        data += take;
        length -= take;
        if (sha->buffer_used == 64) {
            sha256_compress(sha, sha->buffer);
            sha->buffer_used = 0;
        }
    }
}

static void sha256_final(Sha256 *sha, guint8 out[32])
{
    guint8 padding = 0x80;
    sha256_update(sha, &padding, 1);
    while (sha->buffer_used != 56) {
        guint8 zero = 0;
        sha256_update(sha, &zero, 1);
    }

    /* The length is written big-endian, and the padding byte already consumed one
     * slot, so eight bytes land exactly on the 64-byte block boundary. */
    guint8 length_bytes[8];
    for (int i = 0; i < 8; i++) {
        length_bytes[i] = (guint8) ((sha->bit_length >> (56 - i * 8)) & 0xFF);
    }
    sha256_update(sha, length_bytes, 8);

    for (int i = 0; i < 8; i++) {
        out[i * 4] = (guint8) ((sha->state[i] >> 24) & 0xFF);
        out[i * 4 + 1] = (guint8) ((sha->state[i] >> 16) & 0xFF);
        out[i * 4 + 2] = (guint8) ((sha->state[i] >> 8) & 0xFF);
        out[i * 4 + 3] = (guint8) (sha->state[i] & 0xFF);
    }
}

char *ms_sha256_hex(const void *data, gsize length)
{
    Sha256 sha;
    guint8 digest[32];
    sha256_init(&sha);
    if (data != NULL && length > 0) {
        sha256_update(&sha, (const guint8 *) data, length);
    }
    sha256_final(&sha, digest);

    GString *hex = g_string_new(NULL);
    for (int i = 0; i < 32; i++) {
        g_string_append_printf(hex, "%02X", digest[i]);
    }
    return g_string_free(hex, FALSE);
}

char *ms_sha256_file(const char *path, GError **error)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        g_set_error(error, MS_ERROR, 3, "Could not open %s for hashing.", path);
        return NULL;
    }

    Sha256 sha;
    sha256_init(&sha);

    static guint8 buffer[1024 * 1024];
    ssize_t bytes_read;
    while ((bytes_read = read(fd, buffer, sizeof(buffer))) > 0) {
        sha256_update(&sha, buffer, (gsize) bytes_read);
    }

    close(fd);

    if (bytes_read < 0) {
        g_set_error(error, MS_ERROR, 3, "Could not read %s while hashing.", path);
        return NULL;
    }

    guint8 digest[32];
    sha256_final(&sha, digest);

    GString *hex = g_string_new(NULL);
    for (int i = 0; i < 32; i++) {
        g_string_append_printf(hex, "%02X", digest[i]);
    }
    return g_string_free(hex, FALSE);
}

struct Sha256Stream {
    Sha256 state;
};

Sha256Stream *ms_sha256_stream_new(void)
{
    Sha256Stream *stream = g_new0(Sha256Stream, 1);
    sha256_init(&stream->state);
    return stream;
}

void ms_sha256_stream_update(Sha256Stream *stream, const void *data, gsize length)
{
    sha256_update(&stream->state, (const guint8 *) data, length);
}

char *ms_sha256_stream_hex(Sha256Stream *stream)
{
    guint8 digest[32];
    sha256_final(&stream->state, digest);

    GString *hex = g_string_new(NULL);
    for (int i = 0; i < 32; i++) {
        g_string_append_printf(hex, "%02X", digest[i]);
    }
    return g_string_free(hex, FALSE);
}

void ms_sha256_stream_free(Sha256Stream *stream)
{
    g_free(stream);
}
