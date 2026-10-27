`default_nettype none
// Single outstanding byte, held until destination consumption acknowledges it.
// Both resets must assert together; releases are synchronous in each domain.
module uart_byte_cdc #(parameter integer SRC_CE_ENABLE=0, parameter integer DST_CE_ENABLE=0,
    parameter integer WIDTH=8) (
    input wire src_clock_enable, dst_clock_enable,
    
    input wire src_clk,src_reset_n,
    input wire [WIDTH-1:0] src_data,
    input wire src_valid,
    output wire src_ready,
    input wire dst_clk,dst_reset_n,
    output wire [WIDTH-1:0] dst_data,
    output wire dst_valid,
    input wire dst_ready
);
    reg [WIDTH-1:0] payload;
    reg request,ack;
    reg [1:0] ack_sync,request_sync;
    assign src_ready=src_reset_n && request==ack_sync[1];
    assign dst_valid=dst_reset_n && request_sync[1]!=ack;
    assign dst_data=payload;
    always @(posedge src_clk or negedge src_reset_n)begin
        if(!src_reset_n)begin payload<=0;request<=0;ack_sync<=0;end
        else if ((!SRC_CE_ENABLE || src_clock_enable)) begin
            ack_sync<={ack_sync[0],ack};
            if(src_valid && src_ready)begin payload<=src_data;request<=!request;end
        end
    end
    always @(posedge dst_clk or negedge dst_reset_n)begin
        if(!dst_reset_n)begin request_sync<=0;ack<=0;end
        else if ((!DST_CE_ENABLE || dst_clock_enable)) begin
            request_sync<={request_sync[0],request};
            if(dst_valid && dst_ready)ack<=request_sync[1];
        end
    end
endmodule
`default_nettype wire
