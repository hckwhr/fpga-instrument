`default_nettype none
// Shared reciprocal pitch ratio. One 37-enabled-step restoring divide per
// sample, independent of the eight parallel string feedback engines. At the
// common half-rate CE, 512 steps/1024 physical clocks leave >13x the divide
// budget; the unchanged PT8211 divider fixes this interval on the board.
module string_pitch_control #(parameter integer CE_ENABLE=0) (
    input wire clock_enable,
    
    input wire clk, reset_n, sample_strobe, enable,
    input wire signed [7:0] bend,
    input wire [7:0] vibrato_depth,
    output reg signed [16:0] delay_delta
);
    reg [23:0] phase;
    wire [7:0] triangle = phase[23] ? ~phase[22:15] : phase[22:15];
    wire signed [7:0] lfo = $signed(triangle ^ 8'h80);
    wire [31:0] ratio;
    reg [36:0] numerator, quotient;
    reg [18:0] denominator;
    reg [19:0] remainder;
    reg [5:0] left;
    wire [19:0] trial = {remainder[18:0],numerator[36]};
    wire subtract = trial >= {1'b0,denominator};
    wire [36:0] next_quotient = {quotient[35:0],subtract};
    wire signed [19:0] next_delta = $signed({1'b0,next_quotient[18:0]})-20'sd262144;
    pitch_expression #(.CE_ENABLE(CE_ENABLE)) expression (.clock_enable(clock_enable),.clk(clk),.reset_n(reset_n),.sample_strobe(sample_strobe),
        .enable(enable),.active(1'b1),.note_start(1'b0),.target_increment(32'd262144),
        .start_increment(32'd0),.start_valid(1'b0),.glide_select(2'd0),
        .vibrato_depth(vibrato_depth),.lfo(lfo),.bend(bend),.expressed_increment(ratio));
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n)begin
            phase<=24'h400000;delay_delta<=0;left<=0;numerator<=0;
            quotient<=0;denominator<=19'd262144;remainder<=0;
        end else if ((!CE_ENABLE || clock_enable)) if(!enable)begin phase<=24'h400000;delay_delta<=0;left<=0;end
        else if(sample_strobe)begin
            phase<=phase+24'd1748;
            if(ratio==32'd262144)begin delay_delta<=0;left<=0;end
            else begin
                // Legal +/-2-semitone bend plus maximum vibrato lies inside
                // these limits. Clamp malformed parameters before division.
                denominator<=ratio<32'd220000 ? 19'd220000 :
                    ratio>32'd310000 ? 19'd310000 : ratio[18:0];
                numerator<=37'h1000000000;quotient<=0;remainder<=0;left<=6'd37;
            end
        end else if(left!=0)begin
            numerator<={numerator[35:0],1'b0};quotient<=next_quotient;
            remainder<=subtract ? trial-{1'b0,denominator} : trial;
            left<=left-6'd1;
            // floor(2^36 / [220000,310000]) - 2^18 is [-40469,50217].
            // Fits signed 17 bits: each voice can use one 27x18 DSP multiplier.
            if(left==1)delay_delta<=next_delta[16:0];
        end
    end
endmodule
`default_nettype wire
