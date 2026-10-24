#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define BRIDGE_LINE_BYTES 256u
#define BRIDGE_QUEUE_LINES 4u
#define BRIDGE_PARTIAL_MS 2000u
#define BRIDGE_UART_RX_BYTES 8192u // Entire SCOPE1 snapshot is 4896 bytes.
#define BRIDGE_PUMP_RX_BUDGET 256u
#define BRIDGE_PUMP_NOTIFY_BUDGET 16u

typedef enum {
    BRIDGE_OK, BRIDGE_NOT_READY, BRIDGE_INVALID, BRIDGE_FULL, BRIDGE_TIMEOUT
} bridge_result;

typedef struct {
    uint8_t data[BRIDGE_LINE_BYTES];
    size_t length;
} bridge_line;

typedef struct {
    bridge_line lines[BRIDGE_QUEUE_LINES];
    size_t head, count, offset;
    bridge_line partial;
    uint32_t started_ms;
} bridge_stream;

// Single owner: NimBLE host callbacks and its periodic callout. No ISR access.
typedef struct {
    bool connected, subscribed;
    bridge_result fault;
    bridge_stream to_uart, to_ble;
} bridge_core;

void bridge_open(bridge_core *b);
void bridge_close(bridge_core *b);
void bridge_subscribe(bridge_core *b);
bridge_result bridge_receive_ble(bridge_core *b, const uint8_t *data, size_t n, uint32_t now);
bridge_result bridge_receive_uart(bridge_core *b, const uint8_t *data, size_t n, uint32_t now);
bridge_result bridge_tick(bridge_core *b, uint32_t now);
// Conservative read bound: even if every byte is LF, no complete line is lost.
// Leave excess bytes in the driver's RX ring until BLE makes queue space.
size_t bridge_uart_read_limit(const bridge_core *b);
const bridge_line *bridge_uart_front(const bridge_core *b);
void bridge_uart_sent(bridge_core *b);
size_t bridge_notify_peek(const bridge_core *b, size_t mtu, const uint8_t **data);
void bridge_notify_sent(bridge_core *b, size_t n);
