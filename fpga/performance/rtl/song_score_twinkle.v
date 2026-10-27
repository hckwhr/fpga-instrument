`default_nettype none

// Two verses separated by a two-beat rest: 85 rows, 98 beats.
// One quarter = 96 ticks. Note 15 denotes an explicit rest.
module song_score_twinkle (
    input  wire [7:0] index,
    output reg  [3:0] note,
    output reg  [11:0] duration_ticks,
    output wire [11:0] gate_ticks,
    output wire [1:0] octave,
    output wire [6:0] force_level,
    output wire [7:0] length
);
    wire [7:0] row = index > 8'd42 ? index-8'd43 : index;
    localparam [11:0] SHORT_DURATION = 12'd96;
    localparam [11:0] LONG_DURATION  = 12'd192;
    assign length = 8'd85;
    assign gate_ticks = note==4'd15 ? 12'd0 : duration_ticks-12'd6;
    assign octave = 2'd1;
    assign force_level = 7'd96;

    always @* begin
        note = 4'd0;
        duration_ticks = SHORT_DURATION;
        case (row)
            6'd0, 6'd1, 6'd13, 6'd28, 6'd29, 6'd41: note = 4'd0;
            6'd2, 6'd3, 6'd6, 6'd14, 6'd15, 6'd21, 6'd22,
            6'd30, 6'd31, 6'd34: note = 4'd7;
            6'd4, 6'd5, 6'd32, 6'd33: note = 4'd9;
            6'd7, 6'd8, 6'd16, 6'd17, 6'd23, 6'd24,
            6'd35, 6'd36: note = 4'd5;
            6'd9, 6'd10, 6'd18, 6'd19, 6'd25, 6'd26,
            6'd37, 6'd38: note = 4'd4;
            6'd11, 6'd12, 6'd20, 6'd27, 6'd39, 6'd40: note = 4'd2;
            default: note = 4'd0;
        endcase
        case (row)
            6'd6, 6'd13, 6'd20, 6'd27, 6'd34, 6'd41:
                duration_ticks = LONG_DURATION;
            default: duration_ticks = SHORT_DURATION;
        endcase
        if(index==8'd42) begin note=4'd15; duration_ticks=LONG_DURATION; end
        if(index>=8'd85) begin note=4'd15; duration_ticks=12'd0; end
    end
endmodule
`default_nettype wire
