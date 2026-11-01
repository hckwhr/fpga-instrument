#include "bridge_core.h"
#include <string.h>

/* Reassemble BLE packets and UART fragments into complete protocol lines.
 * Only complete lines enter the ring queue. Invalid input, overflow or a
 * partial-line timeout closes the session and discards pending commands,
 * so fragments cannot become valid-looking commands after reconnection.
 * The bridge does not interpret notes: numbered FPGA replies confirm execution. */

void bridge_close(bridge_core *b) { memset(b, 0, sizeof(*b)); }
void bridge_open(bridge_core *b) { bridge_close(b); b->connected = true; }
void bridge_subscribe(bridge_core *b) { if (b->connected) b->subscribed = true; }

static bridge_result fail(bridge_core *b, bridge_result reason)
{
    bridge_close(b); // Never forward a truncated line or retain queued old commands.
    b->fault = reason;
    return reason;
}

static bridge_result receive(bridge_core *b, bridge_stream *s,
                             const uint8_t *data, size_t n, uint32_t now)
{
    if (!b->connected || !b->subscribed) return BRIDGE_NOT_READY;
    if (!data || !n) return fail(b, BRIDGE_INVALID);
    if (bridge_tick(b, now) != BRIDGE_OK) return b->fault;
    for (size_t i = 0; i < n; ++i) {
        uint8_t c = data[i];
        if ((c < 32 && c != '\r' && c != '\n') || c > 126)
            return fail(b, BRIDGE_INVALID);
        if (s->partial.length == 0) s->started_ms = now;
        if (s->partial.length == BRIDGE_LINE_BYTES - 1 && c != '\n')
            return fail(b, BRIDGE_INVALID);
        // CR is allowed only immediately before LF; preserve it on the wire.
        if (s->partial.length && s->partial.data[s->partial.length - 1] == '\r' && c != '\n')
            return fail(b, BRIDGE_INVALID);
        s->partial.data[s->partial.length++] = c;
        if (c == '\n') {
            if (s->count == BRIDGE_QUEUE_LINES) return fail(b, BRIDGE_FULL);
            s->lines[(s->head + s->count) % BRIDGE_QUEUE_LINES] = s->partial;
            ++s->count;
            s->partial.length = 0;
        }
    }
    return BRIDGE_OK;
}

bridge_result bridge_receive_ble(bridge_core *b, const uint8_t *p, size_t n, uint32_t now)
{ return receive(b, &b->to_uart, p, n, now); }

bridge_result bridge_receive_uart(bridge_core *b, const uint8_t *p, size_t n, uint32_t now)
{ return receive(b, &b->to_ble, p, n, now); }

bridge_result bridge_tick(bridge_core *b, uint32_t now)
{
    if (b->fault != BRIDGE_OK) return b->fault;
    if ((b->to_uart.partial.length && (uint32_t)(now - b->to_uart.started_ms) >= BRIDGE_PARTIAL_MS) ||
        (b->to_ble.partial.length && (uint32_t)(now - b->to_ble.started_ms) >= BRIDGE_PARTIAL_MS))
        return fail(b, BRIDGE_TIMEOUT);
    return BRIDGE_OK;
}

const bridge_line *bridge_uart_front(const bridge_core *b)
{ return b->connected && b->to_uart.count ? &b->to_uart.lines[b->to_uart.head] : NULL; }

size_t bridge_uart_read_limit(const bridge_core *b)
{
    if (!b->connected || !b->subscribed) return BRIDGE_LINE_BYTES;
    return BRIDGE_QUEUE_LINES - b->to_ble.count;
}

static void pop(bridge_stream *s)
{
    s->head = (s->head + 1) % BRIDGE_QUEUE_LINES;
    --s->count;
    s->offset = 0;
}

void bridge_uart_sent(bridge_core *b) { if (b->to_uart.count) pop(&b->to_uart); }

size_t bridge_notify_peek(const bridge_core *b, size_t mtu, const uint8_t **data)
{
    const bridge_stream *s = &b->to_ble;
    *data = NULL;
    if (!b->connected || !b->subscribed || !s->count || mtu < 23) return 0;
    size_t n = s->lines[s->head].length - s->offset;
    if (n > mtu - 3) n = mtu - 3;
    *data = s->lines[s->head].data + s->offset;
    return n;
}

void bridge_notify_sent(bridge_core *b, size_t n)
{
    bridge_stream *s = &b->to_ble;
    if (!s->count || !n) return;
    size_t remaining = s->lines[s->head].length - s->offset;
    if (n > remaining) { fail(b, BRIDGE_INVALID); return; }
    s->offset += n;
    if (n == remaining) pop(s);
}
