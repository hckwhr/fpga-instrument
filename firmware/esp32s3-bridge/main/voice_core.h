#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Only commands implemented by the accepted stage62 short-command endpoint.
typedef enum { VOICE_PING, VOICE_PLAY_DEMO, VOICE_STOP, VOICE_STATUS } voice_action;
typedef enum { VOICE_IDLE, VOICE_WAITING, VOICE_CONFIRMED, VOICE_FAILED } voice_state;
typedef struct {
    voice_action action;
    voice_state state;
    uint32_t started_ms;
    size_t length;
    bool cr_seen;
    char reply[96];
} voice_core;

const char *voice_command(voice_action action);
bool voice_begin(voice_core *v, voice_action action, uint32_t now);
void voice_receive(voice_core *v, const uint8_t *data, size_t n);
void voice_tick(voice_core *v, uint32_t now);
void voice_fail(voice_core *v, const char *reason);
