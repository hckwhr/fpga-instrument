`default_nettype none
// Per-voice pitch control, at 48 kHz. Glide durations are approximately
// 4096/8192/16384 samples. Vibrato changes frequency, never amplitude.
module pitch_expression #(parameter integer CE_ENABLE=0) (
    input wire clock_enable,
    
    input wire clk, reset_n, sample_strobe, enable, active, note_start,
    input wire [31:0] target_increment, start_increment,
    input wire start_valid,
    input wire [1:0] glide_select,
    input wire [7:0] vibrato_depth,
    input wire signed [7:0] lfo,
    input wire signed [7:0] bend,
    output wire [31:0] expressed_increment
);
    reg [31:0] base_increment, target, glide_step;
    reg [14:0] glide_left;
    // Compute each possible starting distance before selecting by activity.
    // This keeps the gain -> active flag out of the 32-bit subtract/step path.
    // No extra clock stage: even parameters changed on a sample edge are exact.
    function [31:0] step_from;
        input [31:0] destination, origin;
        input [1:0] speed;
        reg [31:0] distance;
        begin
            distance = (destination >= origin) ? destination-origin : origin-destination;
            step_from = (speed==2'd1) ? (distance>>12)+32'd1 :
                (speed==2'd2) ? (distance>>13)+32'd1 : (distance>>14)+32'd1;
        end
    endfunction
    wire [31:0] active_step = step_from(target_increment, base_increment, glide_select);
    wire [31:0] idle_step = step_from(target_increment, start_increment, glide_select);
    wire active_can_glide = base_increment!=32'd0 && target_increment!=base_increment;
    wire idle_can_glide = start_valid && start_increment!=32'd0 && target_increment!=start_increment;
    wire [14:0] duration = (glide_select==1)?15'd4096:
        (glide_select==2)?15'd8192:15'd16384;
    wire [31:0] error_distance = (target >= base_increment)
        ? target-base_increment : base_increment-target;
    // Bypass preserves the previous DDS frequency word exactly when off.
    wire [31:0] unmodulated = (glide_select==0) ? target_increment : base_increment;
    reg signed [32:0] modulation_product;
    reg signed [41:0] depth_product;
    wire [7:0] bounded_depth=(vibrato_depth>128)?8'd128:vibrato_depth;
    wire signed [32:0] modulation=depth_product>>>11;
    `include "bend_curve.vh"
    // -128 and +127 map to exactly -2/+2 semitones; interpolate 1/4-semitone anchors.
    wire [8:0] bend_position=(bend==127)?9'd256:
        ({bend[7],bend}+9'd128);
    wire [4:0] bend_index=bend_position[8:4];
    wire signed [16:0] bend_base=bend_anchor(bend_index);
    wire signed [17:0] bend_difference=$signed(bend_anchor(bend_index+5'd1))-$signed(bend_base);
    reg signed [22:0] curve_product;
    reg signed [16:0] curve_base;
    wire signed [22:0] curve_sum=$signed({{6{curve_base[16]}},curve_base})+(curve_product>>>4);
    reg signed [16:0] bend_delta;
    reg signed [41:0] bend_product;
    wire signed [32:0] bend_modulation=bend_product>>>10;
    wire signed [33:0] modulated = $signed({2'd0,unmodulated})+
        $signed({modulation[32],modulation})+$signed({bend_modulation[32],bend_modulation});
    reg [3:0] ready;
    always @(posedge clk) if ((!CE_ENABLE || clock_enable)) begin
        modulation_product <= $signed({1'b0,unmodulated[31:8]}) * lfo;
        depth_product <= modulation_product*$signed({1'b0,bounded_depth});
        curve_base <= bend_base;
        curve_product <= bend_difference*$signed({1'b0,bend_position[3:0]});
        bend_delta <= curve_sum[16:0];
        bend_product <= $signed({1'b0,unmodulated[31:8]})*bend_delta;
    end
    assign expressed_increment = ((vibrato_depth==0 && bend==0) || !ready[3]) ? unmodulated :
        modulated[33] ? 32'd0 : modulated[32] ? 32'hffffffff : modulated[31:0];

    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            base_increment<=0; target<=0; glide_step<=0; glide_left<=0; ready<=0;
        end else if ((!CE_ENABLE || clock_enable)) if(!enable) begin
            base_increment<=0; target<=0; glide_step<=0; glide_left<=0; ready<=0;
        end else begin
            ready<={ready[2:0],1'b1};
            if(sample_strobe) begin
                if(glide_select==0) begin
                    base_increment<=target_increment; target<=target_increment; glide_left<=0;
                end else if(note_start || (active && target_increment!=target)) begin
                    target<=target_increment;
                    if(active ? active_can_glide : idle_can_glide) begin
                        base_increment<=active ? base_increment : start_increment;
                        glide_step<=active ? active_step : idle_step;
                        glide_left<=duration;
                    end else begin base_increment<=target_increment; glide_left<=0; end
                end else if(glide_left!=0) begin
                    if(glide_left==1 || error_distance<=glide_step) begin
                        base_increment<=target; glide_left<=0;
                    end else begin
                        base_increment<=(base_increment<target)?base_increment+glide_step:
                            base_increment-glide_step;
                        glide_left<=glide_left-15'd1;
                    end
                end else if(!active) begin base_increment<=target_increment; target<=target_increment; end
            end
        end
    end
endmodule
`default_nettype wire
