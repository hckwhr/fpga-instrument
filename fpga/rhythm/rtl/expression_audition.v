`default_nettype none
// Four seconds of the same C-G-C phrase, dry then wet, through the live DDS.
// The last 250 ms reset the voice history at silence for a repeatable A/B.
module expression_audition #(parameter integer CE_ENABLE=0) (
    input wire clock_enable,
    
    input wire clk, reset_n, sample_strobe, enable, percussive,
    output reg wet,
    output wire mute,
    output wire [2:0] gates,
    output wire [3:0] note,
    output wire [2:0] trigger,
    output wire [6:0] force_level
);
    reg [17:0] sample_index;
    reg [2:0] gates_q;
    reg [3:0] note_q;
    reg [2:0] trigger_q;
    reg [6:0] force_level_q;
    wire [2:0] gates_comb = (enable && (percussive ?
        (sample_index<18'd12000 || (sample_index>=18'd36000 && sample_index<18'd48000) ||
         (sample_index>=18'd72000 && sample_index<18'd84000)) : sample_index<18'd144000)) ? 3'b001 : 3'b000;
    wire [2:0] trigger_comb = enable && (sample_index==0 || sample_index==18'd36000 || sample_index==18'd72000) ? 3'b001:3'b000;
    wire [6:0] force_level_comb=(sample_index<18'd36000) ? 7'd32 : (sample_index<18'd72000) ? 7'd80 : 7'd127;
    wire [3:0] note_comb = (sample_index >= 18'd36000 && sample_index < 18'd72000)
        ? 4'd7 : 4'd0;
    assign mute = !enable || sample_index >= 18'd180000;
    assign gates = gates_q;
    assign trigger = trigger_q;
    assign force_level = force_level_q;
    assign note = note_q;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            sample_index<=0; wet<=0;
            gates_q<=0; note_q<=0; trigger_q<=0; force_level_q<=0;
        end
        else if ((!CE_ENABLE || clock_enable)) if (!enable) begin
            sample_index<=0; wet<=0;
            gates_q<=0; note_q<=0; trigger_q<=0; force_level_q<=0;
        end
        else if (sample_strobe) begin
            gates_q<=gates_comb;
            note_q<=note_comb;
            trigger_q<=trigger_comb;
            force_level_q<=force_level_comb;
            if (sample_index==18'd191999) begin sample_index<=0; wet<=~wet; end
            else sample_index<=sample_index+18'd1;
        end
    end
endmodule
`default_nettype wire
