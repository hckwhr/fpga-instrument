`default_nettype none
// SOM30354 + Dock31005, GW5AST-138C. LCD pins intentionally absent.
// Accepted LCD build is preserved separately in stage65 and the backup ZIP.
module v3_hdmi_top (
    input wire sys_clk,key0_n,key1_n,key2_n,setting_key,adc_miso,hc05_rx,
    output wire pluck_debug,adc_sclk,adc_mosi,adc_cs0_n,adc_cs1_n,
    output wire [3:0] adc_led,
    output wire hc05_tx,ws2812_data,
    output wire audio_bck,audio_ws,audio_din,audio_pa_en_n,
    output wire hdmi_clock_p,hdmi_clock_n,
    output wire [2:0] hdmi_data_p,hdmi_data_n,
    output wire hdmi_tx_enable
);
    av_hdmi_top #(.HALF_RATE_ENABLE(1),.V3_INPUT_ENABLE(1),.V3_ANALOG_KEYS_ENABLE(1),
        .PRESSURE_KEY_REVERSED(1),.RGB_KEY_REVERSED(1),
        .SONG_UPLOAD_ENABLE(1),.LARGE_SCORE_ENABLE(1),.LEGACY_VOICE_ENABLE(0),
        .ADDITIVE_BANK_ENABLE(0),.STRING_BANK_ENABLE(1),.SHARED_CLKS_PER_BIT(434),
        .SCORE_PLAYBACK_ENABLE(1),.BRIGHT_OUTPUT_ENABLE(1),
        .RGB_PIXELS_PER_KEY(1),.RGB_STARTUP_TEST_ENABLE(0)) u_instrument (
        .sys_clk(sys_clk),.key0_n(key0_n),.key1_n(key1_n),.key2_n(key2_n),.setting_key(setting_key),
        .key_serial(1'b1),.key_load_n(),.key_shift_clk(),.pluck_debug(pluck_debug),
        .adc_miso(adc_miso),.adc_sclk(adc_sclk),.adc_mosi(adc_mosi),
        .adc_cs0_n(adc_cs0_n),.adc_cs1_n(adc_cs1_n),.adc_led(adc_led),
        .hc05_rx(hc05_rx),.hc05_tx(hc05_tx),.status_led(),.ws2812_data(ws2812_data),.led_enable(),
        .audio_bck(audio_bck),.audio_ws(audio_ws),.audio_din(audio_din),.audio_pa_en_n(audio_pa_en_n),
        .hdmi_clock_p(hdmi_clock_p),.hdmi_clock_n(hdmi_clock_n),
        .hdmi_data_p(hdmi_data_p),.hdmi_data_n(hdmi_data_n),.hdmi_tx_enable(hdmi_tx_enable));
endmodule
`default_nettype wire
