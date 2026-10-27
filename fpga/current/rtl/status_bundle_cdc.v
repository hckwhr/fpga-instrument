`default_nettype none

module status_bundle_cdc #(parameter integer SRC_CE_ENABLE=0, parameter integer DST_CE_ENABLE=0,
    
    parameter integer WIDTH = 19
) (
    input wire src_clock_enable, dst_clock_enable,
    
    input  wire             src_clk,
    input  wire             src_reset_n,
    input  wire [WIDTH-1:0] src_payload,
    input  wire             dst_clk,
    input  wire             dst_reset_n,
    output reg  [WIDTH-1:0] dst_payload,
    output reg              dst_update
);

    reg [WIDTH-1:0] src_payload_hold;
    reg [WIDTH-1:0] src_last_sent;
    reg             src_initialized;
    reg             request_toggle_src;
    reg [1:0]       acknowledge_sync_src;

    reg [1:0] request_sync_dst;
    reg       request_seen_dst;
    reg       acknowledge_toggle_dst;

    wire src_busy;

    assign src_busy = request_toggle_src ^ acknowledge_sync_src[1];

    always @(posedge src_clk or negedge src_reset_n) begin
        if (!src_reset_n) begin
            src_payload_hold     <= {WIDTH{1'b0}};
            src_last_sent        <= {WIDTH{1'b0}};
            src_initialized      <= 1'b0;
            request_toggle_src   <= 1'b0;
            acknowledge_sync_src <= 2'b00;
        end else if ((!SRC_CE_ENABLE || src_clock_enable)) begin
            acknowledge_sync_src <= {
                acknowledge_sync_src[0], acknowledge_toggle_dst
            };

            if (!src_busy && (!src_initialized || (src_payload != src_last_sent))) begin
                src_payload_hold   <= src_payload;
                src_last_sent      <= src_payload;
                src_initialized    <= 1'b1;
                request_toggle_src <= ~request_toggle_src;
            end
        end
    end

    always @(posedge dst_clk or negedge dst_reset_n) begin
        if (!dst_reset_n) begin
            request_sync_dst       <= 2'b00;
            request_seen_dst       <= 1'b0;
            acknowledge_toggle_dst <= 1'b0;
            dst_payload            <= {WIDTH{1'b0}};
            dst_update             <= 1'b0;
        end else if ((!DST_CE_ENABLE || dst_clock_enable)) begin
            request_sync_dst <= {request_sync_dst[0], request_toggle_src};
            dst_update       <= 1'b0;

            if (request_sync_dst[1] != request_seen_dst) begin
                dst_payload            <= src_payload_hold;
                dst_update             <= 1'b1;
                request_seen_dst       <= request_sync_dst[1];
                acknowledge_toggle_dst <= request_sync_dst[1];
            end
        end
    end

endmodule

`default_nettype wire

