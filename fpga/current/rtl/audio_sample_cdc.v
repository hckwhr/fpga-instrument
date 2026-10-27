`default_nettype none

module audio_sample_cdc #(parameter integer SRC_CE_ENABLE=0, parameter integer DST_CE_ENABLE=0,
    parameter integer WIDTH=16) (
    input wire src_clock_enable, dst_clock_enable,
    
    input  wire               src_clk,
    input  wire               src_reset_n,
    input  wire signed [WIDTH-1:0] src_sample,
    input  wire               src_sample_strobe,
    input  wire               dst_clk,
    input  wire               dst_reset_n,
    output reg signed [WIDTH-1:0]  dst_sample,
    output reg                dst_sample_valid
);

    reg signed [WIDTH-1:0] src_data_hold;
    reg               src_request_toggle;
    reg [1:0]         src_ack_sync;
    reg [1:0]         dst_request_sync;
    reg               dst_request_seen;
    reg               dst_ack_toggle;

    // The source holds the complete sample stable until the destination ACKs it.
    always @(posedge src_clk or negedge src_reset_n) begin
        if (!src_reset_n) begin
            src_data_hold      <= {WIDTH{1'b0}};
            src_request_toggle <= 1'b0;
            src_ack_sync       <= 2'b00;
        end else if ((!SRC_CE_ENABLE || src_clock_enable)) begin
            src_ack_sync <= {src_ack_sync[0], dst_ack_toggle};

            if (src_sample_strobe && (src_ack_sync[1] == src_request_toggle)) begin
                src_data_hold      <= src_sample;
                src_request_toggle <= ~src_request_toggle;
            end
        end
    end

    // The synchronized toggle arrives after the held data has settled.
    always @(posedge dst_clk or negedge dst_reset_n) begin
        if (!dst_reset_n) begin
            dst_request_sync <= 2'b00;
            dst_request_seen <= 1'b0;
            dst_ack_toggle   <= 1'b0;
            dst_sample       <= {WIDTH{1'b0}};
            dst_sample_valid <= 1'b0;
        end else if ((!DST_CE_ENABLE || dst_clock_enable)) begin
            dst_request_sync <= {dst_request_sync[0], src_request_toggle};
            dst_sample_valid <= 1'b0;

            if (dst_request_sync[1] != dst_request_seen) begin
                dst_sample       <= src_data_hold;
                dst_sample_valid <= 1'b1;
                dst_request_seen <= dst_request_sync[1];
                dst_ack_toggle   <= dst_request_sync[1];
            end
        end
    end

endmodule

`default_nettype wire
