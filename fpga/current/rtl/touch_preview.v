`default_nettype none
// Read-only 256x150 RGB inset: HDMI touch surface at 1/4 scale.
// Frame snapshot, two-pixel latency; no audio/menu actions.
module touch_preview (
    input wire clk, reset_n, frame_start, data_enable,
    input wire [10:0] pixel_x, pixel_y,
    input wire [24:0] touch_status,
    output reg overlay,
    output reg [17:0] rgb
);
    reg [24:0] frame_touch;
    reg overlay_s0;
    reg [17:0] rgb_s0;
    wire online=frame_touch[24], down=frame_touch[23];
    wire [2:0] count=frame_touch[22:20];
    wire [10:0] mark_x=11'd528+{3'b0,frame_touch[19:12]};
    wire [10:0] mark_y=11'd16+{3'b0,frame_touch[9:2]};
    wire inside_box=pixel_x>=11'd528 && pixel_x<=11'd783 && pixel_y>=11'd16 && pixel_y<=11'd165;
    wire border=pixel_x==11'd528 || pixel_x==11'd783 || pixel_y==11'd16 || pixel_y==11'd165;
    wire crosshair=(pixel_x==mark_x || pixel_y==mark_y);
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin frame_touch<=0;overlay_s0<=0;rgb_s0<=0;overlay<=0;rgb<=0; end
        else begin
            if (frame_start) frame_touch<=touch_status;
            overlay_s0<=data_enable && online && inside_box && (border || (down && crosshair));
            rgb_s0<=border?18'h00fc0:((count>1)?18'h3f000:18'h3ffff);
            overlay<=overlay_s0;rgb<=rgb_s0;
        end
    end
endmodule
`default_nettype wire
