#pragma once

// Actual 硬件/V3/原理图.pdf, 2026-10-15. V3 ONLY.
#define BRIDGE_UART_TX_GPIO 17 // module pad 10 -> FPGA A20 (RX), net TX2
#define BRIDGE_UART_RX_GPIO 18 // module pad 11 <- FPGA A21 (TX), net RX2
#define BRIDGE_AMP_MUTE_GPIO 39 // ESP_PA_CTL -> R51 -> MAX98357A SD_MODE
#define BRIDGE_AMP_MUTE_LEVEL 0 // SD_MODE LOW = shutdown; no voice playback
// Paired with stage64 FPGA: 50 MHz / 434. Older 9600 images are incompatible.
#define BRIDGE_UART_BAUD 115200
#define BRIDGE_DEVICE_NAME "行者无疆"
