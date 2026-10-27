`default_nettype none
// VESA DMT 800x600@56, 36 MHz. Positive sync, 1024 x 625 total.
// Both monitors rejected the previous CEA 1920x1080p30 raster: this
// transmitter is DVI-only and sends no AVI InfoFrame, so a CEA-only mode is
// not accepted. 800x600 is DMT and was confirmed on both panels.
// The 800x480 dashboard maps 1:1, centered vertically at y=60, so no pixel
// doubling is needed and the renderer runs at the full pixel clock.
// No pixel doubling is needed and the renderer runs at the full pixel clock.
// Coordinates outside the dashboard use out-of-range sentinels, so no plot
// can bleed into blanking. frame_start remains one pulse per physical frame.
module hdmi_timing_800x600 (
    input wire pixel_clk,reset_n,
    output wire hsync,vsync,data_enable,frame_start,panel_enable,
    output wire [10:0] active_x,next_active_x,
    output wire [9:0] active_y
);
    reg [10:0] horizontal;
    reg [9:0] vertical;
    localparam integer H_TOTAL=1024;
    localparam integer V_TOTAL=625;
    wire [10:0] next_horizontal = horizontal==H_TOTAL-1 ? 11'd0 : horizontal+11'd1;
    // The dashboard spans the full active width, so panel_x tracks the
    // active region directly and relative_x needs no offset.
    wire next_panel_x=next_horizontal<11'd800;
    wire panel_x=horizontal<11'd800;
    wire panel_y=vertical>=10'd60 && vertical<10'd540;
    wire [9:0] relative_y=vertical-10'd60;
    assign data_enable=horizontal<11'd800 && vertical<10'd600;
    assign hsync=horizontal>=11'd824 && horizontal<11'd896;
    assign vsync=vertical>=10'd601 && vertical<10'd603;
    assign frame_start=horizontal==11'd0 && vertical==10'd0;
    assign panel_enable=panel_x && panel_y;
    assign active_x=panel_enable ? horizontal : 11'h7ff;
    assign active_y=panel_enable ? relative_y : 10'h3ff;
    assign next_active_x=next_panel_x && panel_y ? next_horizontal : 11'h7ff;
    always @(posedge pixel_clk or negedge reset_n) begin
        if(!reset_n) begin horizontal<=11'd0;vertical<=10'd0;end
        else begin
            horizontal<=next_horizontal;
            if(horizontal==H_TOTAL-1)
                vertical<=vertical==V_TOTAL-1 ? 10'd0 : vertical+10'd1;
        end
    end
endmodule
`default_nettype wire
