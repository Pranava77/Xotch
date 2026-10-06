// needle-helper
//
// Runs Cactus's Whistle speech model (via the needle engine in
// Vendor/Needle/libneedle.a) for Xotch's dictation, in its own process.
// Why a process and not a library: needle keeps one model per process and has
// no way to unload it, and a loaded model takes about 37 MB, 70 MB while
// streaming. As a helper, Xotch starts it when you dictate and quits it when
// you stop for a while, so the memory comes back. The engine is also built for
// macOS 26, which Xotch itself doesn't require.
//
// Protocol: requests on stdin are frames of
//   1 byte op | 4 bytes little-endian payload length | payload
// and each request gets one line of JSON on stdout.
//   'L' payload: path of whistle.cact            -> {"ok":true} or {"error":"..."}
//   'O' payload: language "\0" keywords          -> {"ok":true}
//        language "" detects it; keywords are newline-separated.
//   'A' payload: float32 16 kHz mono samples     -> needle_stream_transcribe_process's JSON
//   'S' (no payload): end the stream             -> needle_stream_transcribe_stop's JSON
//   'T' payload: float32 samples, at most 30 s   -> needle_transcribe's JSON
// The helper exits when stdin closes, so it never outlives Xotch.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../Vendor/Needle/needle.h"

#define OUT_CAPACITY (128 * 1024)

static char out[OUT_CAPACITY];
static char language[16];
static char *keywords;

static int read_exactly(void *buffer, size_t count) {
    return fread(buffer, 1, count, stdin) == count;
}

static void reply(const char *json) {
    fputs(json, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void reply_error(const char *message) {
    char line[1024];
    size_t used = (size_t)snprintf(line, sizeof line, "{\"error\":\"");
    for (const char *c = message ? message : "unknown error"; *c && used < sizeof line - 4; c++) {
        if (*c == '"' || *c == '\\') line[used++] = '\\';
        line[used++] = (*c == '\n' || *c == '\r' || *c == '\t') ? ' ' : *c;
    }
    line[used] = '\0';
    strncat(line, "\"}", sizeof line - strlen(line) - 1);
    reply(line);
}

static void reply_result(int status) {
    if (status < 0) {
        reply_error(needle_last_error());
    } else {
        reply(out);
    }
}

static int load(const char *path) {
    FILE *file = fopen(path, "rb");
    if (!file) return -1;
    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    fseek(file, 0, SEEK_SET);
    unsigned char *model = malloc((size_t)size);
    if (!model || fread(model, 1, (size_t)size, file) != (size_t)size) {
        fclose(file);
        free(model);
        return -1;
    }
    fclose(file);
    // needle keeps its own copy of what it needs.
    int status = needle_load(model, (unsigned long long)size);
    free(model);
    return status;
}

int main(void) {
    for (;;) {
        unsigned char op;
        uint32_t length;
        if (!read_exactly(&op, 1) || !read_exactly(&length, 4)) return 0;
        char *payload = malloc(length + 1);
        if (!payload) return 1;
        if (length && !read_exactly(payload, length)) return 0;
        payload[length] = '\0';

        const float *samples = (const float *)payload;
        int count = (int)(length / sizeof(float));
        const char *lang = language[0] ? language : NULL;

        switch (op) {
        case 'L':
            if (load(payload) < 0) {
                reply_error(needle_last_error() ? needle_last_error() : "Couldn't read the model.");
            } else {
                reply("{\"ok\":true}");
            }
            break;
        case 'O': {
            size_t split = strnlen(payload, length);
            snprintf(language, sizeof language, "%s", payload);
            free(keywords);
            keywords = NULL;
            if (split + 1 < length && payload[split + 1]) keywords = strdup(payload + split + 1);
            reply("{\"ok\":true}");
            break;
        }
        case 'A':
            reply_result(needle_stream_transcribe_process(samples, count, lang, keywords, out, OUT_CAPACITY));
            break;
        case 'S':
            reply_result(needle_stream_transcribe_stop(out, OUT_CAPACITY));
            break;
        case 'T':
            reply_result(needle_transcribe(samples, count, lang, keywords, 0, out, OUT_CAPACITY));
            break;
        default:
            reply_error("Unknown request.");
        }
        free(payload);
    }
}
