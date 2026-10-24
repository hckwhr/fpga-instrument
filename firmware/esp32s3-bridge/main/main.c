#include <string.h>
#include "board.h"
#include "bridge_core.h"
#include "driver/gpio.h"
#include "driver/uart.h"
#include "esp_log.h"
#include "esp_timer.h"
#ifdef BRIDGE_WITH_VOICE
#include "driver/usb_serial_jtag.h"
#include "usb_link.h"
static usb_link usb;
static uint32_t usb_stall_ms;
#endif
#include "nvs_flash.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#ifdef BRIDGE_WITH_VOICE
#include "bridge_voice.h"
#include <limits.h>
static portMUX_TYPE voice_lock = portMUX_INITIALIZER_UNLOCKED;
static bridge_voice_result voice_result;
static voice_core voice;
static bool voice_running;

int bridge_voice_submit(voice_action action) {
    if (!voice_command(action)) return 0;
    portENTER_CRITICAL(&voice_lock);
    if (voice_result.state == BRIDGE_VOICE_QUEUED || voice_result.state == BRIDGE_VOICE_WAITING) {
        portEXIT_CRITICAL(&voice_lock);
        return 0;
    }
    int ticket = voice_result.ticket == INT_MAX ? 1 : voice_result.ticket + 1;
    memset(&voice_result, 0, sizeof(voice_result));
    voice_result.ticket = ticket;
    voice_result.action = action;
    voice_result.state = BRIDGE_VOICE_QUEUED;
    portEXIT_CRITICAL(&voice_lock);
    return ticket;
}

bridge_voice_result bridge_voice_get_result(void) {
    portENTER_CRITICAL(&voice_lock);
    bridge_voice_result result = voice_result;
    portEXIT_CRITICAL(&voice_lock);
    return result;
}

static void voice_publish(void) {
    portENTER_CRITICAL(&voice_lock);
    voice_result.state = voice.state == VOICE_CONFIRMED ? BRIDGE_VOICE_CONFIRMED : BRIDGE_VOICE_FAILED;
    memcpy(voice_result.reply, voice.reply, sizeof(voice_result.reply));
    portEXIT_CRITICAL(&voice_lock);
    voice_running = false;
}
#endif

#if !CONFIG_IDF_TARGET_ESP32S3
#error This board profile is ESP32-S3 V3 only
#endif

#define LINK_UART UART_NUM_1
#define QUIET_MS 3000u
#define NOTIFY_STALL_MS 2000u
static const char *TAG = "instrument_bridge";
// Canonical NUS UUIDs, little-endian for NimBLE. Matches the web transport.
#define NUS_UUID(id) BLE_UUID128_INIT(0x9e,0xca,0xdc,0x24,0x0e,0xe5,0xa9,0xe0,0x93,0xf3,0xa3,0xb5,id,0x00,0x40,0x6e)
static const ble_uuid128_t service_uuid = NUS_UUID(1);
static const ble_uuid128_t write_uuid = NUS_UUID(2);
static const ble_uuid128_t notify_uuid = NUS_UUID(3);
static bridge_core bridge;
static uint16_t connection = BLE_HS_CONN_HANDLE_NONE, notify_handle;
static uint8_t own_addr_type;
static bool synced, notify_failed, stalled;
static uint32_t last_uart_ms, stalled_ms;
static QueueHandle_t uart_events;
static struct ble_npl_callout pump_timer;

static uint32_t now_ms(void) { return (uint32_t)(esp_timer_get_time() / 1000); }
static int gap_event(struct ble_gap_event *event, void *arg);

static void fault(const char *reason)
{
#ifdef BRIDGE_WITH_VOICE
    usb_link_fault(&usb, &bridge, "LINK");
    if (voice_running) voice_fail(&voice, "uart_fault_execution_unknown");
#endif
    ESP_LOGW(TAG, "Link invalidated: %s; FPGA execution state unknown", reason);
    bridge_close(&bridge);
    stalled = false;
    last_uart_ms = now_ms();
    if (connection != BLE_HS_CONN_HANDLE_NONE) {
        int rc = ble_gap_terminate(connection, BLE_ERR_REM_USER_CONN_TERM);
        if (rc != 0 && rc != BLE_HS_ENOTCONN) ESP_LOGW(TAG, "terminate rc=%d", rc);
    }
}

static int gatt_access(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)attr; (void)arg;
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) return BLE_ATT_ERR_READ_NOT_PERMITTED;
    if (conn != connection || !bridge.connected || !bridge.subscribed)
        return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    uint16_t n = OS_MBUF_PKTLEN(ctxt->om);
    uint8_t bytes[BRIDGE_LINE_BYTES];
    if (!n || n > sizeof(bytes) || os_mbuf_copydata(ctxt->om, 0, n, bytes) != 0) {
        fault("invalid BLE write size");
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }
    bridge_result r = bridge_receive_ble(&bridge, bytes, n, now_ms());
    if (r != BRIDGE_OK) {
        fault("BLE line/queue/timeout");
        return r == BRIDGE_FULL ? BLE_ATT_ERR_INSUFFICIENT_RES : BLE_ATT_ERR_UNLIKELY;
    }
    // ATT success means queued at this bridge, never FPGA command completion.
    return 0;
}

static const struct ble_gatt_svc_def services[] = {
    {.type = BLE_GATT_SVC_TYPE_PRIMARY, .uuid = &service_uuid.u,
     .characteristics = (struct ble_gatt_chr_def[]) {
         {.uuid = &write_uuid.u, .access_cb = gatt_access, .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP},
         {.uuid = &notify_uuid.u, .access_cb = gatt_access, .flags = BLE_GATT_CHR_F_NOTIFY,
          .val_handle = &notify_handle},
         {0}
     }},
    {0}
};

static void advertise(void)
{
    struct ble_hs_adv_fields fields = {0};
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids128 = (ble_uuid128_t *)&service_uuid;
    fields.num_uuids128 = 1;
    fields.uuids128_is_complete = 1;
    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) { ESP_LOGE(TAG, "adv fields rc=%d", rc); return; }
    struct ble_hs_adv_fields response = {0};
    response.name = (const uint8_t *)BRIDGE_DEVICE_NAME;
    response.name_len = strlen(BRIDGE_DEVICE_NAME);
    response.name_is_complete = 1;
    rc = ble_gap_adv_rsp_set_fields(&response);
    if (rc != 0) { ESP_LOGE(TAG, "adv response rc=%d", rc); return; }
    struct ble_gap_adv_params params = {0};
    params.conn_mode = BLE_GAP_CONN_MODE_UND;
    params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    rc = ble_gap_adv_start(own_addr_type, NULL, BLE_HS_FOREVER, &params, gap_event, NULL);
    if (rc != 0) ESP_LOGW(TAG, "advertise rc=%d", rc);
    else ESP_LOGI(TAG, "BLE advertising: %s", BRIDGE_DEVICE_NAME);
}

static int gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
#ifdef BRIDGE_WITH_VOICE
            // A connect event already in flight may arrive after advertising stops.
            // Do not give it ownership of the voice transaction or its reply.
            if (voice_running || usb.active) {
                int rc = ble_gap_terminate(event->connect.conn_handle, BLE_ERR_REM_USER_CONN_TERM);
                if (rc != 0) ESP_LOGE(TAG, "reject voice-time connection rc=%d", rc);
                break;
            }
#endif
            connection = event->connect.conn_handle;
            bridge_open(&bridge);
            ESP_LOGI(TAG, "BLE connected; subscribe then identify FPGA");
        }
        else if (!bridge.connected) last_uart_ms = now_ms();
        break;
    case BLE_GAP_EVENT_DISCONNECT:
#ifdef BRIDGE_WITH_VOICE
        if (event->disconnect.conn.conn_handle != connection) break;
#endif
        connection = BLE_HS_CONN_HANDLE_NONE;
        bridge_close(&bridge);
        stalled = false;
        notify_failed = false;
        last_uart_ms = now_ms();
        // Already transmitted bytes cannot be recalled. Drain responses before
        // advertising again, never enqueue STOP or replay an old command.
        ESP_LOGI(TAG, "BLE disconnected; queues cleared, UART draining");
        break;
    case BLE_GAP_EVENT_SUBSCRIBE:
        if (event->subscribe.conn_handle == connection && event->subscribe.attr_handle == notify_handle) {
            if (event->subscribe.cur_notify) {
                bridge_subscribe(&bridge);
                ESP_LOGI(TAG, "BLE notifications subscribed");
            }
            else if (event->subscribe.reason != BLE_GAP_SUBSCRIBE_REASON_TERM)
                fault("notifications disabled");
        }
        break;
    case BLE_GAP_EVENT_NOTIFY_TX:
        // This event may be synchronous inside notify_custom: defer mutation.
        if (event->notify_tx.conn_handle == connection && event->notify_tx.status != 0)
            notify_failed = true;
        break;
    default: break;
    }
    return 0;
}

static void pump(struct ble_npl_event *event)
{
    (void)event;
    uint32_t now = now_ms();
#ifdef BRIDGE_WITH_VOICE
    bool was_usb = usb.active;
    usb_link_tick(&usb, &bridge, now);
    // Consume only until one envelope is queued; this is USB backpressure,
    // not a second concurrent UART owner. A disconnected cable expires in 5 s.
    for (unsigned i=0; i<USB_LINK_FRAME && !usb.output_length; ++i) {
        uint8_t byte;
        if (usb_serial_jtag_read_bytes(&byte, 1, 0) != 1) break;
        bool available = connection == BLE_HS_CONN_HANDLE_NONE && !voice_running &&
            !bridge.connected && (uint32_t)(now-last_uart_ms)>=QUIET_MS && uart_wait_tx_done(LINK_UART,0)==ESP_OK;
        usb_link_byte(&usb,&bridge,byte,now,available);
    }
    if (was_usb && !usb.active) last_uart_ms = now;
#endif
    uart_event_t uart_event;
    // Limit work per host iteration; never block BLE on a UART line time.
    for (unsigned i = 0; i < 32 && xQueueReceive(uart_events, &uart_event, 0) == pdTRUE; ++i) {
        if (uart_event.type == UART_FIFO_OVF || uart_event.type == UART_BUFFER_FULL ||
            uart_event.type == UART_FRAME_ERR || uart_event.type == UART_PARITY_ERR ||
            uart_event.type == UART_BREAK) {
            fault("UART framing/overflow");
            uart_flush_input(LINK_UART);
            xQueueReset(uart_events);
            break;
        }
    }
    uint8_t bytes[BRIDGE_LINE_BYTES];
    // Stop draining the driver ring when the complete-line queue is full.
    // Bounded work leaves the NimBLE host time for Wi-Fi/voice coexistence.
    for (size_t remaining = BRIDGE_PUMP_RX_BUDGET; remaining != 0;) {
        size_t limit = bridge_uart_read_limit(&bridge);
        if (limit > remaining) limit = remaining;
        if (limit == 0) break;
        int count = uart_read_bytes(LINK_UART, bytes, limit, 0);
        if (count <= 0) break;
        remaining -= (size_t)count;
        last_uart_ms = now;
#ifdef BRIDGE_WITH_VOICE
        if (voice_running) voice_receive(&voice, bytes, (size_t)count);
        else
#endif
        if (bridge.connected && bridge.subscribed &&
            bridge_receive_uart(&bridge, bytes, (size_t)count, now) != BRIDGE_OK)
            fault("UART reply line/queue/timeout");
    }
    if (bridge_tick(&bridge, now) != BRIDGE_OK) fault("partial line timeout");
    if (notify_failed) { notify_failed = false; fault("BLE notify completion failed"); }

#ifdef BRIDGE_WITH_VOICE
    if (voice_running) {
        voice_tick(&voice, now);
        if (voice.state != VOICE_WAITING) {
            voice_publish();
            last_uart_ms = now; // Drain late replies before another owner is admitted.
        }
    }
    bridge_voice_result request = bridge_voice_get_result();
    if (!voice_running && request.state == BRIDGE_VOICE_QUEUED) {
        voice_begin(&voice, request.action, now);
        if (connection != BLE_HS_CONN_HANDLE_NONE || bridge.connected || usb.active) {
            voice_fail(&voice, "busy_app_connected_disconnect_usb_or_ble_first");
            voice_publish();
        } else if ((uint32_t)(now - last_uart_ms) < QUIET_MS || uart_wait_tx_done(LINK_UART, 0) != ESP_OK) {
            voice_fail(&voice, "busy_uart_draining_wait_three_seconds");
            voice_publish();
        } else if (ble_gap_adv_active() && ble_gap_adv_stop() != 0) {
            voice_fail(&voice, "busy_ble_advertising_stop_failed");
            voice_publish();
        } else {
            const char *command = voice_command(request.action);
            voice_running = true;
            portENTER_CRITICAL(&voice_lock);
            voice_result.state = BRIDGE_VOICE_WAITING;
            portEXIT_CRITICAL(&voice_lock);
            if (uart_write_bytes(LINK_UART, command, strlen(command)) != (int)strlen(command))
                voice_fail(&voice, "uart_short_write_execution_unknown");
        }
    }
#endif

    const bridge_line *line = bridge_uart_front(&bridge);
    if (line && uart_wait_tx_done(LINK_UART, 0) == ESP_OK) {
        // TX ring is 1024 bytes, empty here; this <=256-byte copy cannot wait
        // for wire time. The UART driver finishes this whole line on disconnect.
        int sent = uart_write_bytes(LINK_UART, line->data, line->length);
        if (sent != (int)line->length) fault("UART short write");
        else bridge_uart_sent(&bridge);
    }

    // One packet per 10 ms limited MTU23 to 2 kB/s. Send a bounded burst;
    // transient stack pressure retains the exact offset for the next callout.
    for (unsigned packet = 0; packet < BRIDGE_PUMP_NOTIFY_BUDGET; ++packet) {
#ifdef BRIDGE_WITH_VOICE
        if (usb.active) break;
#endif
        const uint8_t *data;
        size_t n = bridge_notify_peek(&bridge,
        connection == BLE_HS_CONN_HANDLE_NONE ? 23 : ble_att_mtu(connection), &data);
        if (!n) break;
        struct os_mbuf *om = ble_hs_mbuf_from_flat(data, n);
        // notify_custom consumes the mbuf even on error; retain our own queue.
        int rc = om ? ble_gatts_notify_custom(connection, notify_handle, om) : BLE_HS_ENOMEM;
        if (rc == 0 && !notify_failed) {
            bridge_notify_sent(&bridge, n);
            stalled = false;
        } else if (rc == BLE_HS_ENOMEM || rc == BLE_HS_EAGAIN || rc == BLE_HS_EBUSY) {
            if (!stalled) { stalled = true; stalled_ms = now; }
            else if ((uint32_t)(now - stalled_ms) >= NOTIFY_STALL_MS) fault("BLE notify stalled");
            break;
        } else { fault("BLE notify rejected"); break; }
    }
#ifdef BRIDGE_WITH_VOICE
    usb_link_reply(&usb,&bridge);
    if (usb.output_length) {
        int n=usb_serial_jtag_write_bytes(usb.output+usb.output_offset,usb.output_length-usb.output_offset,0);
        if (n>0) { usb_link_written(&usb,(size_t)n); usb_stall_ms=now; }
        else if ((uint32_t)(now-usb_stall_ms)>=NOTIFY_STALL_MS) {
            usb_link_fault(&usb,&bridge,"USB_STALLED"); last_uart_ms=now;
            // Cable may be absent. Discard only after invalidating the owner;
            // the host watchdog closes the session, never reports execution.
            usb.output_length=usb.output_offset=0; usb_stall_ms=now;
        }
    } else usb_stall_ms=now;
#endif
    if (synced && connection == BLE_HS_CONN_HANDLE_NONE && !ble_gap_adv_active() &&
#ifdef BRIDGE_WITH_VOICE
        !voice_running && !usb.active &&
#endif
        (uint32_t)(now - last_uart_ms) >= QUIET_MS && uart_wait_tx_done(LINK_UART, 0) == ESP_OK) {
        advertise();
        last_uart_ms = now; // Bound advertising retries if the controller rejects one.
    }
    ble_npl_callout_reset(&pump_timer, ble_npl_time_ms_to_ticks32(2));
}

static void on_reset(int reason)
{
#ifdef BRIDGE_WITH_VOICE
    if (voice_running) {
        voice_fail(&voice, "bluetooth_reset_execution_unknown");
        voice_publish();
    }
#endif
    synced = false;
    connection = BLE_HS_CONN_HANDLE_NONE;
#ifdef BRIDGE_WITH_VOICE
    if (!usb.active)
#endif
    bridge_close(&bridge);
    stalled = false;
    notify_failed = false;
    last_uart_ms = now_ms();
    ESP_LOGW(TAG, "NimBLE reset reason=%d", reason);
}

static void on_sync(void)
{
    int rc = ble_hs_util_ensure_addr(0);
    if (rc == 0) rc = ble_hs_id_infer_auto(0, &own_addr_type);
    if (rc != 0) { ESP_LOGE(TAG, "BLE address rc=%d", rc); return; }
    synced = true;
    last_uart_ms = now_ms();
    ble_npl_callout_reset(&pump_timer, ble_npl_time_ms_to_ticks32(10));
}

static void host_task(void *arg)
{
    (void)arg;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

#ifdef BRIDGE_WITH_VOICE
void instrument_bridge_start(void)
#else
void app_main(void)
#endif
{
#ifdef BRIDGE_WITH_VOICE
    // USB Serial/JTAG has a dedicated driver. sdkconfig disables secondary
    // console output on USB; debug logging remains on UART0 GPIO43/44.
    usb_serial_jtag_driver_config_t usb_config={.tx_buffer_size=8192,.rx_buffer_size=8192};
    ESP_ERROR_CHECK(usb_serial_jtag_driver_install(&usb_config));
#endif
#ifndef BRIDGE_WITH_VOICE
    // Actual V3 uses SD_MODE directly through R51, not the old MOS inverter.
    ESP_ERROR_CHECK(gpio_set_level(BRIDGE_AMP_MUTE_GPIO, BRIDGE_AMP_MUTE_LEVEL));
    ESP_ERROR_CHECK(gpio_set_direction(BRIDGE_AMP_MUTE_GPIO, GPIO_MODE_OUTPUT));
    ESP_ERROR_CHECK(nvs_flash_init()); // Do not erase user NVS on an init error.
#endif
    const uart_config_t config = {
        .baud_rate = BRIDGE_UART_BAUD, .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE, .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE, .source_clk = UART_SCLK_DEFAULT
    };
    ESP_ERROR_CHECK(uart_driver_install(LINK_UART, BRIDGE_UART_RX_BYTES, 1024, 64, &uart_events, 0));
    ESP_ERROR_CHECK(uart_param_config(LINK_UART, &config));
    ESP_ERROR_CHECK(uart_set_pin(LINK_UART, BRIDGE_UART_TX_GPIO, BRIDGE_UART_RX_GPIO,
                               UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE));
    ESP_ERROR_CHECK(gpio_set_pull_mode(BRIDGE_UART_RX_GPIO, GPIO_PULLUP_ONLY));
    ESP_ERROR_CHECK(nimble_port_init());
    ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.sync_cb = on_sync;
    ble_svc_gap_init();
    ble_svc_gatt_init();
    ESP_ERROR_CHECK(ble_gatts_count_cfg(services));
    ESP_ERROR_CHECK(ble_gatts_add_svcs(services));
    ESP_ERROR_CHECK(ble_svc_gap_device_name_set(BRIDGE_DEVICE_NAME));
    ble_npl_callout_init(&pump_timer, nimble_port_get_dflt_eventq(), pump, NULL);
    ESP_LOGI(TAG, "V3 UART1 TX=%d RX=%d, %d 8N1; BLE NUS; no FPGA ACK synthesis",
             BRIDGE_UART_TX_GPIO, BRIDGE_UART_RX_GPIO, BRIDGE_UART_BAUD);
    nimble_port_freertos_init(host_task);
}
