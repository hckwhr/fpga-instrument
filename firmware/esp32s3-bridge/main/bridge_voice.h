#pragma once
#include "voice_core.h"

#ifdef __cplusplus
extern "C" {
#endif
typedef enum { BRIDGE_VOICE_NONE, BRIDGE_VOICE_QUEUED, BRIDGE_VOICE_WAITING,
               BRIDGE_VOICE_CONFIRMED, BRIDGE_VOICE_FAILED } bridge_voice_state;
typedef struct {
    int ticket;
    voice_action action;
    bridge_voice_state state;
    char reply[96];
} bridge_voice_result;

void instrument_bridge_start(void);
// Nonblocking, called from XiaoZhi's application task. Zero means busy/invalid.
int bridge_voice_submit(voice_action action);
bridge_voice_result bridge_voice_get_result(void);
#ifdef __cplusplus
}
#endif
