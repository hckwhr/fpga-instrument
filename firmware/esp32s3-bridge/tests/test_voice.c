#include "voice_core.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void feed(voice_core *v, const char *s) {
    voice_receive(v, (const uint8_t *)s, strlen(s));
}

int main(void) {
    // Literal expectations from the accepted stage62 RTL UART bench.
    const struct {voice_action action; const char *tx; const char *rx;} cases[] = {
        {VOICE_PING, "PING\n", "PONG\n"},
        {VOICE_PLAY_DEMO, "PLAY\n", "OK,PLAY\n"},
        {VOICE_PLAY_TWINKLE, "PLAY,0\n", "OK,PLAY,0\n"},
        {VOICE_PLAY_ODE, "PLAY,1\n", "OK,PLAY,1\n"},
        {VOICE_STOP, "STOP\n", "OK,STOP\n"},
        {VOICE_STATUS, "STATUS\n", "STATUS,PLAYING,085/085\n"},
        {VOICE_STATUS, "STATUS\n", "STATUS,STOPPED,030/030\n"},
        {VOICE_STATUS, "STATUS\n", "STATUS,SETTING\n"},
        {VOICE_STATUS, "STATUS\n", "STATUS,MANUAL\n"}
    };
    for (size_t c = 0; c < sizeof(cases)/sizeof(cases[0]); ++c) {
        for (size_t split = 0; split <= strlen(cases[c].rx); ++split) {
            voice_core v = {0};
            assert(!strcmp(voice_command(cases[c].action), cases[c].tx));
            assert(voice_begin(&v, cases[c].action, 10));
            assert(!voice_begin(&v, VOICE_STOP, 11));
            voice_receive(&v, (const uint8_t *)cases[c].rx, split);
            if (split < strlen(cases[c].rx)) assert(v.state == VOICE_WAITING);
            feed(&v, cases[c].rx + split);
            assert(v.state == VOICE_CONFIRMED);
        }
    }
    voice_core v = {0};
    assert(voice_begin(&v, VOICE_PLAY_ODE, 0));
    feed(&v, "OK,PLAY,0\n"); assert(v.state == VOICE_FAILED);
    assert(voice_begin(&v, VOICE_PLAY_TWINKLE, 0));
    feed(&v, "OK,PLAY\n"); assert(v.state == VOICE_FAILED);
    assert(!voice_begin(&v, (voice_action)99, 0));
    assert(voice_begin(&v, VOICE_PLAY_DEMO, 0));
    feed(&v, "ERR,LOCAL\n"); assert(v.state == VOICE_FAILED);
    assert(!strcmp(v.reply, "ERR,LOCAL"));
    voice_begin(&v, VOICE_PLAY_DEMO, 0);
    feed(&v, "OK,STOP\n"); assert(v.state == VOICE_FAILED);
    voice_begin(&v, VOICE_STATUS, 0);
    feed(&v, "STATUS,PLAYING,0x5/085\n"); assert(v.state == VOICE_FAILED);
    voice_begin(&v, VOICE_PING, 0);
    feed(&v, "PONG\r\n"); assert(v.state == VOICE_CONFIRMED);
    voice_begin(&v, VOICE_PING, 0);
    feed(&v, "PONG\rX\n"); assert(v.state == VOICE_FAILED);
    voice_begin(&v, VOICE_PING, 0);
    uint8_t junk[97]; memset(junk, 'A', sizeof(junk));
    voice_receive(&v, junk, sizeof(junk)); assert(v.state == VOICE_FAILED);
    voice_begin(&v, VOICE_PING, UINT32_MAX - 100);
    feed(&v, "PO"); voice_tick(&v, 2898); assert(v.state == VOICE_WAITING);
    voice_tick(&v, 2899); assert(v.state == VOICE_FAILED);
    feed(&v, "NG\n"); assert(v.state == VOICE_FAILED); // Late ACK cannot resurrect timeout.
    voice_begin(&v, VOICE_STOP, 0);
    voice_fail(&v, "uart_fault_execution_unknown");
    feed(&v, "OK,STOP\n"); assert(v.state == VOICE_FAILED);
    puts("PASS: voice commands, all reply splits, refusal/mismatch, CRLF, overflow, timeout wrap and late replies");
    return 0;
}
