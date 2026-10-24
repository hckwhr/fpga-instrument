`default_nettype none
// 96 ticks per quarter. Four exact integer periods at nominal 48 kHz.
// Lookup settles for two clocks before the scheduler's next sample strobe.
// Tempo is changed only in settings (the player is then disabled).
module song_timing #(parameter integer CE_ENABLE=0) (
    input wire clock_enable,
    
    input wire clk,
    input wire [1:0] tempo_select,
    input wire [11:0] duration_ticks, gate_ticks,
    output reg [23:0] duration_samples, gate_samples
);
    reg [8:0] samples_per_tick = 9'd300;
    always @(posedge clk) if ((!CE_ENABLE || clock_enable)) begin
        case (tempo_select)
            2'd0: samples_per_tick <= 9'd375;
            2'd1: samples_per_tick <= 9'd300;
            2'd2: samples_per_tick <= 9'd250;
            default: samples_per_tick <= 9'd200;
        endcase
        duration_samples <= {12'd0,duration_ticks} * {15'd0,samples_per_tick};
        gate_samples <= {12'd0,gate_ticks} * {15'd0,samples_per_tick};
    end
endmodule
`default_nettype wire
