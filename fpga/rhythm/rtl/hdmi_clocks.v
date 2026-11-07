`default_nettype none
// VESA DMT 800x600@56: 50 *18 /1 = 900 MHz VCO, /5 = 180 MHz FCLK,
// /25 = 36 MHz PCLK. The VCO is within the GW5AST-138C 650-1300 MHz range.
// A single PLL replaces the previous cascade: the 1080p30 chain needed
// 50 -> 50.625 -> 371.25 MHz through two VCOs (1012.5 and 1113.75 MHz, the
// second near the device limit), which multiplied jitter on a TMDS link that
// is driven by pseudo-differential LVCMOS33D buffers.
// PCLK and FCLK come from the same PLL at 1:5, as OSER10 requires.
// The renderer no longer runs at half rate, so render_clk is PCLK itself:
// one 36 MHz net instead of two same-frequency outputs, which keeps the
// renderer and the TMDS encoders in a single clock domain.
module hdmi_clocks (
    input wire sys_clk,
    output wire pixel_clk,serial_clk,render_clk,locked
);
    wire video_locked;
    hdmi_pll u_video (.clkin(sys_clk),.init_clk(sys_clk),
        .clkout0(serial_clk),.clkout1(pixel_clk),.clkout2(),.lock(video_locked));
    assign render_clk=pixel_clk;
    assign locked=video_locked;
endmodule
`default_nettype wire
