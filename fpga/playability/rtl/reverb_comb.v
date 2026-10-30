`default_nettype none
// Normalized damped feedback comb. Stale RAM is masked after each restart.
module reverb_comb #(parameter integer CE_ENABLE=0,
    parameter integer LENGTH=1499)(
    input wire clock_enable,
    
    input wire clk, reset_n, sample_strobe, enable,
    input wire signed [15:0] sample_in,
    output reg signed [15:0] sample_out
);
    (* syn_ramstyle="block_ram" *) reg signed [15:0] memory[0:2047];
    reg [10:0] pointer, filled;
    reg [2:0] step;
    reg signed [15:0] tap, input_hold, damped;
    wire signed [16:0] damp_sum=$signed({tap[15],tap})+$signed({damped[15],damped});
    wire signed [16:0] feedback=$signed({input_hold[15],input_hold})/17'sd4+
        $signed({damped[15],damped})/17'sd2+$signed({damped[15],damped})/17'sd4;
    always @(posedge clk) if ((!CE_ENABLE || clock_enable)) begin
        if(sample_strobe && enable) tap<=memory[pointer];
        if(step==3'd2 && enable) memory[pointer]<=feedback[15:0];
    end
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin pointer<=0;filled<=0;step<=0;damped<=0;input_hold<=0;sample_out<=0;end
        else if ((!CE_ENABLE || clock_enable)) if(!enable) begin pointer<=0;filled<=0;step<=0;damped<=0;input_hold<=0;sample_out<=0;end
        else if(sample_strobe) begin input_hold<=sample_in;step<=1;end
        else case(step)
            1:begin
                damped<=(filled>=LENGTH)?damp_sum/17'sd2:16'sd0;
                sample_out<=(filled>=LENGTH)?tap:16'sd0;
                step<=2;
            end
            2:begin
                pointer<=(pointer==LENGTH-1)?11'd0:pointer+11'd1;
                if(filled<LENGTH) filled<=filled+11'd1;
                step<=0;
            end
            default:step<=0;
        endcase
    end
endmodule
`default_nettype wire
