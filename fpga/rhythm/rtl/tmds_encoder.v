`default_nettype none
// DVI 1.0 TMDS, one channel. Capture input, then emit the corresponding
// symbol on the next pixel edge (two registers, throughput one pixel/clock).
// Blank/control symbols reset running disparity. Serializer sends bit0 first.
module tmds_encoder (
    input wire pixel_clk, reset_n, de,
    input wire [7:0] data,
    input wire [1:0] control,
    output reg [9:0] symbol
);
    reg [8:0] transition;
    reg de_q;
    reg [1:0] control_q;
    reg signed [5:0] disparity;
    reg [8:0] transition_next;
    reg [3:0] input_ones, transition_ones;
    reg use_xnor;
    reg signed [5:0] balance, disparity_next;
    reg [9:0] symbol_next;
    integer i;
    always @* begin
        input_ones=4'd0;
        for(i=0;i<8;i=i+1) input_ones=input_ones+{3'd0,data[i]};
        use_xnor=(input_ones>4'd4) || ((input_ones==4'd4) && !data[0]);
        transition_next[0]=data[0];
        for(i=1;i<8;i=i+1)
            transition_next[i]=transition_next[i-1] ^ data[i] ^ use_xnor;
        transition_next[8]=!use_xnor;
        transition_ones=4'd0;
        for(i=0;i<8;i=i+1) transition_ones=transition_ones+{3'd0,transition[i]};
        balance=$signed({1'b0,transition_ones,1'b0})-6'sd8;
        symbol_next=10'd0;
        disparity_next=6'sd0;
        if (!de_q) begin
            case(control_q)
                2'b00:symbol_next=10'b1101010100;
                2'b01:symbol_next=10'b0010101011;
                2'b10:symbol_next=10'b0101010100;
                2'b11:symbol_next=10'b1010101011;
            endcase
        end else if (disparity==6'sd0 || balance==6'sd0) begin
            symbol_next={~transition[8],transition[8],
                (transition[8]?transition[7:0]:~transition[7:0])};
            disparity_next=disparity+(transition[8]?balance:-balance);
        end else if ((disparity>6'sd0 && balance>6'sd0) ||
                     (disparity<6'sd0 && balance<6'sd0)) begin
            symbol_next={1'b1,transition[8],~transition[7:0]};
            disparity_next=disparity-balance+(transition[8]?6'sd2:6'sd0);
        end else begin
            symbol_next={1'b0,transition[8],transition[7:0]};
            disparity_next=disparity+balance-(transition[8]?6'sd0:6'sd2);
        end
    end
    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            transition<=9'd0;de_q<=0;control_q<=0;
            disparity<=0;symbol<=10'b1101010100;
        end else begin
            transition<=transition_next;de_q<=de;control_q<=control;
            disparity<=disparity_next;symbol<=symbol_next;
        end
    end
endmodule
`default_nettype wire
