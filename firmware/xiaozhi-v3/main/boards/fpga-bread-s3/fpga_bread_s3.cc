#include "wifi_board.h"
#include "codecs/no_audio_codec.h"
#include "display/oled_display.h"
#include "application.h"
#include "button.h"
#include "config.h"
#include "mcp_server.h"
#include "led/single_led.h"
#include "bridge_voice.h"
#include <algorithm>
#include <driver/i2c_master.h>
#include <esp_lcd_panel_ops.h>
#include <esp_lcd_panel_vendor.h>
#include <esp_log.h>
#include <wifi_station.h>

LV_FONT_DECLARE(font_puhui_14_1);
LV_FONT_DECLARE(font_awesome_14_1);

class FpgaBreadS3 : public WifiBoard {
    Button boot_{BOOT_BUTTON_GPIO};
    Button talk_{TOUCH_BUTTON_GPIO};
    Button volume_up_{VOLUME_UP_BUTTON_GPIO};
    Button volume_down_{VOLUME_DOWN_BUTTON_GPIO};
    Display* display_ = nullptr;

    void InitializeDisplay() {
        static_assert(CONFIG_FPGA_OLED_HEIGHT == 32 || CONFIG_FPGA_OLED_HEIGHT == 64);
        i2c_master_bus_config_t bus_config = {};
        bus_config.i2c_port = I2C_NUM_0;
        bus_config.sda_io_num = DISPLAY_SDA_PIN;
        bus_config.scl_io_num = DISPLAY_SCL_PIN;
        bus_config.clk_source = I2C_CLK_SRC_DEFAULT;
        bus_config.glitch_ignore_cnt = 7;
        bus_config.flags.enable_internal_pullup = true;
        i2c_master_bus_handle_t bus = nullptr;
        ESP_ERROR_CHECK(i2c_new_master_bus(&bus_config, &bus));
        if (i2c_master_probe(bus, 0x3c, 100) != ESP_OK) {
            ESP_LOGW("FpgaBreadS3", "No OLED at 0x3c; continuing without a display");
            ESP_ERROR_CHECK(i2c_del_master_bus(bus));
            display_ = new NoDisplay();
            return;
        }
        esp_lcd_panel_io_i2c_config_t io_config = {};
        io_config.dev_addr = 0x3c;
        io_config.control_phase_bytes = 1;
        io_config.dc_bit_offset = 6;
        io_config.lcd_cmd_bits = 8;
        io_config.lcd_param_bits = 8;
        io_config.scl_speed_hz = 400000;
        esp_lcd_panel_io_handle_t io = nullptr;
        ESP_ERROR_CHECK(esp_lcd_new_panel_io_i2c_v2(bus, &io_config, &io));
        esp_lcd_panel_ssd1306_config_t ssd_config = {};
        ssd_config.height = CONFIG_FPGA_OLED_HEIGHT;
        esp_lcd_panel_dev_config_t panel_config = {};
        panel_config.reset_gpio_num = -1;
        panel_config.bits_per_pixel = 1;
        panel_config.vendor_config = &ssd_config;
        esp_lcd_panel_handle_t panel = nullptr;
        ESP_ERROR_CHECK(esp_lcd_new_panel_ssd1306(io, &panel_config, &panel));
        ESP_ERROR_CHECK(esp_lcd_panel_reset(panel));
        ESP_ERROR_CHECK(esp_lcd_panel_init(panel));
        ESP_ERROR_CHECK(esp_lcd_panel_disp_on_off(panel, true));
        display_ = new OledDisplay(io, panel, 128, CONFIG_FPGA_OLED_HEIGHT, true, true,
            {&font_puhui_14_1, &font_awesome_14_1}, true);
    }

    void InitializeTools() {
        auto& mcp = McpServer::GetInstance();
        auto add = [&mcp](const char* name, const char* description, voice_action action) {
            mcp.AddTool(name, description, PropertyList(), [action](const PropertyList&) -> ReturnValue {
                int ticket = bridge_voice_submit(action);
                if (!ticket) throw std::runtime_error("FPGA control busy; do not claim execution");
                return "queued ticket=" + std::to_string(ticket) +
                    "; NOT executed yet. Call self.fpga.result with this ticket; only confirmed means FPGA acknowledged.";
            });
        };
        add("self.fpga.ping", "Check the wired FPGA connection. Query self.fpga.result after enqueue.", VOICE_PING);
        add("self.fpga.play_demo", "Play the FPGA built-in demonstration (Twinkle/Ode), NOT an uploaded song or arbitrary title. "
            "Requires companion BLE/USB app disconnected. Query result before announcing success.", VOICE_PLAY_DEMO);
        add("self.fpga.stop", "Stop FPGA song playback, including uploaded playback. BLE/USB app must disconnect first. "
            "Does not mute manually held keys. Query result before announcing success.", VOICE_STOP);
        add("self.fpga.status", "Query built-in FPGA player status. Does not report uploaded SONG2 playback state. "
            "Query result after enqueue.", VOICE_STATUS);
        mcp.AddTool("self.fpga.result", "Read the asynchronous result of the last FPGA command. "
            "queued/waiting is NOT success; failed means failure or execution unknown. Never automatically replay on timeout. "
            "If BLE/USB busy, ask user to disconnect the companion app. confirmed requires an actual matching FPGA UART reply.",
            PropertyList({Property("ticket", kPropertyTypeInteger, 1, 2147483647)}),
            [](const PropertyList& properties) -> ReturnValue {
                auto result = bridge_voice_get_result();
                if (result.ticket != properties["ticket"].value<int>())
                    throw std::runtime_error("FPGA result expired or unknown ticket");
                const char* states[] = {"none", "queued", "waiting", "confirmed", "failed"};
                return std::string(states[result.state]) + ": " + result.reply;
            });
    }

public:
    FpgaBreadS3() {
        InitializeDisplay();
        boot_.OnClick([this]() {
            auto& app = Application::GetInstance();
            if (app.GetDeviceState() == kDeviceStateStarting && !WifiStation::GetInstance().IsConnected())
                ResetWifiConfiguration();
            app.ToggleChatState();
        });
        talk_.OnPressDown([]() { Application::GetInstance().StartListening(); });
        talk_.OnPressUp([]() { Application::GetInstance().StopListening(); });
        volume_up_.OnClick([this]() {
            auto codec = GetAudioCodec();
            codec->SetOutputVolume(std::min(100, codec->output_volume() + 10));
        });
        volume_down_.OnClick([this]() {
            auto codec = GetAudioCodec();
            codec->SetOutputVolume(std::max(0, codec->output_volume() - 10));
        });
        instrument_bridge_start();
        InitializeTools();
    }
    AudioCodec* GetAudioCodec() override {
        static NoAudioCodecSimplex codec(AUDIO_INPUT_SAMPLE_RATE, AUDIO_OUTPUT_SAMPLE_RATE,
            AUDIO_I2S_SPK_GPIO_BCLK, AUDIO_I2S_SPK_GPIO_LRCK, AUDIO_I2S_SPK_GPIO_DOUT,
            AUDIO_I2S_MIC_GPIO_SCK, AUDIO_I2S_MIC_GPIO_WS, AUDIO_I2S_MIC_GPIO_DIN);
        return &codec;
    }
    Led* GetLed() override { static SingleLed led(BUILTIN_LED_GPIO); return &led; }
    Display* GetDisplay() override { return display_; }
};

DECLARE_BOARD(FpgaBreadS3);
