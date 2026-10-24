`default_nettype none
// Actual 2026-10-15 V3 PCB interface. No 74HC165, BRK or LED-enable wire.
module v3_hardware_top #(parameter integer STRING_BANK_ENABLE=1)(
    input wire sys_clk,key0_n,key1_n,key2_n,setting_key,adc_miso,hc05_rx,
    output wire pluck_debug,adc_sclk,adc_mosi,adc_cs0_n,adc_cs1_n,
    output wire [3:0] adc_led,
    output wire hc05_tx,ws2812_data,
    output wire audio_bck,audio_ws,audio_din,audio_pa_en_n,
    output wire lcd_pclk,lcd_hsync,lcd_vsync,lcd_de,lcd_bl,
    output wire [5:0] lcd_r,lcd_g,lcd_b
);
    av_top #(.HALF_RATE_ENABLE(1),.V3_INPUT_ENABLE(1),.V3_ANALOG_KEYS_ENABLE(1),.SONG_UPLOAD_ENABLE(1),.LARGE_SCORE_ENABLE(1),
        .LEGACY_VOICE_ENABLE(0),.ADDITIVE_BANK_ENABLE(0),.STRING_BANK_ENABLE(STRING_BANK_ENABLE),
        // 50 MHz / 434 = 115207 baud (+0.0064%). Pair with S3 115200 8N1.
        .SHARED_CLKS_PER_BIT(434),
        .BRIGHT_OUTPUT_ENABLE(1),.RGB_PIXELS_PER_KEY(1),.RGB_STARTUP_TEST_ENABLE(1)) u_instrument(
        .sys_clk(sys_clk),.key0_n(key0_n),.key1_n(key1_n),.key2_n(key2_n),.setting_key(setting_key),
        .key_serial(1'b1),.key_load_n(),.key_shift_clk(),.pluck_debug(pluck_debug),
        .adc_miso(adc_miso),.adc_sclk(adc_sclk),.adc_mosi(adc_mosi),.adc_cs0_n(adc_cs0_n),.adc_cs1_n(adc_cs1_n),.adc_led(adc_led),
        .hc05_rx(hc05_rx),.hc05_tx(hc05_tx),.status_led(),.ws2812_data(ws2812_data),.led_enable(),
        .audio_bck(audio_bck),.audio_ws(audio_ws),.audio_din(audio_din),.audio_pa_en_n(audio_pa_en_n),
        .lcd_pclk(lcd_pclk),.lcd_hsync(lcd_hsync),.lcd_vsync(lcd_vsync),.lcd_de(lcd_de),.lcd_bl(lcd_bl),
        .lcd_r(lcd_r),.lcd_g(lcd_g),.lcd_b(lcd_b));
endmodule
`default_nettype wire
