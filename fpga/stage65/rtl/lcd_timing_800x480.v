`default_nettype none

module lcd_timing_800x480 #(
    parameter [10:0] H_ACTIVE = 11'd800,
    parameter [10:0] H_FRONT  = 11'd210,
    parameter [10:0] H_SYNC   = 11'd1,
    parameter [10:0] H_BACK   = 11'd46,
    parameter [9:0]  V_ACTIVE = 10'd480,
    parameter [9:0]  V_FRONT  = 10'd22,
    parameter [9:0]  V_SYNC   = 10'd1,
    parameter [9:0]  V_BACK   = 10'd23
) (
    input  wire        pixel_clk,
    input  wire        reset_n,
    output wire        hsync,
    output wire        vsync,
    output wire        data_enable,
    output wire        frame_start,
    output wire [10:0] active_x,
    output wire [9:0]  active_y
);

    localparam [10:0] H_TOTAL      = H_ACTIVE + H_FRONT + H_SYNC + H_BACK;
    localparam [10:0] H_SYNC_START = H_ACTIVE + H_FRONT;
    localparam [10:0] H_SYNC_END   = H_ACTIVE + H_FRONT + H_SYNC;
    localparam [9:0]  V_TOTAL      = V_ACTIVE + V_FRONT + V_SYNC + V_BACK;
    localparam [9:0]  V_SYNC_START = V_ACTIVE + V_FRONT;
    localparam [9:0]  V_SYNC_END   = V_ACTIVE + V_FRONT + V_SYNC;

    reg [10:0] h_count;
    reg [9:0]  v_count;

    assign active_x    = h_count;
    assign active_y    = v_count;
    assign data_enable = (h_count < H_ACTIVE) && (v_count < V_ACTIVE);
    assign hsync       = !((h_count >= H_SYNC_START) && (h_count < H_SYNC_END));
    assign vsync       = !((v_count >= V_SYNC_START) && (v_count < V_SYNC_END));
    assign frame_start = (h_count == 11'd0) && (v_count == 10'd0);

    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            h_count <= 11'd0;
            v_count <= 10'd0;
        end else if (h_count == H_TOTAL - 11'd1) begin
            h_count <= 11'd0;

            if (v_count == V_TOTAL - 10'd1)
                v_count <= 10'd0;
            else
                v_count <= v_count + 10'd1;
        end else begin
            h_count <= h_count + 11'd1;
        end
    end

endmodule

`default_nettype wire
