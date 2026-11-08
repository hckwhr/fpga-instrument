`default_nettype none
// Independent 800x480 settings monitor, using the accepted LCD PLL/pin timing.
// The LCD owns a separate status handshake and commits only at its frame edge;
// neither display can stall audio or the other display's raster.
module lcd_settings_display (
    input wire sys_clk,audio_clk,audio_reset_n,clock_enable,
    input wire [79:0] status_audio,
    output wire lcd_pclk,lcd_hsync,lcd_vsync,lcd_de,lcd_bl,
    output wire [5:0] lcd_r,lcd_g,lcd_b
);
    wire clk,locked;
    lcd_pll u_lcd_pll(.clkin(sys_clk),.init_clk(sys_clk),.clkout0(clk),.lock(locked));
    reg [1:0] reset_sync_n;
    always @(posedge clk or negedge locked)
        if(!locked)reset_sync_n<=2'b00;
        else reset_sync_n<={reset_sync_n[0],1'b1};
    wire reset_n=reset_sync_n[1];
    wire [79:0] payload;
    wire update;
    status_bundle_cdc #(.SRC_CE_ENABLE(1),.DST_CE_ENABLE(0),.WIDTH(80)) u_status(
        .src_clk(audio_clk),.src_reset_n(audio_reset_n),.src_clock_enable(clock_enable),
        .src_payload(status_audio),.dst_clk(clk),.dst_reset_n(reset_n),
        .dst_clock_enable(1'b1),.dst_payload(payload),.dst_update(update));
    wire hs,vs,de,frame;
    wire [10:0] x;
    wire [9:0] y;
    lcd_timing_800x480 u_timing(.pixel_clk(clk),.reset_n(reset_n),.hsync(hs),
        .vsync(vs),.data_enable(de),.frame_start(frame),.active_x(x),.active_y(y));
    reg [10:0] x_q;
    reg [9:0] y_q;
    reg [3:0] control_q;
    always @(posedge clk or negedge reset_n)
        if(!reset_n)begin x_q<=0;y_q<=0;control_q<=0;end
        else begin x_q<=x;y_q<=y;control_q<={frame,de,hs,vs};end
    wire [67:0] menu_status=payload[67:0] | (68'd1<<23);
    wire [5:0] r,g,b;
    wire panel_hs,panel_vs,panel_de;
    // Settings occupy y=8..471 in the shared renderer. Constant ST_SETTING
    // removes its waveform/keyboard branch; the main controller is unchanged.
    instrument_panel_renderer #(.COMPACT_SCOPE(1),.UPLOAD_UI(0),.LIVE_KEYBOARD(1),
        .ADDITIVE_BANK_ENABLE(0),.STRING_BANK_ENABLE(1),.KEYBOARD_MODE_ENABLE(1),
        .MULTI_TIMBRE_ENABLE(1),.LIGHT_UI_ENABLE(1)) u_menu(
        .pixel_clk(clk),.reset_n(reset_n),.active_x(x_q),.next_active_x(x_q+11'd1),
        .active_y(y_q),.predecode_y(y),.data_enable(control_q[2]),
        .frame_start(control_q[3]),.hsync_in(control_q[1]),.vsync_in(control_q[0]),
        .hsync_out(panel_hs),.vsync_out(panel_vs),.de_out(panel_de),
        .status_payload(menu_status),.status_update(update),.upload_status(payload[79:68]),
        .audio_sample(16'sd0),.audio_sample_valid(1'b0),.red(r),.green(g),.blue(b));
    assign lcd_hsync=reset_n ? panel_hs : 1'b1;
    assign lcd_vsync=reset_n ? panel_vs : 1'b1;
    assign lcd_de=reset_n && panel_de;
    assign lcd_bl=reset_n;
    assign {lcd_r,lcd_g,lcd_b}=lcd_de ? {r,g,b} : 18'd0;
    // Capture RGB/sync half a clock after the renderer's rising-edge registers.
    ODDR u_pclk(.Q0(lcd_pclk),.Q1(),.D0(1'b0),.D1(reset_n),.TX(1'b0),.CLK(clk));
endmodule
`default_nettype wire
