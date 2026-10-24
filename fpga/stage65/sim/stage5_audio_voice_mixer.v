`default_nettype none

module stage5_audio_voice_mixer #(
    parameter [7:0] ATTACK_STEP = 8'd1,
    parameter [7:0] DECAY_INTERVAL_LAST = 8'd191,
    parameter [7:0] ADSR_DECAY_INTERVAL_LAST = 8'd15,
    parameter [7:0] TOUCH_RELEASE_INTERVAL_LAST = 8'd47,
    parameter integer FILTER_SHIFT = 1,
    parameter integer PIANO_FILTER_SHIFT = 1
) (
    input  wire               clk,
    input  wire               reset_n,
    input  wire               sample_strobe,
    input  wire [2:0]         voice_trigger,
    input  wire [2:0]         voice_gate,
    input  wire               mute,
    input  wire               song_release,
    input  wire               play_mode,
    input  wire [1:0]         tone_select,
    input  wire [3:0]         note_select,
    input  wire               keymap_select,
    input  wire [1:0]         octave_select,
    input  wire [6:0]         force_value,
    input  wire [1:0]         glide_select,
    input  wire [7:0]         vibrato_depth,
    input  wire signed [7:0]  bend,
    output wire signed [15:0] sample
);

    reg [31:0] voice0_phase_accumulator;
    reg [31:0] voice1_phase_accumulator;
    reg [31:0] voice2_phase_accumulator;
    reg [31:0] voice3_phase_accumulator;
    reg [7:0]  voice0_gain;
    reg [7:0]  voice1_gain;
    reg [7:0]  voice2_gain;
    reg [7:0]  voice3_gain;
    reg [7:0]  voice0_decay_count;
    reg [7:0]  voice1_decay_count;
    reg [7:0]  voice2_decay_count;
    reg [7:0]  voice3_decay_count;
    reg        voice0_attacking;
    reg        voice1_attacking;
    reg        voice2_attacking;
    reg        voice3_attacking;
    reg        voice0_decaying;
    reg        voice1_decaying;
    reg        voice2_decaying;
    reg        voice3_decaying;
    reg [2:0]  voice_gate_previous;
    reg        voice3_gate_previous;
    reg [2:0]  trigger_pending;
    reg [3:0]  chord_root_offset;
    reg [2:0]  chord_gate_previous;
    reg signed [17:0] filtered_sample;

    wire [2:0] trigger_now;
    wire [2:0] trigger_effective;
    wire [2:0] voice_gate_effective;
    wire       voice3_gate_effective;
    wire       voice3_trigger_now;
    wire [4:0] chord_root_note_sum;
    wire [4:0] voice0_note_sum;
    wire [4:0] voice1_note_sum;
    wire [4:0] voice2_note_sum;
    wire [4:0] voice3_note_sum;
    wire [31:0] voice0_phase_increment;
    wire [31:0] voice1_phase_increment;
    wire [31:0] voice2_phase_increment;
    wire [31:0] voice3_phase_increment;
    wire [7:0] requested_gain;
    wire [7:0] sustain_gain;
    wire [7:0] voice3_requested_gain;
    wire [7:0] voice3_sustain_gain;
    wire [8:0] voice0_attack_sum;
    wire [8:0] voice1_attack_sum;
    wire [8:0] voice2_attack_sum;
    wire [8:0] voice3_attack_sum;
    wire signed [15:0] voice0_wave;
    wire signed [15:0] voice1_wave;
    wire signed [15:0] voice2_wave;
    wire signed [15:0] voice3_wave;
    wire signed [8:0] voice0_gain_signed;
    wire signed [8:0] voice1_gain_signed;
    wire signed [8:0] voice2_gain_signed;
    wire signed [8:0] voice3_gain_signed;
    wire signed [24:0] voice0_scaled;
    wire signed [24:0] voice1_scaled;
    wire signed [24:0] voice2_scaled;
    wire signed [24:0] voice3_scaled;
    wire signed [26:0] mixed_scaled;
    wire signed [26:0] mixed_sample;
    wire signed [15:0] raw_sample;
    wire signed [17:0] raw_sample_extended;
    wire signed [18:0] filter_error;
    wire signed [18:0] filter_step;
    wire [2:0] active_voice_count;
    reg [31:0] expression_target [0:3];
    wire [31:0] expression_result [0:3];
    wire [31:0] expression_increment [0:3];
    wire [3:0] expression_active, expression_start;
    reg [31:0] last_note_increment;
    reg last_note_valid;
    reg [23:0] vibrato_phase;
    wire [7:0] vibrato_triangle = vibrato_phase[23] ? ~vibrato_phase[22:15] : vibrato_phase[22:15];
    wire signed [7:0] vibrato_lfo = $signed(vibrato_triangle ^ 8'h80);
    // Separate note lookup from pitch arithmetic. Parameters settle hundreds
    // of clocks before the next audio slot; the disabled path stays exact.
    always @(posedge clk) begin
        expression_target[0]<=voice0_phase_increment;
        expression_target[1]<=voice1_phase_increment;
        expression_target[2]<=voice2_phase_increment;
        expression_target[3]<=voice3_phase_increment;
    end
    assign expression_increment[0]=(glide_select==0 && vibrato_depth==0 && bend==0)?voice0_phase_increment:expression_result[0];
    assign expression_increment[1]=(glide_select==0 && vibrato_depth==0 && bend==0)?voice1_phase_increment:expression_result[1];
    assign expression_increment[2]=(glide_select==0 && vibrato_depth==0 && bend==0)?voice2_phase_increment:expression_result[2];
    assign expression_increment[3]=(glide_select==0 && vibrato_depth==0 && bend==0)?voice3_phase_increment:expression_result[3];
    assign expression_active={voice3_gain!=0,voice2_gain!=0,voice1_gain!=0,voice0_gain!=0};
    assign expression_start=play_mode ? {voice3_trigger_now,trigger_effective} :
        {voice3_gate_effective && !voice3_gate_previous,voice_gate_effective & ~voice_gate_previous};
    genvar expression_voice;
    generate for(expression_voice=0;expression_voice<4;expression_voice=expression_voice+1) begin: expressions
        pitch_expression pitch (
            .clk(clk),.reset_n(reset_n),.sample_strobe(sample_strobe),.enable(!mute),
            .active(expression_active[expression_voice]),.note_start(expression_start[expression_voice]),
            .target_increment(expression_target[expression_voice]),
            .start_increment(keymap_select ? expression_target[expression_voice] : last_note_increment),
            .start_valid(!keymap_select && last_note_valid),
            .glide_select(glide_select),.vibrato_depth(vibrato_depth),.lfo(vibrato_lfo),
            .bend(bend),
            .expressed_increment(expression_result[expression_voice]));
    end endgenerate
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin last_note_increment<=0; last_note_valid<=0; vibrato_phase<=24'h400000; end
        else if(mute) begin last_note_increment<=0; last_note_valid<=0; vibrato_phase<=24'h400000; end
        else if(sample_strobe) begin
            // 1748 * 48000 / 2^24 = 5.001 Hz, independent of note pitch.
            vibrato_phase<=vibrato_phase+24'd1748;
            if(|expression_start[2:0]) begin
                last_note_increment<=expression_start[2]?voice2_phase_increment:
                    expression_start[1]?voice1_phase_increment:voice0_phase_increment;
                last_note_valid<=1;
            end
        end
    end

    // Fold semitone wrapping and octave carry into the constant table.
    // This removes compare/subtract/add stages without adding cycle latency.
    function [31:0] phase_increment;
        input [4:0] note_sum;
        input [1:0] octave_index;
        reg [31:0] middle_increment;
        begin
            case (note_sum)
                5'd0: middle_increment = 32'd23409859;
                5'd1: middle_increment = 32'd24801882;
                5'd2: middle_increment = 32'd26276679;
                5'd3: middle_increment = 32'd27839171;
                5'd4: middle_increment = 32'd29494575;
                5'd5: middle_increment = 32'd31248413;
                5'd6: middle_increment = 32'd33106541;
                5'd7: middle_increment = 32'd35075158;
                5'd8: middle_increment = 32'd37160835;
                5'd9: middle_increment = 32'd39370534;
                5'd10: middle_increment = 32'd41711627;
                5'd11: middle_increment = 32'd44191930;
                5'd12: middle_increment = 32'd46819718;
                5'd13: middle_increment = 32'd49603764;
                5'd14: middle_increment = 32'd52553358;
                5'd15: middle_increment = 32'd55678342;
                5'd16: middle_increment = 32'd58989150;
                5'd17: middle_increment = 32'd62496826;
                5'd18: middle_increment = 32'd66213082;
                5'd19: middle_increment = 32'd70150316;
                5'd20: middle_increment = 32'd74321670;
                5'd21: middle_increment = 32'd78741068;
                5'd22: middle_increment = 32'd83423254;
                5'd23: middle_increment = 32'd88383860;
                5'd24: middle_increment = 32'd93639436;
                5'd25: middle_increment = 32'd99207528;
                5'd26: middle_increment = 32'd105106716;
                5'd27: middle_increment = 32'd111356684;
                5'd28: middle_increment = 32'd117978300;
                5'd29: middle_increment = 32'd124993652;
                5'd30: middle_increment = 32'd132426164;
                default: middle_increment = 32'd140300632;
            endcase
            case (octave_index)
                2'd0: phase_increment = middle_increment >> 1;
                2'd1: phase_increment = middle_increment;
                2'd2: phase_increment = middle_increment << 1;
                // Preserve the old fallback for the unused octave=3/carry=2.
                default: phase_increment = (note_sum >= 5'd24)
                    ? (middle_increment >> 2) : (middle_increment << 2);
            endcase
        end
    endfunction

    `include "piano_wave.vh"

    function [15:0] waveform_value;
        input [31:0] phase;
        input [1:0] selected_tone;
        reg [15:0] triangle_unsigned_value;
        reg signed [15:0] centered_value;
        begin
            triangle_unsigned_value = phase[31]
                                      ? ~phase[30:15]
                                      :  phase[30:15];
            case (selected_tone)
                2'd0: begin
                    centered_value = $signed(triangle_unsigned_value ^ 16'h8000);
                    waveform_value = centered_value >>> 2;
                end
                2'd1: waveform_value = phase[31] ? -16'sd8192 : 16'sd8191;
                2'd2: begin
                    centered_value = $signed(phase[31:16]);
                    waveform_value = centered_value >>> 2;
                end
                default: waveform_value = piano_wave(phase);
            endcase
        end
    endfunction

    function [3:0] chord_root_for_keys;
        input [2:0] keys;
        begin
            if (keys[2])
                chord_root_for_keys = 4'd7; // V
            else if (keys[1])
                chord_root_for_keys = 4'd5; // IV
            else
                chord_root_for_keys = 4'd0; // I
        end
    endfunction

    assign trigger_now = trigger_pending | voice_trigger;
    assign trigger_effective = keymap_select ? {3{|trigger_now}} : trigger_now;
    assign voice_gate_effective = keymap_select ? {3{|voice_gate}} : voice_gate;
    assign voice3_gate_effective = keymap_select ? |voice_gate : &voice_gate;
    assign voice3_trigger_now = keymap_select
                              ? |trigger_now
                              : ((&voice_gate) && (|trigger_now));
    assign chord_root_note_sum = {1'b0, note_select}
                               + {1'b0, chord_root_offset};
    assign voice0_note_sum = keymap_select
                           ? chord_root_note_sum
                           : {1'b0, note_select};
    assign voice1_note_sum = keymap_select
                           ? chord_root_note_sum + 5'd4
                           : {1'b0, note_select} + 5'd2;
    assign voice2_note_sum = keymap_select
                           ? chord_root_note_sum + 5'd7
                           : {1'b0, note_select} + 5'd4;
    assign voice3_note_sum = keymap_select
                           ? chord_root_note_sum + 5'd12
                           : {1'b0, note_select} + 5'd12;
    assign voice0_phase_increment = phase_increment(voice0_note_sum, octave_select);
    assign voice1_phase_increment = phase_increment(voice1_note_sum, octave_select);
    assign voice2_phase_increment = phase_increment(voice2_note_sum, octave_select);
    assign voice3_phase_increment = phase_increment(voice3_note_sum, octave_select);

    assign requested_gain = (force_value == 7'd127)
                          ? 8'hff : {force_value, 1'b0};
    assign sustain_gain = requested_gain - (requested_gain >> 2);
    assign voice3_requested_gain = requested_gain >> 1;
    assign voice3_sustain_gain = voice3_requested_gain
                               - (voice3_requested_gain >> 2);
    assign voice0_attack_sum = {1'b0, voice0_gain} + {1'b0, ATTACK_STEP};
    assign voice1_attack_sum = {1'b0, voice1_gain} + {1'b0, ATTACK_STEP};
    assign voice2_attack_sum = {1'b0, voice2_gain} + {1'b0, ATTACK_STEP};
    assign voice3_attack_sum = {1'b0, voice3_gain} + {1'b0, ATTACK_STEP};

    assign voice0_wave = $signed(waveform_value(
        voice0_phase_accumulator, tone_select
    ));
    assign voice1_wave = $signed(waveform_value(
        voice1_phase_accumulator, tone_select
    ));
    assign voice2_wave = $signed(waveform_value(
        voice2_phase_accumulator, tone_select
    ));
    assign voice3_wave = $signed(waveform_value(
        voice3_phase_accumulator, tone_select
    ));
    assign voice0_gain_signed = $signed({1'b0, voice0_gain});
    assign voice1_gain_signed = $signed({1'b0, voice1_gain});
    assign voice2_gain_signed = $signed({1'b0, voice2_gain});
    assign voice3_gain_signed = $signed({1'b0, voice3_gain});
    assign voice0_scaled = voice0_wave * voice0_gain_signed;
    assign voice1_scaled = voice1_wave * voice1_gain_signed;
    assign voice2_scaled = voice2_wave * voice2_gain_signed;
    assign voice3_scaled = voice3_wave * voice3_gain_signed;
    assign mixed_scaled = {{2{voice0_scaled[24]}}, voice0_scaled}
                        + {{2{voice1_scaled[24]}}, voice1_scaled}
                        + {{2{voice2_scaled[24]}}, voice2_scaled}
                        + {{2{voice3_scaled[24]}}, voice3_scaled};
    assign active_voice_count = {2'b00, (voice0_gain != 8'd0)}
                              + {2'b00, (voice1_gain != 8'd0)}
                              + {2'b00, (voice2_gain != 8'd0)}
                              + {2'b00, (voice3_gain != 8'd0)};

    // Fixed normalization avoids an audible gain step when the fourth voice
    // joins or leaves a chord. Four full-scale voices remain below clipping.
    assign mixed_sample = mixed_scaled >>> 8;
    assign raw_sample = (mixed_sample > 27'sd32767) ? 16'sh7fff :
                        (mixed_sample < -27'sd32768) ? 16'sh8000 :
                        mixed_sample[15:0];
    assign raw_sample_extended = {{2{raw_sample[15]}}, raw_sample};
    assign filter_error = $signed({raw_sample_extended[17], raw_sample_extended})
                        - $signed({filtered_sample[17], filtered_sample});
    // Preserve audible harmonics for every timbre while rounding sharp edges.
    // At 48 kHz, alpha=1/2 has a -3 dB corner near 5.52 kHz (was ~1.02 kHz).
    assign filter_step = (tone_select == 2'd3)
        ? (filter_error >>> PIANO_FILTER_SHIFT) : (filter_error >>> FILTER_SHIFT);
    assign sample = filtered_sample[15:0];

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n || mute)
            filtered_sample <= 18'sd0;
        else if (sample_strobe) begin
            if ((raw_sample == 16'sd0)
                && (filtered_sample >= -18'sd7)
                && (filtered_sample <= 18'sd7))
                filtered_sample <= 18'sd0;
            else
                filtered_sample <= filtered_sample + filter_step[17:0];
        end
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            trigger_pending <= 3'b000;
        else if (mute || !play_mode)
            trigger_pending <= 3'b000;
        else if (sample_strobe)
            trigger_pending <= 3'b000;
        else
            trigger_pending <= trigger_pending | voice_trigger;
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n || mute) begin
            chord_root_offset <= 4'd0;
            chord_gate_previous <= 3'b000;
        end else begin
            chord_gate_previous <= voice_gate;
            if (!keymap_select)
                chord_root_offset <= 4'd0;
            else if (|voice_trigger)
                chord_root_offset <= chord_root_for_keys(voice_trigger);
            else if ((|voice_gate) && !(|chord_gate_previous))
                chord_root_offset <= chord_root_for_keys(voice_gate);
        end
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            voice0_phase_accumulator <= 32'd0;
            voice1_phase_accumulator <= 32'd0;
            voice2_phase_accumulator <= 32'd0;
            voice3_phase_accumulator <= 32'd0;
            voice0_gain              <= 8'd0;
            voice1_gain              <= 8'd0;
            voice2_gain              <= 8'd0;
            voice3_gain              <= 8'd0;
            voice0_decay_count       <= 8'd0;
            voice1_decay_count       <= 8'd0;
            voice2_decay_count       <= 8'd0;
            voice3_decay_count       <= 8'd0;
            voice0_attacking         <= 1'b0;
            voice1_attacking         <= 1'b0;
            voice2_attacking         <= 1'b0;
            voice3_attacking         <= 1'b0;
            voice0_decaying          <= 1'b0;
            voice1_decaying          <= 1'b0;
            voice2_decaying          <= 1'b0;
            voice3_decaying          <= 1'b0;
            voice_gate_previous      <= 3'b000;
            voice3_gate_previous     <= 1'b0;
        end else if (mute) begin
            voice0_phase_accumulator <= 32'd0;
            voice1_phase_accumulator <= 32'd0;
            voice2_phase_accumulator <= 32'd0;
            voice3_phase_accumulator <= 32'd0;
            voice0_gain              <= 8'd0;
            voice1_gain              <= 8'd0;
            voice2_gain              <= 8'd0;
            voice3_gain              <= 8'd0;
            voice0_decay_count       <= 8'd0;
            voice1_decay_count       <= 8'd0;
            voice2_decay_count       <= 8'd0;
            voice3_decay_count       <= 8'd0;
            voice0_attacking         <= 1'b0;
            voice1_attacking         <= 1'b0;
            voice2_attacking         <= 1'b0;
            voice3_attacking         <= 1'b0;
            voice0_decaying          <= 1'b0;
            voice1_decaying          <= 1'b0;
            voice2_decaying          <= 1'b0;
            voice3_decaying          <= 1'b0;
            voice_gate_previous      <= 3'b000;
            voice3_gate_previous     <= 1'b0;
        end else if (sample_strobe) begin
            voice_gate_previous <= voice_gate_effective;
            voice3_gate_previous <= voice3_gate_effective;
            if (voice0_gain == 8'd0)
                voice0_phase_accumulator <= 32'd0;
            else
                voice0_phase_accumulator <= voice0_phase_accumulator
                                          + expression_increment[0];

            if (voice1_gain == 8'd0)
                voice1_phase_accumulator <= 32'd0;
            else
                voice1_phase_accumulator <= voice1_phase_accumulator
                                          + expression_increment[1];

            if (voice2_gain == 8'd0)
                voice2_phase_accumulator <= 32'd0;
            else
                voice2_phase_accumulator <= voice2_phase_accumulator
                                          + expression_increment[2];

            if (voice3_gain == 8'd0)
                voice3_phase_accumulator <= 32'd0;
            else
                voice3_phase_accumulator <= voice3_phase_accumulator
                                          + expression_increment[3];

            if (!play_mode) begin
                if (voice_gate_effective[0]) begin
                    if (!voice_gate_previous[0]) begin
                        voice0_decay_count <= 8'd0;
                        voice0_decaying <= 1'b0;
                        if (voice0_attack_sum >= {1'b0, requested_gain}) begin
                            voice0_gain <= requested_gain;
                            voice0_attacking <= 1'b0;
                            voice0_decaying <= 1'b1;
                        end else begin
                            voice0_gain <= voice0_gain + ATTACK_STEP;
                            voice0_attacking <= 1'b1;
                        end
                    end else if (voice0_attacking) begin
                        voice0_decay_count <= 8'd0;
                        if (voice0_attack_sum >= {1'b0, requested_gain}) begin
                            voice0_gain <= requested_gain;
                            voice0_attacking <= 1'b0;
                            voice0_decaying <= 1'b1;
                        end else begin
                            voice0_gain <= voice0_gain + ATTACK_STEP;
                        end
                    end else if (voice0_decaying) begin
                        if (voice0_gain <= sustain_gain) begin
                            voice0_gain <= sustain_gain;
                            voice0_decay_count <= 8'd0;
                            voice0_decaying <= 1'b0;
                        end else if (voice0_decay_count == ADSR_DECAY_INTERVAL_LAST) begin
                            voice0_gain <= voice0_gain - 8'd1;
                            voice0_decay_count <= 8'd0;
                        end else begin
                            voice0_decay_count <= voice0_decay_count + 8'd1;
                        end
                    end else begin
                        voice0_gain <= sustain_gain;
                        voice0_decay_count <= 8'd0;
                    end
                end else begin
                    voice0_attacking <= 1'b0;
                    voice0_decaying <= 1'b0;
                    if (voice0_gain == 8'd0) begin
                        voice0_decay_count <= 8'd0;
                    end else if ((song_release && voice0_decay_count >= 8'd3) ||
                                 (!song_release && voice0_decay_count == TOUCH_RELEASE_INTERVAL_LAST)) begin
                        voice0_gain <= voice0_gain - 8'd1;
                        voice0_decay_count <= 8'd0;
                    end else begin
                        voice0_decay_count <= voice0_decay_count + 8'd1;
                    end
                end

                if (voice_gate_effective[1]) begin
                    if (!voice_gate_previous[1]) begin
                        voice1_decay_count <= 8'd0;
                        voice1_decaying <= 1'b0;
                        if (voice1_attack_sum >= {1'b0, requested_gain}) begin
                            voice1_gain <= requested_gain;
                            voice1_attacking <= 1'b0;
                            voice1_decaying <= 1'b1;
                        end else begin
                            voice1_gain <= voice1_gain + ATTACK_STEP;
                            voice1_attacking <= 1'b1;
                        end
                    end else if (voice1_attacking) begin
                        voice1_decay_count <= 8'd0;
                        if (voice1_attack_sum >= {1'b0, requested_gain}) begin
                            voice1_gain <= requested_gain;
                            voice1_attacking <= 1'b0;
                            voice1_decaying <= 1'b1;
                        end else begin
                            voice1_gain <= voice1_gain + ATTACK_STEP;
                        end
                    end else if (voice1_decaying) begin
                        if (voice1_gain <= sustain_gain) begin
                            voice1_gain <= sustain_gain;
                            voice1_decay_count <= 8'd0;
                            voice1_decaying <= 1'b0;
                        end else if (voice1_decay_count == ADSR_DECAY_INTERVAL_LAST) begin
                            voice1_gain <= voice1_gain - 8'd1;
                            voice1_decay_count <= 8'd0;
                        end else begin
                            voice1_decay_count <= voice1_decay_count + 8'd1;
                        end
                    end else begin
                        voice1_gain <= sustain_gain;
                        voice1_decay_count <= 8'd0;
                    end
                end else begin
                    voice1_attacking <= 1'b0;
                    voice1_decaying <= 1'b0;
                    if (voice1_gain == 8'd0) begin
                        voice1_decay_count <= 8'd0;
                    end else if (voice1_decay_count == TOUCH_RELEASE_INTERVAL_LAST) begin
                        voice1_gain <= voice1_gain - 8'd1;
                        voice1_decay_count <= 8'd0;
                    end else begin
                        voice1_decay_count <= voice1_decay_count + 8'd1;
                    end
                end

                if (voice_gate_effective[2]) begin
                    if (!voice_gate_previous[2]) begin
                        voice2_decay_count <= 8'd0;
                        voice2_decaying <= 1'b0;
                        if (voice2_attack_sum >= {1'b0, requested_gain}) begin
                            voice2_gain <= requested_gain;
                            voice2_attacking <= 1'b0;
                            voice2_decaying <= 1'b1;
                        end else begin
                            voice2_gain <= voice2_gain + ATTACK_STEP;
                            voice2_attacking <= 1'b1;
                        end
                    end else if (voice2_attacking) begin
                        voice2_decay_count <= 8'd0;
                        if (voice2_attack_sum >= {1'b0, requested_gain}) begin
                            voice2_gain <= requested_gain;
                            voice2_attacking <= 1'b0;
                            voice2_decaying <= 1'b1;
                        end else begin
                            voice2_gain <= voice2_gain + ATTACK_STEP;
                        end
                    end else if (voice2_decaying) begin
                        if (voice2_gain <= sustain_gain) begin
                            voice2_gain <= sustain_gain;
                            voice2_decay_count <= 8'd0;
                            voice2_decaying <= 1'b0;
                        end else if (voice2_decay_count == ADSR_DECAY_INTERVAL_LAST) begin
                            voice2_gain <= voice2_gain - 8'd1;
                            voice2_decay_count <= 8'd0;
                        end else begin
                            voice2_decay_count <= voice2_decay_count + 8'd1;
                        end
                    end else begin
                        voice2_gain <= sustain_gain;
                        voice2_decay_count <= 8'd0;
                    end
                end else begin
                    voice2_attacking <= 1'b0;
                    voice2_decaying <= 1'b0;
                    if (voice2_gain == 8'd0) begin
                        voice2_decay_count <= 8'd0;
                    end else if (voice2_decay_count == TOUCH_RELEASE_INTERVAL_LAST) begin
                        voice2_gain <= voice2_gain - 8'd1;
                        voice2_decay_count <= 8'd0;
                    end else begin
                        voice2_decay_count <= voice2_decay_count + 8'd1;
                    end
                end

                if (voice3_gate_effective) begin
                    if (!voice3_gate_previous) begin
                        voice3_decay_count <= 8'd0;
                        voice3_decaying <= 1'b0;
                        if (voice3_attack_sum >= {1'b0, voice3_requested_gain}) begin
                            voice3_gain <= voice3_requested_gain;
                            voice3_attacking <= 1'b0;
                            voice3_decaying <= 1'b1;
                        end else begin
                            voice3_gain <= voice3_gain + ATTACK_STEP;
                            voice3_attacking <= 1'b1;
                        end
                    end else if (voice3_attacking) begin
                        voice3_decay_count <= 8'd0;
                        if (voice3_attack_sum >= {1'b0, voice3_requested_gain}) begin
                            voice3_gain <= voice3_requested_gain;
                            voice3_attacking <= 1'b0;
                            voice3_decaying <= 1'b1;
                        end else begin
                            voice3_gain <= voice3_gain + ATTACK_STEP;
                        end
                    end else if (voice3_decaying) begin
                        if (voice3_gain <= voice3_sustain_gain) begin
                            voice3_gain <= voice3_sustain_gain;
                            voice3_decay_count <= 8'd0;
                            voice3_decaying <= 1'b0;
                        end else if (voice3_decay_count == ADSR_DECAY_INTERVAL_LAST) begin
                            voice3_gain <= voice3_gain - 8'd1;
                            voice3_decay_count <= 8'd0;
                        end else begin
                            voice3_decay_count <= voice3_decay_count + 8'd1;
                        end
                    end else begin
                        voice3_gain <= voice3_sustain_gain;
                        voice3_decay_count <= 8'd0;
                    end
                end else begin
                    voice3_attacking <= 1'b0;
                    voice3_decaying <= 1'b0;
                    if (voice3_gain == 8'd0) begin
                        voice3_decay_count <= 8'd0;
                    end else if (voice3_decay_count == TOUCH_RELEASE_INTERVAL_LAST) begin
                        voice3_gain <= voice3_gain - 8'd1;
                        voice3_decay_count <= 8'd0;
                    end else begin
                        voice3_decay_count <= voice3_decay_count + 8'd1;
                    end
                end
            end else begin
            voice0_decaying <= 1'b0;
            voice1_decaying <= 1'b0;
            voice2_decaying <= 1'b0;
            voice3_decaying <= 1'b0;
            if (trigger_effective[0]) begin
                voice0_decay_count <= 8'd0;
                if (voice0_gain >= requested_gain) begin
                    voice0_gain <= requested_gain;
                    voice0_attacking <= 1'b0;
                end else if (voice0_attack_sum >= {1'b0, requested_gain}) begin
                    voice0_gain <= requested_gain;
                    voice0_attacking <= 1'b0;
                end else begin
                    voice0_gain <= voice0_gain + ATTACK_STEP;
                    voice0_attacking <= 1'b1;
                end
            end else if (voice0_gain == 8'd0) begin
                voice0_decay_count <= 8'd0;
                voice0_attacking <= 1'b0;
            end else if (voice0_attacking) begin
                voice0_decay_count <= 8'd0;
                if (voice0_attack_sum >= {1'b0, requested_gain}) begin
                    voice0_gain <= requested_gain;
                    voice0_attacking <= 1'b0;
                end else begin
                    voice0_gain <= voice0_gain + ATTACK_STEP;
                end
            end else if (voice0_decay_count == DECAY_INTERVAL_LAST) begin
                voice0_gain <= voice0_gain - 8'd1;
                voice0_decay_count <= 8'd0;
            end else begin
                voice0_decay_count <= voice0_decay_count + 8'd1;
            end

            if (trigger_effective[1]) begin
                voice1_decay_count <= 8'd0;
                if (voice1_gain >= requested_gain) begin
                    voice1_gain <= requested_gain;
                    voice1_attacking <= 1'b0;
                end else if (voice1_attack_sum >= {1'b0, requested_gain}) begin
                    voice1_gain <= requested_gain;
                    voice1_attacking <= 1'b0;
                end else begin
                    voice1_gain <= voice1_gain + ATTACK_STEP;
                    voice1_attacking <= 1'b1;
                end
            end else if (voice1_gain == 8'd0) begin
                voice1_decay_count <= 8'd0;
                voice1_attacking <= 1'b0;
            end else if (voice1_attacking) begin
                voice1_decay_count <= 8'd0;
                if (voice1_attack_sum >= {1'b0, requested_gain}) begin
                    voice1_gain <= requested_gain;
                    voice1_attacking <= 1'b0;
                end else begin
                    voice1_gain <= voice1_gain + ATTACK_STEP;
                end
            end else if (voice1_decay_count == DECAY_INTERVAL_LAST) begin
                voice1_gain <= voice1_gain - 8'd1;
                voice1_decay_count <= 8'd0;
            end else begin
                voice1_decay_count <= voice1_decay_count + 8'd1;
            end

            if (trigger_effective[2]) begin
                voice2_decay_count <= 8'd0;
                if (voice2_gain >= requested_gain) begin
                    voice2_gain <= requested_gain;
                    voice2_attacking <= 1'b0;
                end else if (voice2_attack_sum >= {1'b0, requested_gain}) begin
                    voice2_gain <= requested_gain;
                    voice2_attacking <= 1'b0;
                end else begin
                    voice2_gain <= voice2_gain + ATTACK_STEP;
                    voice2_attacking <= 1'b1;
                end
            end else if (voice2_gain == 8'd0) begin
                voice2_decay_count <= 8'd0;
                voice2_attacking <= 1'b0;
            end else if (voice2_attacking) begin
                voice2_decay_count <= 8'd0;
                if (voice2_attack_sum >= {1'b0, requested_gain}) begin
                    voice2_gain <= requested_gain;
                    voice2_attacking <= 1'b0;
                end else begin
                    voice2_gain <= voice2_gain + ATTACK_STEP;
                end
            end else if (voice2_decay_count == DECAY_INTERVAL_LAST) begin
                voice2_gain <= voice2_gain - 8'd1;
                voice2_decay_count <= 8'd0;
            end else begin
                voice2_decay_count <= voice2_decay_count + 8'd1;
            end

            if (voice3_trigger_now) begin
                voice3_decay_count <= 8'd0;
                if (voice3_gain >= voice3_requested_gain) begin
                    voice3_gain <= voice3_requested_gain;
                    voice3_attacking <= 1'b0;
                end else if (voice3_attack_sum >= {1'b0, voice3_requested_gain}) begin
                    voice3_gain <= voice3_requested_gain;
                    voice3_attacking <= 1'b0;
                end else begin
                    voice3_gain <= voice3_gain + ATTACK_STEP;
                    voice3_attacking <= 1'b1;
                end
            end else if (voice3_gain == 8'd0) begin
                voice3_decay_count <= 8'd0;
                voice3_attacking <= 1'b0;
            end else if (voice3_attacking) begin
                voice3_decay_count <= 8'd0;
                if (voice3_attack_sum >= {1'b0, voice3_requested_gain}) begin
                    voice3_gain <= voice3_requested_gain;
                    voice3_attacking <= 1'b0;
                end else begin
                    voice3_gain <= voice3_gain + ATTACK_STEP;
                end
            end else if (voice3_decay_count == DECAY_INTERVAL_LAST) begin
                voice3_gain <= voice3_gain - 8'd1;
                voice3_decay_count <= 8'd0;
            end else begin
                voice3_decay_count <= voice3_decay_count + 8'd1;
            end
            end
        end
    end

endmodule

`default_nettype wire
