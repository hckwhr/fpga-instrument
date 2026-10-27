`default_nettype none
// DVI-compatible RGB video over HDMI, no audio/infoframes/HDCP.
// PCLK and FCLK must come from the same PLL at 1:5 with aligned phase.
module hdmi_tmds_tx (
    input wire pixel_clk, serial_clk, reset_n, serializer_reset_n,
    input wire de, hsync, vsync,
    input wire [23:0] rgb,
    output wire clock_p, clock_n,
    output wire [2:0] data_p, data_n
);
    // UG306 section 4.1 permits DHCE -> IOLOGIC FCLK. Do not attempt to
    // time a fabric reset against a continuously running 371.25 MHz I/O
    // clock: its clock-tree latency differs from the fabric clock tree.
    // On every reset/relock, keep RESET asserted for 16 PCLK cycles while
    // DHCE closes; release RESET on falling PCLK, then wait ANOTHER 16 PCLK
    // cycles (215.488 ns) before opening FCLK. PCLK recovery stays single-cycle.
    // Only RESET -> FCLK recovery has a paired, bounded 4-FCLK exception:
    // 10.776 ns is much shorter than the guaranteed clock-stopped interval.
    reg [5:0] startup_count = 6'd0;
    reg serializer_release_n = 1'b0 /* synthesis syn_preserve = 1 syn_keep = 1 */;
    reg serial_running = 1'b0;
    always @(negedge pixel_clk or negedge serializer_reset_n) begin
        if(!serializer_reset_n)begin
            startup_count<=6'd0;serializer_release_n<=1'b0;serial_running<=1'b0;
        end else begin
            if(startup_count!=6'd63)startup_count<=startup_count+6'd1;
            if(startup_count==6'd15)serializer_release_n<=1'b1;
            if(startup_count==6'd31)serial_running<=1'b1;
        end
    end
    wire gated_serial_clk;
    DHCE u_serial_gate(.CLKIN(serial_clk),.CEN(!serial_running),.CLKOUT(gated_serial_clk));
    wire [9:0] symbols [0:3];
    tmds_encoder u_blue (.pixel_clk(pixel_clk),.reset_n(reset_n),
        .de(de),.data(rgb[7:0]),.control({vsync,hsync}),.symbol(symbols[0]));
    tmds_encoder u_green (.pixel_clk(pixel_clk),.reset_n(reset_n),
        .de(de),.data(rgb[15:8]),.control(2'b00),.symbol(symbols[1]));
    tmds_encoder u_red (.pixel_clk(pixel_clk),.reset_n(reset_n),
        .de(de),.data(rgb[23:16]),.control(2'b00),.symbol(symbols[2]));
    assign symbols[3]=10'b1111100000;
    wire [3:0] serial_data,positive,negative;
    genvar lane;
    generate for(lane=0;lane<4;lane=lane+1) begin: lanes
        OSER10 u_serializer (.Q(serial_data[lane]),
            .D0(symbols[lane][0]),.D1(symbols[lane][1]),.D2(symbols[lane][2]),
            .D3(symbols[lane][3]),.D4(symbols[lane][4]),.D5(symbols[lane][5]),
            .D6(symbols[lane][6]),.D7(symbols[lane][7]),.D8(symbols[lane][8]),
            .D9(symbols[lane][9]),.PCLK(pixel_clk),.FCLK(gated_serial_clk),.RESET(!serializer_release_n));
        ELVDS_OBUF u_output (.I(serial_data[lane]),.O(positive[lane]),.OB(negative[lane]));
    end endgenerate
    assign data_p=positive[2:0];assign data_n=negative[2:0];
    assign clock_p=positive[3];assign clock_n=negative[3];
endmodule
`default_nettype wire
