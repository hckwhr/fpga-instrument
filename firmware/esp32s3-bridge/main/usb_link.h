#pragma once
#include "bridge_core.h"

#define USB_LINK_FRAME 600u
#define USB_LINK_LEASE_MS 5000u
typedef struct {
    bool active, discard;
    char token[17], input[USB_LINK_FRAME], output[USB_LINK_FRAME];
    size_t input_length, output_length, output_offset;
    uint32_t last_ms, sequence;
} usb_link;

// Called exclusively by the existing NimBLE pump, like bridge_core.
void usb_link_byte(usb_link *u, bridge_core *b, uint8_t byte, uint32_t now, bool available);
void usb_link_tick(usb_link *u, bridge_core *b, uint32_t now);
void usb_link_fault(usb_link *u, bridge_core *b, const char *reason);
void usb_link_reply(usb_link *u, bridge_core *b);
void usb_link_written(usb_link *u, size_t count);
