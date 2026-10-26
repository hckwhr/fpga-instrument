`default_nettype none
`include "note_event_contract.vh"

// 32 parallel DDS/envelope lanes. A single event bus writes one lane at a
// time; never infer a nine-write-port register array for simultaneous triads.
module stage18_polyphony_bank_32 #(
    parameter integer PLUCK_DECAY_INTERVAL_SAMPLES = 6000,
    parameter integer TOUCH_RELEASE_INTERVAL_SAMPLES = 2000,
    parameter integer TOUCH_DECAY_INTERVAL_SAMPLES = 4,
    parameter integer ENVELOPE_COUNTER_WIDTH = 14,
    parameter [11:0] ATTACK_STEP = 12'd16
) (
    input wire clk, reset_n, sample_strobe, enable,
    input wire [2:0] voice_trigger, voice_gate,
    input wire play_mode,
    input wire [1:0] tone_select,
    input wire [3:0] note_select,
    input wire keymap_select,
    input wire [1:0] octave_select,
    input wire [6:0] force_value,
    // Exclusive owner: physical keys when 0, ready/valid note events when 1.
    // Flush cancels allocation and releases event voices; enable=0 hard clears.
    input wire event_mode, event_flush, event_valid, event_on,
    input wire [`NOTE_EVENT_ID_WIDTH-1:0] event_id,
    input wire [3:0] event_note,
    input wire [1:0] event_octave,
    input wire [6:0] event_force,
    output wire event_ready,
    output reg signed [15:0] sample,
    output reg [5:0] active_voice_count,
    // Held event pitch classes, sampled at the audio boundary. Release tails
    // still count as active voices but no longer look like held piano keys.
    output reg [11:0] held_note_mask,
    output wire all_voices_active
);
    localparam [ENVELOPE_COUNTER_WIDTH-1:0] PLUCK_LAST =
        ((PLUCK_DECAY_INTERVAL_SAMPLES >= 64) ? PLUCK_DECAY_INTERVAL_SAMPLES / 64 : 1) - 1;
    localparam [ENVELOPE_COUNTER_WIDTH-1:0] RELEASE_LAST =
        ((TOUCH_RELEASE_INTERVAL_SAMPLES >= 64) ? TOUCH_RELEASE_INTERVAL_SAMPLES / 64 : 1) - 1;
    localparam [ENVELOPE_COUNTER_WIDTH-1:0] TOUCH_DECAY_LAST =
        ((TOUCH_DECAY_INTERVAL_SAMPLES >= 1) ? TOUCH_DECAY_INTERVAL_SAMPLES : 1) - 1;
    localparam [2:0] IDLE=0, PREPARE=1, SEARCH=2, WRITE=3, PICK=4;

    wire [31:0] voice_active;
    reg [31:0] phase_accumulator [0:31];
    reg [31:0] phase_increment_reg [0:31];
    reg [11:0] envelope_gain [0:31];
    reg [11:0] envelope_target [0:31];
    reg [ENVELOPE_COUNTER_WIDTH-1:0] envelope_count [0:31];
    reg [1:0] voice_source [0:31];
    reg [31:0] voice_one_shot, voice_attacking, voice_releasing;
    reg [31:0] voice_decaying;
    reg [31:0] voice_stealing;
    reg [31:0] pending_increment [0:31];
    reg [15:0] voice_id [0:31];
    reg [3:0] voice_note [0:31];
    reg [31:0] voice_id_valid;
    reg [15:0] batch_id;
    reg event_mode_d;
    reg [2:0] allocator_state;
    wire owner_change = event_mode != event_mode_d;
    wire [31:0] id_match;
    wire event_accept = event_valid && event_ready;
    wire event_off = event_accept && !event_on;
    assign event_ready = reset_n && enable && event_mode && !owner_change &&
        !event_flush && !sample_strobe && allocator_state==IDLE;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) event_mode_d<=0;
        else event_mode_d<=event_mode;
    end

    reg best_valid, best_released;
    reg [4:0] best_index;
    reg [11:0] best_gain;
    reg [4:0] next_voice_index, search_index, search_count;
    // One-hot read avoids a priority mux chain across 32 distributed lanes.
    // No extra allocator cycle: the 320-clock batch contract stays unchanged.
    wire [31:0] search_select;
    wire [11:0] candidate_gain;
    wire [31:0] released_lanes, better_lanes;
    genvar gain_lane, gain_bit;
    generate
        for (gain_lane=0; gain_lane<32; gain_lane=gain_lane+1) begin: u_search_decode
            assign search_select[gain_lane] = (search_index == gain_lane);
            // Compare locally before selecting a lane. This removes the
            // 32:1 gain read from the priority-comparison path without adding
            // a scan cycle or taking a stale snapshot at a sample boundary.
            assign released_lanes[gain_lane] = voice_releasing[gain_lane] ||
                (!event_mode && !voice_one_shot[gain_lane] && !voice_gate[voice_source[gain_lane]]);
            assign better_lanes[gain_lane] = !best_valid ||
                (released_lanes[gain_lane] && !best_released) ||
                ((released_lanes[gain_lane] == best_released) && envelope_gain[gain_lane] < best_gain);
        end
        for (gain_bit=0; gain_bit<12; gain_bit=gain_bit+1) begin: u_gain_read
            wire [31:0] selected_bits;
            for (gain_lane=0; gain_lane<32; gain_lane=gain_lane+1) begin: u_lane
                assign selected_bits[gain_lane] = search_select[gain_lane] & envelope_gain[gain_lane][gain_bit];
            end
            assign candidate_gain[gain_bit] = |selected_bits;
        end
    endgenerate
    wire candidate_released = |(search_select & released_lanes);
    wire candidate_better = |(search_select & better_lanes);
    reg [2:0] trigger_pending, batch_keys;
    reg [1:0] event_source, chord_member;
    reg [3:0] batch_root;
    reg [11:0] batch_gain;
    reg [1:0] batch_octave;
    reg batch_chord, batch_pluck;
    reg [31:0] event_increment;
    wire [4:0] event_root_offset = batch_chord
        ? ((event_source == 0) ? 5'd0 : (event_source == 1) ? 5'd5 : 5'd7)
        : ((event_source == 0) ? 5'd0 : (event_source == 1) ? 5'd2 : 5'd4);
    wire [4:0] event_offset = event_root_offset
        + ((chord_member == 0) ? 5'd0 : (chord_member == 1) ? 5'd4 : 5'd7);
    // This combinational write qualifier fans out across all 32 lanes. The
    // routed stage-18 report showed 517 loads before per-lane decoding; keep
    // the boundary and allow local copies without adding an allocator cycle.
    wire allocate_voice /* synthesis syn_keep = 1 syn_maxfan = 16 */ =
        enable && !owner_change && !(event_mode && event_flush) &&
        (allocator_state == WRITE);
    wire [7:0] requested_gain = (force_value == 7'd127)
        ? 8'd255 : {force_value, 1'b0};

    function [31:0] pitch_increment;
        input [3:0] root;
        input [1:0] octave;
        input [4:0] offset;
        reg [5:0] total, wrapped;
        reg [2:0] level;
        reg [31:0] base;
        begin
            total = {2'b0, root} + {1'b0, offset};
            level = {1'b0, octave};
            if (total >= 6'd24) begin
                wrapped = total - 6'd24; level = level + 3'd2;
            end else if (total >= 6'd12) begin
                wrapped = total - 6'd12; level = level + 3'd1;
            end else wrapped = total;
            case (wrapped[3:0])
                0: base=32'd23409859; 1: base=32'd24801882;
                2: base=32'd26276679; 3: base=32'd27839171;
                4: base=32'd29494575; 5: base=32'd31248413;
                6: base=32'd33106541; 7: base=32'd35075158;
                8: base=32'd37160835; 9: base=32'd39370534;
                10: base=32'd41711627; default: base=32'd44191930;
            endcase
            case (level)
                0: pitch_increment=base>>1;
                1: pitch_increment=base;
                2: pitch_increment=base<<1;
                3: pitch_increment=base<<2;
                default: pitch_increment=base<<3;
            endcase
        end
    endfunction

    `include "piano_wave.vh"

    function signed [15:0] waveform;
        input [31:0] phase;
        input [1:0] tone;
        reg [15:0] triangle_value;
        reg signed [15:0] centered;
        begin
            triangle_value = phase[31] ? ~phase[30:15] : phase[30:15];
            case (tone)
                0: begin
                    centered = $signed(triangle_value ^ 16'h8000);
                    waveform = centered >>> 2;
                end
                1: waveform = phase[31] ? -16'sd8192 : 16'sd8191;
                2: begin
                    centered = $signed(phase[31:16]);
                    waveform = centered >>> 2;
                end
                default: waveform = piano_wave(phase);
            endcase
        end
    endfunction

    // The board produces a strobe every 1024 clocks. The worst batch (three
    // triads, all slots occupied) needs 9*(1+32+1+1)+1 = 316 clocks.
    // Event input has backpressure; one accepted ON is retained until WRITE.
    // This is not a timestamped/atomic batch scheduler. A producer must hold
    // stalled events and budget the measured allocator latency before a deadline.
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            trigger_pending <= 0; batch_keys <= 0;
            allocator_state <= IDLE; event_source <= 0; chord_member <= 0;
            batch_root <= 0; batch_gain <= 0; batch_octave <= 0;
            batch_chord <= 0; batch_pluck <= 0;
            next_voice_index <= 0; search_index <= 0; search_count <= 0;
            event_increment <= 0;
            best_valid<=0; best_released<=0; best_index<=0; best_gain<=0;
            batch_id<=0;
        end else if (!enable || owner_change || (event_mode && event_flush)) begin
            trigger_pending <= 0; batch_keys <= 0;
            allocator_state <= IDLE; next_voice_index <= 0;
        end else begin
            trigger_pending <= event_mode ? 3'd0 : trigger_pending | voice_trigger;
            case (allocator_state)
                IDLE: if (event_mode) begin
                    // Invalid/duplicate ON and stale OFF are consumed safely.
                    // A live occurrence ID is unique; repeated ON is idempotent.
                    if (event_accept && event_on) begin
                        // Capture the offered payload independently of the
                        // duplicate-ID reduction. Rejected ONs may change these
                        // idle-only scratch registers, but cannot reach PREPARE
                        // or WRITE. This removes duplicate detection from the
                        // wide payload write-enable path, with unchanged ready,
                        // acceptance and allocation cycles.
                        batch_root<=event_note; batch_octave<=event_octave;
                        batch_gain<={(event_force==7'd127 ? 8'd255 : {event_force,1'b0}),4'd0};
                        batch_chord<=0; batch_pluck<=0;
                        event_source<=0; chord_member<=0; batch_keys<=0;
                        if (!(|id_match) && event_note<4'd12 &&
                            event_octave<2'd3 && event_force!=0) begin
                            // Keep the stored occurrence ID unchanged for
                            // rejected ONs, including later manual ownership.
                            batch_id<=event_id;
                            allocator_state<=PREPARE;
                        end
                    end
                end else if (sample_strobe && (|(trigger_pending | voice_trigger))) begin
                    batch_keys <= trigger_pending | voice_trigger;
                    trigger_pending <= 0;
                    batch_root <= note_select; batch_octave <= octave_select;
                    batch_chord <= keymap_select; batch_pluck <= play_mode;
                    batch_gain <= {requested_gain, 4'b0000};
                    event_source <= (trigger_pending[0] | voice_trigger[0]) ? 2'd0
                                  : (trigger_pending[1] | voice_trigger[1]) ? 2'd1 : 2'd2;
                    chord_member <= 0;
                    allocator_state <= PREPARE;
                end
                PREPARE: begin
                    event_increment <= pitch_increment(batch_root, batch_octave, event_offset);
                    search_index <= next_voice_index;
                    search_count <= 0;
                    best_valid <= 0;
                    allocator_state <= SEARCH;
                end
                SEARCH: begin
                    if (!voice_active[search_index] && !voice_stealing[search_index])
                        allocator_state <= WRITE;
                    else begin
                        if(!voice_stealing[search_index] && candidate_better) begin
                            best_valid<=1; best_index<=search_index;
                            best_gain<=candidate_gain; best_released<=candidate_released;
                        end
                        if(search_count==5'd31) allocator_state<=PICK;
                        else begin
                            search_index <= search_index + 5'd1;
                            search_count <= search_count + 5'd1;
                        end
                    end
                end
                PICK: if(best_valid) begin search_index<=best_index; allocator_state<=WRITE; end
                    else begin search_index<=next_voice_index; search_count<=0; allocator_state<=SEARCH; end
                WRITE: begin
                    next_voice_index <= search_index + 5'd1;
                    if (batch_chord && chord_member != 2'd2) begin
                        chord_member <= chord_member + 2'd1;
                        allocator_state <= PREPARE;
                    end else begin
                        chord_member <= 0;
                        if (event_source == 0 && batch_keys[1]) begin
                            event_source <= 1; allocator_state <= PREPARE;
                        end else if (event_source != 2 && batch_keys[2]) begin
                            event_source <= 2; allocator_state <= PREPARE;
                        end else allocator_state <= IDLE;
                    end
                end
                default: allocator_state<=IDLE;
            endcase
        end
    end

    genvar g, id_pair;
    generate for (g=0; g<32; g=g+1) begin: u_voice_bank
        reg active;
        // The routed 16-bit equality inferred a serial ALU carry chain on
        // the duplicate-ID -> batch-accept path. Preserve 2-bit LUT compares
        // so the reduction stays a short parallel tree, with no cycle added.
        wire [7:0] id_pair_equal /* synthesis syn_keep=1 */;
        for (id_pair=0; id_pair<8; id_pair=id_pair+1) begin: u_id_pair
            assign id_pair_equal[id_pair] =
                (voice_id[g][id_pair*2 +: 2] == event_id[id_pair*2 +: 2]);
        end
        assign id_match[g] = voice_id_valid[g] && active && (&id_pair_equal);
        wire [12:0] attack_sum = {1'b0, envelope_gain[g]} + {1'b0, ATTACK_STEP};
        // Small multiplicative decay steps: smooth at high level, finite tail
        // down to one 12-bit unit. Default pluck is about 1.3 seconds at gain 96.
        wire [11:0] decay_step = {8'd0, envelope_gain[g][11:8]} + 12'd1;
        // Manual touch ADSR: peak -> 75% sustain in 12-bit single-unit steps.
        // At force 96: 4 ms attack and 64 ms decay at 48 kHz. Reuse the lane's
        // sample counter. Event-owned voices retain their frozen score envelope.
        wire [11:0] sustain_gain = envelope_target[g] - (envelope_target[g] >> 2);
        assign voice_active[g] = active;
        // Only this process writes lane g. The only cross-lane write wiring is
        // a registered pitch bus and a five-bit destination decoder.
        always @(posedge clk or negedge reset_n) begin
            if (!reset_n) begin
                active <= 0; phase_accumulator[g] <= 0; phase_increment_reg[g] <= 0;
                envelope_gain[g] <= 0; envelope_target[g] <= 0; envelope_count[g] <= 0;
                voice_source[g] <= 0; voice_one_shot[g] <= 0;
                voice_attacking[g] <= 0; voice_releasing[g] <= 0;
                voice_decaying[g] <= 0;
                voice_stealing[g]<=0; pending_increment[g]<=0;
                voice_id[g]<=0; voice_id_valid[g]<=0; voice_note[g]<=0;
            end else if (!enable || owner_change) begin
                active <= 0; phase_accumulator[g] <= 0; envelope_gain[g] <= 0;
                envelope_count[g] <= 0; voice_attacking[g] <= 0; voice_releasing[g] <= 0;
                voice_decaying[g] <= 0;
                voice_stealing[g]<=0;
                voice_id_valid[g]<=0;
            end else if (event_mode && event_flush) begin
                // Repeated flush levels still advance the release on samples.
                // Cancel a replacement before its new pitch can start.
                voice_id_valid[g]<=0; voice_releasing[g]<=1;
                voice_attacking[g]<=0; voice_stealing[g]<=0;
                voice_decaying[g]<=0;
                envelope_count[g]<=0;
                if (sample_strobe && active) begin
                    phase_accumulator[g]<=phase_accumulator[g]+phase_increment_reg[g];
                    if (envelope_gain[g]<=decay_step) begin
                        envelope_gain[g]<=0; active<=0;
                    end else envelope_gain[g]<=envelope_gain[g]-decay_step;
                end
            end else if (allocate_voice && search_index == g) begin
                active <= 1;
                // Retune an occupied lane only after a <=16-sample fade to zero.
                // Other 31 voices keep their independent phase and envelope.
                pending_increment[g]<=event_increment;
                voice_stealing[g]<=active;
                if (!active) begin
                    phase_accumulator[g] <= (tone_select == 0) ? 32'h40000000 : 32'd0;
                    envelope_gain[g] <= 0;
                    phase_increment_reg[g] <= event_increment;
                end
                envelope_target[g] <= batch_gain;
                envelope_count[g] <= 0; voice_source[g] <= event_source;
                voice_one_shot[g] <= batch_pluck; voice_attacking[g] <= 1;
                voice_decaying[g] <= 0;
                voice_releasing[g] <= 0;
                voice_id[g]<=batch_id; voice_id_valid[g]<=event_mode;
                voice_note[g]<=batch_root;
            end else if (event_off && id_match[g]) begin
                voice_id_valid[g]<=0; voice_releasing[g]<=1;
                voice_attacking[g]<=0; voice_stealing[g]<=0;
                voice_decaying[g]<=0;
                envelope_count[g]<=0;
            end else if (sample_strobe && active) begin
                phase_accumulator[g] <= phase_accumulator[g] + phase_increment_reg[g];
                // A single live force channel controls held manual touch voices.
                // Target values are multiples of 16 (including all allocations),
                // so a one-unit 8-bit slew cannot overshoot. Release tails,
                // stealing, pluck and event-owned notes keep their captured force.
                if (!event_mode && !voice_one_shot[g] && !voice_releasing[g] &&
                    !voice_stealing[g] && voice_gate[voice_source[g]]) begin
                    if (envelope_target[g][11:4] < requested_gain)
                        envelope_target[g] <= envelope_target[g] + 12'd16;
                    else if (envelope_target[g][11:4] > requested_gain)
                        envelope_target[g] <= envelope_target[g] - 12'd16;
                end
                if (voice_stealing[g]) begin
                    if(envelope_gain[g]<=12'd256) begin
                        envelope_gain[g]<=0; voice_stealing[g]<=0;
                        phase_increment_reg[g]<=pending_increment[g];
                        phase_accumulator[g]<=(tone_select==0)?32'h40000000:32'd0;
                    end else envelope_gain[g]<=envelope_gain[g]-12'd256;
                end else if (!voice_one_shot[g] &&
                    (voice_releasing[g] || (!event_mode && !voice_gate[voice_source[g]]))) begin
                    voice_releasing[g] <= 1; voice_attacking[g] <= 0;
                    voice_decaying[g] <= 0;
                    // Event OFF fits the score's minimum 25 ms release gap;
                    // manual touch/pluck timings remain unchanged.
                    if (event_mode || envelope_count[g] >= RELEASE_LAST) begin
                        envelope_count[g] <= 0;
                        if (envelope_gain[g] <= decay_step) begin
                            envelope_gain[g] <= 0; active <= 0;
                        end else envelope_gain[g] <= envelope_gain[g] - decay_step;
                    end else envelope_count[g] <= envelope_count[g] + 1'b1;
                end else if (voice_attacking[g]) begin
                    envelope_count[g] <= 0;
                    if (attack_sum >= {1'b0, envelope_target[g]}) begin
                        envelope_gain[g] <= envelope_target[g];
                        voice_attacking[g] <= 0;
                        voice_decaying[g] <= !event_mode && !voice_one_shot[g];
                    end else envelope_gain[g] <= attack_sum[11:0];
                end else if (voice_decaying[g]) begin
                    // A falling force ceiling takes priority over the musical
                    // decay. Since the ceiling slews by <=16/sample, this clamp
                    // also moves by <=16; it cannot introduce a full gain jump.
                    if (envelope_gain[g] > envelope_target[g]) begin
                        envelope_gain[g] <= envelope_target[g];
                        envelope_count[g] <= 0;
                    end else if (envelope_gain[g] <= sustain_gain) begin
                        envelope_gain[g] <= sustain_gain;
                        envelope_count[g] <= 0;
                        voice_decaying[g] <= 0;
                    end else if (envelope_count[g] >= TOUCH_DECAY_LAST) begin
                        envelope_gain[g] <= envelope_gain[g] - 12'd1;
                        envelope_count[g] <= 0;
                    end else envelope_count[g] <= envelope_count[g] + 1'b1;
                end else if (voice_one_shot[g]) begin
                    if (envelope_count[g] >= PLUCK_LAST) begin
                        envelope_count[g] <= 0;
                        if (envelope_gain[g] <= decay_step) begin
                            envelope_gain[g] <= 0; active <= 0;
                        end else envelope_gain[g] <= envelope_gain[g] - decay_step;
                    end else envelope_count[g] <= envelope_count[g] + 1'b1;
                end else begin
                    envelope_count[g] <= 0;
                    // Sustained gain follows the slewed target (<=12/sample).
                    // Zero force silences a held lane without restarting its
                    // phase/ADSR when force returns; key release retires it.
                    if (!event_mode) envelope_gain[g] <= sustain_gain;
                end
            end
        end
    end endgenerate

    // Read the actual allocator ownership, not a second independent event
    // table. Equal pitches OR together; replacing a voice cannot leave a
    // stale key lit. A stealing lane shows its new key only after retuning.
    wire [11:0] held_notes_next;
    genvar pitch, lane;
    generate for (pitch=0; pitch<12; pitch=pitch+1) begin: u_held_notes
        wire [31:0] matches;
        for (lane=0; lane<32; lane=lane+1) begin: u_match
            assign matches[lane] = voice_active[lane] && voice_id_valid[lane] &&
                !voice_stealing[lane] && (voice_note[lane] == pitch);
        end
        assign held_notes_next[pitch] = |matches;
    end endgenerate
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) held_note_mask <= 12'd0;
        else if (!enable || owner_change || event_flush || !event_mode)
            held_note_mask <= 12'd0;
        else if (sample_strobe) held_note_mask <= held_notes_next;
    end

    // Local products followed by five registered pairwise sum stages.
    // All 32 lanes compute in parallel. Output is committed only on strobes,
    // after the event bus and this pipeline have settled between samples.
    reg signed [28:0] products [0:31];
    // Separate waveform interpolation from envelope multiplication. Capture
    // both operands together: exactly +1 internal clock vs the old mix tree.
    // Full audio slots allow the tree to settle before sample publication.
    reg signed [15:0] wave_q [0:31];
    reg signed [12:0] gain_q [0:31];
    wire signed [15:0] lane_sample [0:31];
    reg signed [16:0] sum1 [0:15];
    reg signed [17:0] sum2 [0:7];
    reg signed [18:0] sum3 [0:3];
    reg signed [19:0] sum4 [0:1];
    reg signed [20:0] sum5;
    generate
        for (g=0; g<32; g=g+1) begin: u_product
            always @(posedge clk) begin
                wave_q[g] <= waveform(phase_accumulator[g], tone_select);
                gain_q[g] <= $signed({1'b0, envelope_gain[g]});
                products[g] <= wave_q[g] * gain_q[g];
            end
            // 8 extra gain bits retain the original fixed mix headroom.
            assign lane_sample[g] = {{3{products[g][28]}}, products[g][28:16]};
        end
        for (g=0; g<16; g=g+1) begin: u_sum1
            always @(posedge clk) sum1[g] <=
                $signed({lane_sample[2*g][15], lane_sample[2*g]}) +
                $signed({lane_sample[2*g+1][15], lane_sample[2*g+1]});
        end
        for (g=0; g<8; g=g+1) begin: u_sum2
            always @(posedge clk) sum2[g] <=
                $signed({sum1[2*g][16], sum1[2*g]}) +
                $signed({sum1[2*g+1][16], sum1[2*g+1]});
        end
        for (g=0; g<4; g=g+1) begin: u_sum3
            always @(posedge clk) sum3[g] <=
                $signed({sum2[2*g][17], sum2[2*g]}) +
                $signed({sum2[2*g+1][17], sum2[2*g+1]});
        end
        for (g=0; g<2; g=g+1) begin: u_sum4
            always @(posedge clk) sum4[g] <=
                $signed({sum3[2*g][18], sum3[2*g]}) +
                $signed({sum3[2*g+1][18], sum3[2*g+1]});
        end
    endgenerate
    always @(posedge clk) sum5 <=
        $signed({sum4[0][19], sum4[0]}) + $signed({sum4[1][19], sum4[1]});

    reg [7:0] pipeline_ready;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin sample <= 0; pipeline_ready <= 0; end
        else if (!enable || owner_change) begin sample <= 0; pipeline_ready <= 0; end
        else begin
            pipeline_ready <= {pipeline_ready[6:0], 1'b1};
            if (sample_strobe) begin
                if (!pipeline_ready[7]) sample <= 0;
                else if (sum5 > 21'sd32767) sample <= 16'sh7fff;
                else if (sum5 < -21'sd32768) sample <= 16'sh8000;
                else sample <= sum5[15:0];
            end
        end
    end

    integer i;
    always @* begin
        active_voice_count = 0;
        for (i=0; i<32; i=i+1)
            active_voice_count = active_voice_count + {5'd0, voice_active[i]};
    end
    assign all_voices_active = &voice_active;
endmodule
`default_nettype wire
