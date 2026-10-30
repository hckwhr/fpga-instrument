#include "voice_core.h"
#include <stdio.h>
#include <string.h>

const char *voice_command(voice_action action) {
    switch (action) {
    case VOICE_PING: return "PING\n";
    case VOICE_PLAY_DEMO: return "PLAY\n";
    case VOICE_PLAY_TWINKLE: return "PLAY,0\n";
    case VOICE_PLAY_ODE: return "PLAY,1\n";
    case VOICE_STOP: return "STOP\n";
    case VOICE_STATUS: return "STATUS\n";
    default: return NULL;
    }
}

bool voice_begin(voice_core *v, voice_action action, uint32_t now) {
    if (v->state == VOICE_WAITING || !voice_command(action)) return false;
    memset(v, 0, sizeof(*v));
    v->action = action;
    v->state = VOICE_WAITING;
    v->started_ms = now;
    return true;
}

void voice_fail(voice_core *v, const char *reason) {
    v->state = VOICE_FAILED;
    snprintf(v->reply, sizeof(v->reply), "%s", reason);
}

static bool status_matches(const char *s) {
    if (!strcmp(s, "STATUS,SETTING") || !strcmp(s, "STATUS,MANUAL")) return true;
    if (strlen(s) != 22 ||
        (strncmp(s, "STATUS,PLAYING,", 15) && strncmp(s, "STATUS,STOPPED,", 15))) return false;
    for (size_t i = 15; i < 22; ++i) {
        if (i == 18) { if (s[i] != '/') return false; }
        else if (s[i] < '0' || s[i] > '9') return false;
    }
    return true;
}

void voice_receive(voice_core *v, const uint8_t *data, size_t n) {
    for (size_t i = 0; i < n && v->state == VOICE_WAITING; ++i) {
        uint8_t b = data[i];
        if (b == '\n') {
            v->reply[v->length] = 0;
            bool match = (v->action == VOICE_PING && !strcmp(v->reply, "PONG")) ||
                (v->action == VOICE_PLAY_DEMO && !strcmp(v->reply, "OK,PLAY")) ||
                (v->action == VOICE_PLAY_TWINKLE && !strcmp(v->reply, "OK,PLAY,0")) ||
                (v->action == VOICE_PLAY_ODE && !strcmp(v->reply, "OK,PLAY,1")) ||
                (v->action == VOICE_STOP && !strcmp(v->reply, "OK,STOP")) ||
                (v->action == VOICE_STATUS && status_matches(v->reply));
            if (match) v->state = VOICE_CONFIRMED;
            else if (!strncmp(v->reply, "ERR,", 4)) v->state = VOICE_FAILED;
            else voice_fail(v, "unexpected_reply_execution_unknown");
        } else if (b == '\r' && !v->cr_seen) {
            v->cr_seen = true;
        } else if (v->cr_seen || b < 32 || b > 126 || v->length >= sizeof(v->reply) - 1) {
            voice_fail(v, "invalid_reply_execution_unknown");
        } else {
            v->reply[v->length++] = (char)b;
        }
    }
}

void voice_tick(voice_core *v, uint32_t now) {
    if (v->state == VOICE_WAITING && (uint32_t)(now - v->started_ms) >= 3000u)
        voice_fail(v, "timeout_execution_unknown_do_not_retry_automatically");
}
