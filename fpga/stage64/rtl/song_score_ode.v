`default_nettype none
// Ode to Joy main theme, C major, two 8-bar phrases (30 attacks / 32 beats).
// Public-domain melody; the second ending resolves D to C.
module song_score_ode (
    input wire [7:0] index,
    output reg [3:0] note,
    output reg [11:0] duration_ticks,
    output wire [11:0] gate_ticks,
    output wire [1:0] octave,
    output wire [6:0] force_level,
    output wire [7:0] length
);
    assign length=8'd30;
    assign gate_ticks=(duration_ticks==0)?12'd0:duration_ticks-12'd6;
    assign octave=2'd1;
    assign force_level=7'd96;
    always @* begin
        case(index)
            0,1,6,11,12,15,16,21,26: note=4'd4;
            2,5,17,20: note=4'd5;
            3,4,18,19: note=4'd7;
            7,10,13,14,22,25,27: note=4'd2;
            default: note=4'd0;
        endcase
        case(index)
            12,27: duration_ticks=12'd144;
            13,28: duration_ticks=12'd48;
            14,29: duration_ticks=12'd192;
            default: duration_ticks=12'd96;
        endcase
        if(index>=8'd30) begin note=4'd15; duration_ticks=12'd0; end
    end
endmodule
`default_nettype wire
