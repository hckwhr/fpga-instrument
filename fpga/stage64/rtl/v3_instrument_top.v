`default_nettype none
// Logical integration only. Deliberately no V3 package constraints yet.
module v3_instrument_top(
    input wire sys_clk,key0_n,key1_n,key2_n,setting_key,adc_miso,hc05_rx,key_serial,
    output wire key_load_n,key_shift_clk,pluck_debug,
    output wire adc_sclk,adc_mosi,adc_cs0_n,adc_cs1_n,
    output wire [3:0] adc_led,
    output wire hc05_tx,status_led,ws2812_data,led_enable,
    output wire audio_bck,audio_ws,audio_din,audio_pa_en_n,
    output wire lcd_pclk,lcd_hsync,lcd_vsync,lcd_de,lcd_bl,
    output wire [5:0] lcd_r,lcd_g,lcd_b
);
    av_top #(.V3_INPUT_ENABLE(1),.SONG_UPLOAD_ENABLE(1)) u_instrument(
        .sys_clk(sys_clk),.key0_n(key0_n),.key1_n(key1_n),.key2_n(key2_n),.setting_key(setting_key),
        .key_serial(key_serial),.key_load_n(key_load_n),.key_shift_clk(key_shift_clk),.pluck_debug(pluck_debug),
        .adc_miso(adc_miso),.adc_sclk(adc_sclk),.adc_mosi(adc_mosi),.adc_cs0_n(adc_cs0_n),.adc_cs1_n(adc_cs1_n),.adc_led(adc_led),
        .hc05_rx(hc05_rx),.hc05_tx(hc05_tx),.status_led(status_led),.ws2812_data(ws2812_data),.led_enable(led_enable),
        .audio_bck(audio_bck),.audio_ws(audio_ws),.audio_din(audio_din),.audio_pa_en_n(audio_pa_en_n),
        .lcd_pclk(lcd_pclk),.lcd_hsync(lcd_hsync),.lcd_vsync(lcd_vsync),.lcd_de(lcd_de),.lcd_bl(lcd_bl),
        .lcd_r(lcd_r),.lcd_g(lcd_g),.lcd_b(lcd_b));
endmodule
`default_nettype wire
