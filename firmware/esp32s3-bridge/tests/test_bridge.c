#include "bridge_core.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void ready(bridge_core *b) { bridge_open(b); bridge_subscribe(b); }
static void request(bridge_core *b, const char *s)
{ assert(bridge_receive_ble(b, (const uint8_t *)s, strlen(s), 0) == BRIDGE_OK); }
static void expect_uart(bridge_core *b, const char *s)
{
    const bridge_line *l = bridge_uart_front(b);
    assert(l && l->length == strlen(s) && memcmp(l->data, s, l->length) == 0);
    bridge_uart_sent(b);
}

static void test_all_splits(void)
{
    const char *s = "SONG2,0123456789ABCDEF,2,DATA,0,1,0000000000000000,1234\n";
    size_t length = strlen(s);
    for (size_t i = 1; i < length; ++i) {
        bridge_core b; ready(&b);
        assert(bridge_receive_ble(&b, (const uint8_t *)s, i, 1) == BRIDGE_OK);
        assert(bridge_uart_front(&b) == NULL);
        assert(bridge_receive_ble(&b, (const uint8_t *)s + i, length - i, 2) == BRIDGE_OK);
        expect_uart(&b, s);
        assert(bridge_uart_front(&b) == NULL);
    }
    puts("PASS all BLE split positions, no partial UART writes");
}

static void test_queues(void)
{
    bridge_core b; ready(&b);
    request(&b, "HELLO\r\nPING\nPLAY\nSTOP\n");
    expect_uart(&b, "HELLO\r\n"); expect_uart(&b, "PING\n");
    request(&b, "STATUS\n"); // ring wrap
    expect_uart(&b, "PLAY\n"); expect_uart(&b, "STOP\n"); expect_uart(&b, "STATUS\n");
    request(&b, "PING\nPING\nPING\nPING\n");
    assert(bridge_receive_ble(&b, (const uint8_t *)"PLAY\n", 5, 0) == BRIDGE_FULL);
    assert(!b.connected && !bridge_uart_front(&b));
    ready(&b);
    assert(bridge_receive_uart(&b, (const uint8_t *)"1\n2\n3\n4\n5\n", 10, 0) == BRIDGE_FULL);
    assert(!b.connected && b.to_ble.count == 0);
    puts("PASS concatenated lines, FIFO order, wrap and both queue overflow paths");
}

static void test_validation(void)
{
    bridge_core b;
    uint8_t s[257]; memset(s, 'X', sizeof(s)); s[255] = '\n';
    ready(&b);
    assert(bridge_receive_ble(&b, s, 256, 0) == BRIDGE_OK);
    assert(bridge_uart_front(&b)->length == 256);
    ready(&b); s[255] = 'X'; s[256] = '\n';
    assert(bridge_receive_ble(&b, s, 257, 0) == BRIDGE_INVALID);
    for (unsigned c = 0; c < 256; ++c) {
        if ((c >= 32 && c <= 126) || c == '\r' || c == '\n') continue;
        ready(&b); uint8_t byte = (uint8_t)c;
        assert(bridge_receive_ble(&b, &byte, 1, 0) == BRIDGE_INVALID);
        assert(!b.connected);
    }
    ready(&b);
    assert(bridge_receive_ble(&b, (const uint8_t *)"PL\rAY\n", 6, 0) == BRIDGE_INVALID);
    ready(&b);
    assert(bridge_receive_uart(&b, s, 257, 0) == BRIDGE_INVALID);
    puts("PASS 256-byte boundary, every forbidden byte, embedded CR, reply bounds");
}

static void test_lifecycle(void)
{
    bridge_core b; bridge_open(&b);
    assert(bridge_receive_ble(&b, (const uint8_t *)"PLAY\n", 5, 0) == BRIDGE_NOT_READY);
    bridge_subscribe(&b); request(&b, "PLAY\nST");
    assert(bridge_receive_uart(&b, (const uint8_t *)"OK,PLAY\nSTA", 11, 0) == BRIDGE_OK);
    bridge_close(&b); ready(&b);
    assert(!bridge_uart_front(&b) && !b.to_ble.count && !b.to_ble.partial.length);
    request(&b, "HELLO\n"); expect_uart(&b, "HELLO\n");
    ready(&b); request(&b, "P");
    assert(bridge_tick(&b, 1999) == BRIDGE_OK);
    assert(bridge_tick(&b, 2000) == BRIDGE_TIMEOUT);
    ready(&b);
    assert(bridge_receive_uart(&b, (const uint8_t *)"S", 1, UINT32_MAX - 1000) == BRIDGE_OK);
    assert(bridge_tick(&b, 998) == BRIDGE_OK);
    assert(bridge_tick(&b, 999) == BRIDGE_TIMEOUT);
    ready(&b);
    assert(bridge_receive_ble(&b, (const uint8_t *)"PL", 2, 0) == BRIDGE_OK);
    assert(bridge_receive_ble(&b, (const uint8_t *)"AY\n", 3, 2000) == BRIDGE_TIMEOUT);
    assert(!bridge_uart_front(&b));
    puts("PASS subscribe gating, disconnect clears both queues/partials, timeout and clock wrap");
}

// Model the fixed 4896-byte SCOPE1 burst arriving at a real UART line rate.
// The driver ring can hold it during transient BLE pressure. Queue admission
// uses the production bound; successful notifications are compared bytewise.
static bool scope_pump(unsigned baud, bool optimized, unsigned *elapsed)
{
    bridge_core b; ready(&b);
    uint8_t source[4896];
    for (size_t i=0;i<sizeof(source);++i) source[i]=i%153==152?'\n':(uint8_t)('A'+i%26);
    size_t arrived=0,read=0,sent=0;
    for (unsigned ms=0;ms<5000;++ms) {
        arrived=(size_t)((unsigned long long)(ms+1)*baud/10000);
        if(arrived>sizeof(source))arrived=sizeof(source);
        assert(arrived-read<=BRIDGE_UART_RX_BYTES);
        if(ms%10 || (ms>=120 && ms<160))continue; // scheduled work delayed 40 ms
        size_t budget=BRIDGE_PUMP_RX_BUDGET;
        while(budget && read<arrived){
            size_t n=optimized?bridge_uart_read_limit(&b):budget;
            if(n>budget)n=budget;
            if(n>arrived-read)n=arrived-read;
            if(!n)break;
            if(bridge_receive_uart(&b,source+read,n,ms)!=BRIDGE_OK)return false;
            read+=n;budget-=n;
        }
        for(unsigned i=0;i<(optimized?BRIDGE_PUMP_NOTIFY_BUDGET:1);++i){
            const uint8_t *p,*again;
            size_t n=bridge_notify_peek(&b,23,&p);
            if(!n)break;
            if(ms>=200 && ms<400){ // ENOMEM/EAGAIN: do not consume on retry.
                assert(bridge_notify_peek(&b,23,&again)==n && again==p);
                break;
            }
            assert(sent+n<=sizeof(source) && memcmp(p,source+sent,n)==0);
            bridge_notify_sent(&b,n);sent+=n;
        }
        if(bridge_tick(&b,ms)!=BRIDGE_OK)return false;
        if(sent==sizeof(source)){*elapsed=ms;return true;}
    }
    return false;
}

static void test_high_baud_backpressure(void)
{
    unsigned elapsed=0;
    assert(!scope_pump(115200,false,&elapsed)); // Previous pump must fail this load.
    assert(scope_pump(115200,true,&elapsed));
    printf("PASS 115200 scope, MTU23, scheduler gap and 200ms BLE stall: %u ms simulated\n",elapsed);
    assert(scope_pump(230400,true,&elapsed));
    printf("PASS 230400 scope, MTU23, scheduler gap and 200ms BLE stall: %u ms simulated\n",elapsed);
    bridge_core b;ready(&b);
    for(unsigned i=0;i<BRIDGE_QUEUE_LINES;++i){
        size_t n=bridge_uart_read_limit(&b);
        assert(n==BRIDGE_QUEUE_LINES-i);
        assert(bridge_receive_uart(&b,(const uint8_t *)"\n",1,0)==BRIDGE_OK);
    }
    assert(bridge_uart_read_limit(&b)==0);
    bridge_close(&b);assert(bridge_uart_read_limit(&b)==BRIDGE_LINE_BYTES);
    puts("PASS short-line worst case, full-queue pause, disconnect resumes drain; old pump negative control fails");
}

static void test_notifications(void)
{
    uint8_t reply[256]; memset(reply, 'A', sizeof(reply)); reply[255] = '\n';
    const size_t mtus[] = {23, 24, 64, 247, 517};
    for (size_t m = 0; m < sizeof(mtus) / sizeof(mtus[0]); ++m) {
        bridge_core b; ready(&b);
        // An incomplete UART reply cannot generate any notification.
        assert(bridge_receive_uart(&b, reply, 255, 0) == BRIDGE_OK);
        const uint8_t *p, *again;
        assert(bridge_notify_peek(&b, mtus[m], &p) == 0);
        assert(bridge_receive_uart(&b, reply + 255, 1, 1) == BRIDGE_OK);
        size_t offset = 0, n;
        assert(bridge_notify_peek(&b, 22, &p) == 0);
        while ((n = bridge_notify_peek(&b, mtus[m], &p)) != 0) {
            assert(n <= mtus[m] - 3 && memcmp(p, reply + offset, n) == 0);
            // Simulated temporary stack failure: no commit => identical retry.
            assert(bridge_notify_peek(&b, mtus[m], &again) == n && again == p);
            bridge_notify_sent(&b, n); offset += n;
        }
        assert(offset == 256);
    }
    puts("PASS UART reply atomicity, negotiated MTU, retry preserves exact bytes");
}

// Pipe driver used by Node to test actual C code against the production JS
// encoder and the explicitly test-only FPGA receiver model.
static int pipe_mode(void)
{
    bridge_core b; ready(&b);
    char input[4096]; uint8_t data[1024]; uint32_t now = 0;
    while (fgets(input, sizeof(input), stdin)) {
        char op = input[0];
        if (op == 'C') { ready(&b); puts("C"); }
        else if (op == 'D') { bridge_close(&b); puts("D"); }
        else if (op == 'T') { now = (uint32_t)strtoul(input + 2, NULL, 10); printf("R %d\n", bridge_tick(&b, now)); }
        else if (op == 'B' || op == 'U') {
            size_t n = strcspn(input + 2, "\r\n") / 2;
            assert(n <= sizeof(data));
            for (size_t i = 0; i < n; ++i) {
                char pair[3] = {input[2 + i * 2], input[3 + i * 2], 0};
                char *end;
                data[i] = (uint8_t)strtoul(pair, &end, 16);
                assert(end == pair + 2);
            }
            printf("R %d\n", op == 'B' ? bridge_receive_ble(&b, data, n, now) : bridge_receive_uart(&b, data, n, now));
        } else if (op == 'W') {
            const bridge_line *line = bridge_uart_front(&b);
            printf("W ");
            if (line) { for (size_t i = 0; i < line->length; ++i) printf("%02x", line->data[i]); bridge_uart_sent(&b); }
            puts("");
        } else if (op == 'N') {
            const uint8_t *p; size_t n = bridge_notify_peek(&b, strtoul(input + 2, NULL, 10), &p);
            printf("N "); for (size_t i = 0; i < n; ++i) printf("%02x", p[i]); puts("");
            bridge_notify_sent(&b, n);
        } else return 2;
    }
    return 0;
}

static bool recording_pump(size_t mtu, unsigned stall_ms)
{
    bridge_core b; ready(&b);
    static uint8_t source[196 * 500]; // Ten seconds, 50 frames/sec.
    for(size_t i=0;i<sizeof(source);++i)source[i]=i%196==195?'\n':(uint8_t)('A'+i%26);
    size_t arrived=0,read=0,sent=0;
    for(unsigned ms=0;ms<14000;++ms){
        size_t fraction=(size_t)((ms%20+1)*115200/10000);
        if(fraction>196)fraction=196;
        arrived=(ms/20)*196+fraction;
        if(arrived>sizeof(source))arrived=sizeof(source);
        if(arrived-read>BRIDGE_UART_RX_BYTES)return false;
        if(ms%10 || (ms>=100 && ms<140))continue;
        size_t budget=BRIDGE_PUMP_RX_BUDGET;
        while(budget && read<arrived){
            size_t n=bridge_uart_read_limit(&b);
            if(n>budget)n=budget;if(n>arrived-read)n=arrived-read;if(!n)break;
            if(bridge_receive_uart(&b,source+read,n,ms)!=BRIDGE_OK)return false;
            read+=n;budget-=n;
        }
        if(!(ms>=300 && ms<300+stall_ms))for(unsigned p=0;p<BRIDGE_PUMP_NOTIFY_BUDGET;p++){
            const uint8_t *data;size_t n=bridge_notify_peek(&b,mtu,&data);if(!n)break;
            assert(sent+n<=sizeof(source)&&memcmp(data,source+sent,n)==0);
            bridge_notify_sent(&b,n);sent+=n;
        }
        if(bridge_tick(&b,ms)!=BRIDGE_OK)return false;
        if(sent==sizeof(source))return true;
    }
    return false;
}

int main(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "--pipe") == 0) return pipe_mode();
    test_all_splits(); test_queues(); test_validation(); test_lifecycle(); test_notifications();
    test_high_baud_backpressure();
    assert(recording_pump(23,200));assert(recording_pump(247,200));
    assert(!recording_pump(23,1200));
    puts("PASS continuous PERF1: 9800 B/s, MTU23/247, 200ms radio stall; 1200ms overflow detected");
    puts("PASS bridge core: 7 scenario groups");
    return 0;
}
