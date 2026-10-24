`default_nettype none
`include "note_event_contract.vh"

// 32 parallel DDS/envelope lanes. A single event bus writes one lane at a
// time; never infer a nine-write-port register array for simultaneous triads.
module polyphony_bank_32 #(parameter integer CE_ENABLE=0,
    
    parameter integer PLUCK_DECAY_INTERVAL_SAMPLES = 6000,
    parameter integer TOUCH_RELEASE_INTERVAL_SAMPLES = 2000,
    parameter integer TOUCH_DECAY_INTERVAL_SAMPLES = 4,
    parameter integer ENVELOPE_COUNTER_WIDTH = 14,
    parameter [11:0] ATTACK_STEP = 12'd16,
    parameter integer LIVE_EVENT_SUPPORT=0,
    parameter integer PER_KEY_FORCE_SUPPORT=0,
    parameter integer KEYBOARD_SCALE_SUPPORT=0,
    parameter integer SHARED_KEY_FORCE=0,
    parameter integer SHARED_PITCH=0,
    // Diagnostic bisection: 16 shares lanes 0..15; 32 is the original 54f.
    // The other lanes retain their original parallel arithmetic. Use 16 or 32.
    parameter integer SHARED_PITCH_LANES=32,
    // Production: 1024 physical clocks / 512 enabled engine steps per sample.
    // Keep default direct for fast tests.
    parameter integer SUSTAIN_COMPARE_PIPELINE=0
) (
    input wire clock_enable,
    
    input wire clk, reset_n, sample_strobe, enable,
    input wire [2:0] voice_trigger, voice_gate,
    input wire play_mode,
    input wire [1:0] tone_select,
    input wire [3:0] note_select,
    input wire keymap_select,
    input wire [1:0] octave_select,
    input wire [6:0] force_value,
    input wire [83:0] key_forces,
    input wire [1:0] glide_select,
    input wire signed [7:0] bend,
    input wire [7:0] vibrato_depth,
    // Exclusive owner: physical keys when 0, ready/valid note events when 1.
    // Flush cancels allocation and releases event voices; enable=0 hard clears.
    input wire event_mode, event_flush, event_valid, event_on,
    input wire live_event_enable,
    input wire keyboard_piano,
    input wire [`NOTE_EVENT_ID_WIDTH-1:0] event_id,
    input wire [3:0] event_note,
    input wire [1:0] event_octave,
    // Scores stay within octaves 0..2. Only the all-engine self-test raises
    // this, to reach C6..B6 and place its 32 notes clear of the additive
    // bank's 110 Hz harmonics; pitch_increment already scales that level.
    input wire wide_event_octave,
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
    wire live_expression=(LIVE_EVENT_SUPPORT!=0) && live_event_enable;
    reg [2:0] allocator_state;
    wire owner_change = event_mode != event_mode_d;
    // Preserve/copy the common run qualifiers before distributing them across
    // the bank. The route report showed 588/218 loads and 6.257 ns on this chain.
    wire bank_enabled /* synthesis syn_keep = 1 syn_maxfan = 8 */ = enable && !owner_change;
    wire allocator_enabled /* synthesis syn_keep = 1 syn_maxfan = 8 */ =
        bank_enabled && !(event_mode && event_flush);
    wire [31:0] id_match;
    // Stage-20 route: a shared event-ID bit drove 35 loads and a 5.505 ns
    // wire before duplicate detection. Allow local combinational copies.
    wire [15:0] distributed_event_id /* synthesis syn_keep = 1 syn_maxfan = 8 */ = event_id;
    wire event_accept = event_valid && event_ready;
    // OFF handshakes reach every lane after the ready/valid producer chain.
    // The routed fanout-32 net cost 6.524 ns; preserve local data-net copies.
    wire event_off /* synthesis syn_keep = 1 syn_maxfan = 4 */ = event_accept && !event_on;
    assign event_ready = reset_n && bank_enabled && event_mode &&
        !event_flush && !sample_strobe && allocator_state==IDLE;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) event_mode_d<=0;
        else if ((!CE_ENABLE || clock_enable)) event_mode_d<=event_mode;
    end

    reg best_valid, best_released;
    reg [4:0] best_index;
    reg [11:0] best_gain;
    reg [4:0] next_voice_index, search_index, search_count;
    // One-hot read avoids a priority mux chain across 32 distributed lanes.
    // No extra allocator step: the 320-engine-step batch contract stays unchanged.
    // Route evidence: one full lane decode drove 55 loads and a 9.283 ns
    // segment into the candidate tree. Keep/localize these combinational nets.
    wire [31:0] search_select /* synthesis syn_keep = 1 syn_maxfan = 8 */;
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
    reg batch_diatonic;
    reg [31:0] event_increment;
    // Single-key melody history is shared; each allocated lane owns its ramp.
    // Simultaneous keys/triads bypass glide and invalidate ambiguous history.
    reg [31:0] last_melody_increment, batch_glide_origin;
    reg last_melody_valid, batch_single_melody;
    reg [1:0] batch_glide;
    reg [31:0] event_glide_origin, event_glide_step;
    reg [14:0] event_glide_duration;
    wire [2:0] incoming_keys = trigger_pending | voice_trigger;
    wire single_melody = !keymap_select &&
        (incoming_keys==3'b001 || incoming_keys==3'b010 || incoming_keys==3'b100);
    wire [4:0] event_root_offset = batch_chord
        ? ((event_source == 0) ? 5'd0 : (event_source == 1) ? 5'd5 : 5'd7)
        : ((event_source == 0) ? 5'd0 : (event_source == 1) ? 5'd2 : 5'd4);
    wire [4:0] event_offset = event_root_offset
        + ((chord_member == 0) ? 5'd0 : (chord_member == 1) ? 5'd4 : 5'd7);
    // This combinational write qualifier fans out across all 32 lanes. The
    // routed stage-18 report showed 517 loads before per-lane decoding; keep
    // the boundary and allow local copies without adding an allocator cycle.
    wire allocate_voice /* synthesis syn_keep = 1 syn_maxfan = 16 */ =
        allocator_enabled &&
        (allocator_state == WRITE);
    wire [7:0] requested_gain = (force_value == 7'd127)
        ? 8'd255 : {force_value, 1'b0};

    // One coherent Q18 pitch ratio for all manual lanes. Reuse the ordinary
    // DDS curve/LFO depth arithmetic at a unit frequency; event scores bypass
    // expression. Oscillators and envelopes still run independently in parallel.
    reg [23:0] vibrato_phase;
    wire [7:0] vibrato_triangle = vibrato_phase[23] ?
        ~vibrato_phase[22:15] : vibrato_phase[22:15];
    wire signed [7:0] vibrato_lfo = $signed(vibrato_triangle ^ 8'h80);
    wire [31:0] expression_ratio;
    // Subtraction is explicitly 32-bit before narrowing. The supported range
    // (+/-2 semitones plus vibrato) fits a signed 18-bit delta from Q18 unity.
    wire [31:0] ratio_delta = expression_ratio - 32'd262144;
    // Register the common coefficient. SHARED_PITCH sends it to one DSP;
    // the default configuration retains the historical parallel datapath.
    reg signed [17:0] pitch_delta /* synthesis syn_maxfan = 8 */;
    always @(posedge clk) if ((!CE_ENABLE || clock_enable)) pitch_delta <= $signed(ratio_delta[17:0]);
    // Share the Boolean contract but allow local copies for the 32 pitch muxes.
    wire expression_bypass /* synthesis syn_keep = 1 syn_maxfan = 8 */ =
        (event_mode && !live_expression) || (bend==8'sd0 && vibrato_depth==8'd0);
    // Preserve the common mode decode and the local lane select separately:
    // the active-flag route still had 32/35-load nets before the phase adder.
    wire glide_bypass /* synthesis syn_keep = 1 syn_maxfan = 8 */ =
        event_mode || glide_select==2'd0;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) vibrato_phase<=24'h400000;
        else if ((!CE_ENABLE || clock_enable)) if(!bank_enabled || (event_mode && !live_expression)) vibrato_phase<=24'h400000;
        else if(sample_strobe) vibrato_phase<=vibrato_phase+24'd1748;
    end
    pitch_expression #(.CE_ENABLE(CE_ENABLE)) u_expression_ratio (.clock_enable(clock_enable),
        .clk(clk),.reset_n(reset_n),.sample_strobe(sample_strobe),
        .enable(enable && (!event_mode || live_expression)),.active(1'b1),.note_start(1'b0),
        .target_increment(32'd262144),.start_increment(32'd0),.start_valid(1'b0),
        .glide_select(2'd0),.vibrato_depth(vibrato_depth),.lfo(vibrato_lfo),
        .bend(bend),.expressed_increment(expression_ratio));
    wire [31:0] expressed_increment [0:31];

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

    // Source-key identity stays in batch_root/voice_note for independent FSR
    // force tracking, OFF ownership and LEDs, even when C occurs in two octaves.
    // Only the shared pitch preparation maps white keys. No oscillator is added.
    function [3:0] white_key_note;
        input [3:0] key_index;
        begin
            case(key_index)
                0,7:white_key_note=4'd0;
                1,8:white_key_note=4'd2;
                2,9:white_key_note=4'd4;
                3,10:white_key_note=4'd5;
                4,11:white_key_note=4'd7;
                5:white_key_note=4'd9;
                6:white_key_note=4'd11;
                default:white_key_note=4'd0;
            endcase
        end
    endfunction
    wire mapped_batch=KEYBOARD_SCALE_SUPPORT && batch_diatonic;
    wire [3:0] prepared_note=mapped_batch ? white_key_note(batch_root) : batch_root;
    wire [1:0] prepared_octave=(mapped_batch && batch_root>=4'd7 && batch_octave<2'd3)
        ? batch_octave+2'd1 : batch_octave;
    wire [31:0] prepared_increment = pitch_increment(prepared_note, prepared_octave, event_offset);
    wire [31:0] glide_distance = (prepared_increment >= batch_glide_origin)
        ? prepared_increment-batch_glide_origin : batch_glide_origin-prepared_increment;
    wire [31:0] prepared_glide_step = (batch_glide==2'd1) ? (glide_distance>>12)+32'd1 :
        (batch_glide==2'd2) ? (glide_distance>>13)+32'd1 : (glide_distance>>14)+32'd1;
    wire [14:0] prepared_glide_duration = (batch_glide==2'd1) ? 15'd4096 :
        (batch_glide==2'd2) ? 15'd8192 : 15'd16384;

    `include "piano_wave.vh"

    // Reference form, kept byte-for-byte as the pre-optimization definition.
    // The lane datapath no longer calls it, so it costs no logic, but
    // tb_polyphony_bank_32 evaluates dut.waveform() for all 32 lanes to build
    // its expected mix. Keeping it independent of the shared lookup below is
    // what makes that comparison an equivalence proof rather than a tautology.
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

    // Lane datapath form. Tones 0-2 are a few bit operations and stay
    // combinational per lane; the piano tone takes the shared table's
    // registered result instead of a per-lane copy of that table.
    function signed [15:0] waveform_shared;
        input [31:0] phase;
        input [1:0] tone;
        input signed [15:0] piano;
        reg [15:0] triangle_value;
        reg signed [15:0] centered;
        begin
            triangle_value = phase[31] ? ~phase[30:15] : phase[30:15];
            case (tone)
                0: begin
                    centered = $signed(triangle_value ^ 16'h8000);
                    waveform_shared = centered >>> 2;
                end
                1: waveform_shared = phase[31] ? -16'sd8192 : 16'sd8191;
                2: begin
                    centered = $signed(phase[31:16]);
                    waveform_shared = centered >>> 2;
                end
                default: waveform_shared = piano;
            endcase
        end
    endfunction

    // The board supplies 512 enabled steps per 1024-physical-clock frame.
    // Worst batch (three triads, all slots occupied): 316 steps, conservatively
    // budget 320; 512/320=1.6x. Backpressure, not a faster strobe, handles bursts.
    // Event input has backpressure; one accepted ON is retained until WRITE.
    // This is not a timestamped/atomic batch scheduler. A producer must hold
    // stalled events and budget the measured allocator latency before a deadline.
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            trigger_pending <= 0; batch_keys <= 0;
            allocator_state <= IDLE; event_source <= 0; chord_member <= 0;
            batch_root <= 0; batch_gain <= 0; batch_octave <= 0;
            batch_chord <= 0; batch_pluck <= 0;
            batch_diatonic <= 0;
            next_voice_index <= 0; search_index <= 0; search_count <= 0;
            event_increment <= 0;
            best_valid<=0; best_released<=0; best_index<=0; best_gain<=0;
            batch_id<=0;
            last_melody_increment<=0; last_melody_valid<=0;
            batch_glide_origin<=0; batch_single_melody<=0; batch_glide<=0;
            event_glide_origin<=0; event_glide_step<=0; event_glide_duration<=0;
        end else if ((!CE_ENABLE || clock_enable)) if (!allocator_enabled) begin
            trigger_pending <= 0; batch_keys <= 0;
            allocator_state <= IDLE; next_voice_index <= 0;
            last_melody_valid<=0;
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
                        batch_diatonic<=KEYBOARD_SCALE_SUPPORT && live_expression && keyboard_piano;
                        batch_gain<={(event_force==7'd127 ? 8'd255 : {event_force,1'b0}),4'd0};
                        batch_chord<=0; batch_pluck<=0;
                        batch_glide<=0; batch_single_melody<=0;
                        event_source<=0; chord_member<=0; batch_keys<=0;
                        if (!(|id_match) && event_note<4'd12 &&
                            (event_octave<2'd3 || wide_event_octave) && event_force!=0) begin
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
                    batch_diatonic<=0;
                    batch_chord <= keymap_select; batch_pluck <= play_mode;
                    batch_single_melody <= single_melody;
                    batch_glide <= (single_melody && last_melody_valid) ? glide_select : 2'd0;
                    batch_glide_origin <= last_melody_increment;
                    batch_gain <= {requested_gain, 4'b0000};
                    event_source <= (trigger_pending[0] | voice_trigger[0]) ? 2'd0
                                  : (trigger_pending[1] | voice_trigger[1]) ? 2'd1 : 2'd2;
                    chord_member <= 0;
                    allocator_state <= PREPARE;
                end
                PREPARE: begin
                    event_increment <= prepared_increment;
                    event_glide_origin <= batch_glide_origin;
                    event_glide_step <= (prepared_increment>=batch_glide_origin)
                        ? prepared_glide_step : (~prepared_glide_step)+32'd1;
                    event_glide_duration <= (batch_glide!=2'd0 && glide_distance!=32'd0)
                        ? prepared_glide_duration : 15'd0;
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
                    last_melody_valid <= !event_mode && batch_single_melody;
                    last_melody_increment <= event_increment;
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

    // Shared force lookup contract: inputs are snapshotted at sample_strobe,
    // One lane per enabled step, all 32 caches settle in <=32 enabled steps.
    // Consumption requires >=33 enabled steps (32 to fill plus one consuming
    // edge). Production has 512 steps per 1024 physical clocks (>15x), guaranteed
    // by PT8211 framing. ADC CDC may arrive on ANY clock: the snapshot makes
    // the lookup source atomic/stable; live force adds at most one audio slot
    // of latency, never an unbounded or torn scan. ON still uses event_force.
    // A newly allocated lane is seeded from its captured event gain, so a
    // late allocation cannot consume the previous owner's cached pressure.
    // Default direct mode preserves legacy module timing and its regressions.
    reg [83:0] force_snapshot;
    reg [4:0] force_lane;
    wire [3:0] force_note=voice_note[force_lane];
    reg [6:0] shared_force;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin force_snapshot<=0;force_lane<=0;end
        else if ((!CE_ENABLE || clock_enable)) if(SHARED_KEY_FORCE && PER_KEY_FORCE_SUPPORT) begin
            if(sample_strobe) force_snapshot<=key_forces;
            force_lane<=force_lane+1'b1;
        end
    end
    always @* begin
        case(force_note)
            0:shared_force=force_snapshot[6:0];
            1:shared_force=force_snapshot[13:7];
            2:shared_force=force_snapshot[20:14];
            3:shared_force=force_snapshot[27:21];
            4:shared_force=force_snapshot[34:28];
            5:shared_force=force_snapshot[41:35];
            6:shared_force=force_snapshot[48:42];
            7:shared_force=force_snapshot[55:49];
            8:shared_force=force_snapshot[62:56];
            9:shared_force=force_snapshot[69:63];
            10:shared_force=force_snapshot[76:70];
            11:shared_force=force_snapshot[83:77];
            default:shared_force=0;
        endcase
    end

    // Shared pitch: issue one lane per clock, multiply/register, then add,
    // saturate and write back on the next edge. Oscillator, glide and envelope
    // state remain independent in all 32 lanes.
    // TIMING CONTRACT: after a stable increment/coefficient, all lane caches
    // fill within SHARED_PITCH_LANES+1 enabled steps (33 for 32, 17 for 16).
    // The bisection keeps the original >=64-step interface contract. Including
    // the expression curve pipeline and top-level control register, require
    // >=64 enabled steps between strobes, conservatively >20 steps of settling
    // allowance. PT8211 fixes production at 1024 physical clocks / 512 steps,
    // 8x this bound; performance_controls slews bend/depth on that same audio
    // boundary, not on the asynchronous ADC frame arrival. No clock/CDC change
    // is needed. Arbitrary module callers must respect this settling contract.
    // Allocation/zero-gain retune cancels cached/in-flight old-owner results;
    // until a fresh result returns, use the new unmodulated frequency.
    localparam integer PITCH_LANE_WIDTH=$clog2(SHARED_PITCH_LANES);
    wire [31:0] pitch_input [0:SHARED_PITCH_LANES-1];
    reg [PITCH_LANE_WIDTH-1:0] pitch_lane, pitch_lane_d1;
    reg signed [42:0] shared_pitch_product;
    reg [31:0] shared_pitch_base;
    wire [31:0] selected_pitch = pitch_input[pitch_lane];
    wire signed [33:0] shared_pitch_sum = $signed({2'b0,shared_pitch_base}) +
        $signed({shared_pitch_product[42],shared_pitch_product[42:10]});
    wire [31:0] shared_pitch_result = shared_pitch_sum[33] ? 32'd0 :
        shared_pitch_sum[32] ? 32'hffffffff : shared_pitch_sum[31:0];
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) pitch_lane<=0;
        else if ((!CE_ENABLE || clock_enable)) if(!bank_enabled) pitch_lane<=0;
        else if(SHARED_PITCH) pitch_lane<=pitch_lane+1'b1;
    end
    always @(posedge clk) if ((!CE_ENABLE || clock_enable)) begin
        shared_pitch_product <= $signed({1'b0,selected_pitch[31:8]}) * pitch_delta;
        shared_pitch_base <= selected_pitch;
        pitch_lane_d1 <= pitch_lane;
    end

    genvar g, id_pair;
    generate for (g=0; g<32; g=g+1) begin: u_voice_bank
        reg active;
        // Separate the 12-key selection from the envelope comparator path.
        reg [6:0] key_force_q;
        reg [6:0] selected_key_force;
        // Fixed seven-bit slices avoid a replicated 84-bit variable shifter.
        // Invalid notes remain silent; the registered selection keeps its
        // original one-clock latency, including allocation and owner changes.
        always @* begin
            case (voice_note[g])
                4'd0: selected_key_force=key_forces[6:0];
                4'd1: selected_key_force=key_forces[13:7];
                4'd2: selected_key_force=key_forces[20:14];
                4'd3: selected_key_force=key_forces[27:21];
                4'd4: selected_key_force=key_forces[34:28];
                4'd5: selected_key_force=key_forces[41:35];
                4'd6: selected_key_force=key_forces[48:42];
                4'd7: selected_key_force=key_forces[55:49];
                4'd8: selected_key_force=key_forces[62:56];
                4'd9: selected_key_force=key_forces[69:63];
                4'd10: selected_key_force=key_forces[76:70];
                4'd11: selected_key_force=key_forces[83:77];
                default: selected_key_force=7'd0;
            endcase
        end
        always @(posedge clk or negedge reset_n)
            if(!reset_n)key_force_q<=0;
            else if ((!CE_ENABLE || clock_enable)) if(PER_KEY_FORCE_SUPPORT) begin
                if(!SHARED_KEY_FORCE) key_force_q<=selected_key_force;
                else if(allocate_voice && search_index==g) key_force_q<=batch_gain[11:5];
                else if(force_lane==g) key_force_q<=shared_force;
            end
        wire [7:0] lane_requested_gain=(PER_KEY_FORCE_SUPPORT && event_mode && live_expression) ?
            (key_force_q==127 ? 8'd255 : {key_force_q,1'b0}) : requested_gain;
        // The routed 16-bit equality inferred a serial ALU carry chain on
        // the duplicate-ID -> batch-accept path. Preserve 2-bit LUT compares
        // so the reduction stays a short parallel tree, with no cycle added.
        wire [7:0] id_pair_equal /* synthesis syn_keep=1 */;
        for (id_pair=0; id_pair<8; id_pair=id_pair+1) begin: u_id_pair
            assign id_pair_equal[id_pair] =
                (voice_id[g][id_pair*2 +: 2] == distributed_event_id[id_pair*2 +: 2]);
        end
        assign id_match[g] = voice_id_valid[g] && active && (&id_pair_equal);
        // OFF-to-envelope-control was within 0.011 ns of the limit; keep
        // the lane decision local instead of sharing its final wide enable.
        wire lane_event_off /* synthesis syn_keep = 1 syn_maxfan = 4 */ =
            event_off && id_match[g];
        wire [12:0] attack_sum = {1'b0, envelope_gain[g]} + {1'b0, ATTACK_STEP};
        // Small multiplicative decay steps: smooth at high level, finite tail
        // down to one 12-bit unit. Default pluck is about 1.3 seconds at gain 96.
        wire [11:0] decay_step = {8'd0, envelope_gain[g][11:8]} + 12'd1;
        // Manual touch ADSR: peak -> 75% sustain in 12-bit single-unit steps.
        // At force 96: 4 ms attack and 64 ms decay at 48 kHz. Reuse the lane's
        // sample counter. Event-owned voices retain their frozen score envelope.
        // P&R: envelope_target -> (subtract) -> (compare) -> envelope_gain was
        // the worst setup path (-0.939 ns, 17 of 25 violating paths). The
        // subtract is hoisted out of that chain into a mirror register that is
        // written at every site that writes envelope_target, from the same
        // next-value expression. Both registers therefore update on the same
        // clock edge from the same source: sustain_gain_q always equals what
        // the combinational form produced, cycle for cycle. No behaviour moves.
        reg [11:0] sustain_gain_q;
        wire [11:0] sustain_gain = sustain_gain_q;
        wire gain_at_sustain;
        if(SUSTAIN_COMPARE_PIPELINE)begin: pipelined_sustain
            reg reached;
            always @(posedge clk) if ((!CE_ENABLE || clock_enable)) reached <= envelope_gain[g] <= sustain_gain;
            assign gain_at_sustain=reached;
        end else begin: direct_sustain
            assign gain_at_sustain=envelope_gain[g] <= sustain_gain;
        end
        wire [11:0] target_up   = envelope_target[g] + 12'd16;
        wire [11:0] target_down = envelope_target[g] - 12'd16;
        assign voice_active[g] = active;
        // Signed step uses one adder for either direction. The first route
        // had a 25.958 ns compare/subtract/compare/update chain (-5.681 ns).
        // Register the next sum inside the 512-step audio slot, then clamp
        // at the sample boundary. No second 32-bit result register is needed:
        // the sample-held glide_base is already the second pipeline boundary.
        reg [31:0] glide_base, glide_step;
        reg [14:0] glide_left;
        // Keep the zero-count decision out of the pitch mux/phase-adder path.
        // Updated on exactly the same edges as glide_left; no sample delay.
        reg glide_active;
        reg signed [32:0] glide_sum_q;
        reg [1:0] glide_ready;
        wire glide_arrived = glide_step[31]
            ? (glide_sum_q <= $signed({1'b0,phase_increment_reg[g]}))
            : (glide_sum_q >= $signed({1'b0,phase_increment_reg[g]}));
        // During stealing, keep the old pitch until the existing zero-gain
        // retune. The new ramp is already captured but must not advance yet.
        wire lane_glide_bypass /* synthesis syn_keep = 1 syn_maxfan = 8 */ =
            glide_bypass || voice_stealing[g] || !glide_active;
        wire [31:0] unmodulated_increment = lane_glide_bypass
            ? phase_increment_reg[g] : glide_base;
        if(g<SHARED_PITCH_LANES) begin: pitch_input_lane
            assign pitch_input[g] = unmodulated_increment;
        end
        reg [31:0] modulated_q;
        reg [1:0] pitch_valid;
        wire pitch_cache_ready;
        wire pitch_replaced = (allocate_voice && search_index==g && !active) ||
            (sample_strobe && active && voice_stealing[g] && envelope_gain[g]<=12'd256);
        always @(posedge clk) if ((!CE_ENABLE || clock_enable)) begin
            glide_sum_q <= $signed({1'b0,glide_base})+$signed({glide_step[31],glide_step});
        end
        always @(posedge clk or negedge reset_n) begin
            if(!reset_n) glide_ready<=2'b00;
            else if ((!CE_ENABLE || clock_enable)) if(!bank_enabled || (allocate_voice && search_index==g) || pitch_replaced)
                glide_ready<=2'b00;
            else glide_ready<={glide_ready[0],1'b1};
        end
        if(SHARED_PITCH && g<SHARED_PITCH_LANES) begin: shared_pitch
            reg cached;
            assign pitch_cache_ready=cached;
            always @(posedge clk or negedge reset_n) begin
                if(!reset_n) cached<=1'b0;
                else if ((!CE_ENABLE || clock_enable)) if(!bank_enabled || pitch_replaced) cached<=1'b0;
                // pitch_valid[0] rejects the return from an issue on the
                // replacement edge (which necessarily read the old owner).
                else if(pitch_lane_d1==g && pitch_valid[0]) cached<=1'b1;
            end
            always @(posedge clk) if ((!CE_ENABLE || clock_enable)) begin
                if(pitch_lane_d1==g && pitch_valid[0]) modulated_q<=shared_pitch_result;
            end
        end else begin: parallel_pitch
            reg signed [42:0] pitch_product;
            reg [31:0] pitch_base_q;
            wire signed [33:0] pitch_sum = $signed({2'b0,pitch_base_q}) +
                $signed({pitch_product[42],pitch_product[42:10]});
            assign pitch_cache_ready=1'b1;
            always @(posedge clk) if ((!CE_ENABLE || clock_enable)) begin
                pitch_product <= $signed({1'b0,unmodulated_increment[31:8]}) * pitch_delta;
                pitch_base_q <= unmodulated_increment;
                modulated_q <= pitch_sum[33] ? 32'd0 :
                    pitch_sum[32] ? 32'hffffffff : pitch_sum[31:0];
            end
        end
        always @(posedge clk or negedge reset_n) begin
            if(!reset_n) pitch_valid<=2'b00;
            else if ((!CE_ENABLE || clock_enable)) if(!bank_enabled || pitch_replaced) pitch_valid<=2'b00;
            else pitch_valid<={pitch_valid[0],1'b1};
        end
        assign expressed_increment[g] = (expression_bypass || !pitch_valid[1] || !pitch_cache_ready) ?
            unmodulated_increment : modulated_q;
        always @(posedge clk or negedge reset_n) begin
            if(!reset_n) begin glide_base<=0; glide_step<=0; glide_left<=0; glide_active<=0; end
            else if ((!CE_ENABLE || clock_enable)) if(!bank_enabled) begin glide_base<=0; glide_step<=0; glide_left<=0; glide_active<=0; end
            else if(allocate_voice && search_index==g) begin
                glide_base<=event_glide_origin;
                glide_step<=event_glide_step;
                glide_left<=event_glide_duration;
                glide_active<=(event_glide_duration!=15'd0);
            end else if(sample_strobe) begin
                if(event_mode || glide_select==2'd0 || !active) begin
                    glide_left<=0; glide_active<=0;
                end else if(!voice_stealing[g] && glide_active && glide_ready[1]) begin
                    if(glide_left==15'd1 || glide_arrived) begin
                        glide_base<=phase_increment_reg[g]; glide_left<=0; glide_active<=0;
                    end else begin
                        glide_base <= glide_sum_q[31:0];
                        glide_left<=glide_left-15'd1;
                    end
                end
            end
        end
        // Only this process writes lane g. The only cross-lane write wiring is
        // a registered pitch bus and a five-bit destination decoder.
        always @(posedge clk or negedge reset_n) begin
            if (!reset_n) begin
                active <= 0; phase_accumulator[g] <= 0; phase_increment_reg[g] <= 0;
                envelope_gain[g] <= 0; envelope_target[g] <= 0; envelope_count[g] <= 0;
                sustain_gain_q <= 0;
                voice_source[g] <= 0; voice_one_shot[g] <= 0;
                voice_attacking[g] <= 0; voice_releasing[g] <= 0;
                voice_decaying[g] <= 0;
                voice_stealing[g]<=0; pending_increment[g]<=0;
                voice_id[g]<=0; voice_id_valid[g]<=0; voice_note[g]<=0;
            end else if ((!CE_ENABLE || clock_enable)) if (!bank_enabled) begin
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
                end else begin
                    // Freeze the outgoing ramp at its current pitch while
                    // fading; loading the incoming ramp must not retune it.
                    phase_increment_reg[g] <= unmodulated_increment;
                end
                envelope_target[g] <= batch_gain;
                sustain_gain_q <= batch_gain - (batch_gain >> 2);
                envelope_count[g] <= 0; voice_source[g] <= event_source;
                voice_one_shot[g] <= batch_pluck; voice_attacking[g] <= 1;
                voice_decaying[g] <= 0;
                voice_releasing[g] <= 0;
                voice_id[g]<=batch_id; voice_id_valid[g]<=event_mode;
                voice_note[g]<=batch_root;
            end else if (sample_strobe && active) begin
                phase_accumulator[g] <= phase_accumulator[g] + expressed_increment[g];
                // A single live force channel controls held manual touch voices.
                // Target values are multiples of 16 (including all allocations),
                // so a one-unit 8-bit slew cannot overshoot. Release tails,
                // stealing, pluck and event-owned notes keep their captured force.
                if (!voice_one_shot[g] && !voice_releasing[g] && !voice_stealing[g] &&
                    ((!event_mode && voice_gate[voice_source[g]]) ||
                     (event_mode && live_expression && voice_id_valid[g]))) begin
                    if (envelope_target[g][11:4] < lane_requested_gain) begin
                        envelope_target[g] <= target_up;
                        // Targets are multiples of 16 from reset/allocation.
                        // A guarded +/-16 target step is exactly +/-12 of
                        // its 75% sustain, without wrap at either endpoint.
                        sustain_gain_q <= sustain_gain_q + 12'd12;
                    end else if (envelope_target[g][11:4] > lane_requested_gain) begin
                        envelope_target[g] <= target_down;
                        sustain_gain_q <= sustain_gain_q - 12'd12;
                    end
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
                        voice_decaying[g] <= (!event_mode || live_expression) && !voice_one_shot[g];
                    end else envelope_gain[g] <= attack_sum[11:0];
                end else if (voice_decaying[g]) begin
                    // A falling force ceiling takes priority over the musical
                    // decay. Since the ceiling slews by <=16/sample, this clamp
                    // also moves by <=16; it cannot introduce a full gain jump.
                    if (envelope_gain[g] > envelope_target[g]) begin
                        envelope_gain[g] <= envelope_target[g];
                        envelope_count[g] <= 0;
                    end else if (gain_at_sustain) begin
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
                    if (!event_mode || live_expression) envelope_gain[g] <= sustain_gain;
                end
            end else if (lane_event_off) begin
                // event_ready includes !sample_strobe: OFF and sample update
                // are mutually exclusive. Put OFF after the sample branch so
                // the producer handshake is not in phase/gain/active enables.
                // This reorders disjoint actions; no handshake or cycle moves.
                voice_id_valid[g]<=0; voice_releasing[g]<=1;
                voice_attacking[g]<=0; voice_stealing[g]<=0;
                voice_decaying[g]<=0;
                envelope_count[g]<=0;
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
        else if ((!CE_ENABLE || clock_enable)) if (!bank_enabled || event_flush || !event_mode)
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
    // Shared piano wavetable. The previous netlist built one 128x33 bit
    // combinational table plus its interpolation multiplier inside every lane,
    // 32 copies in all, and that table was the bulk of this module's LUT count.
    // phase_accumulator[g] only changes on sample_strobe or on an allocation,
    // so within an audio slot each lane's phase is constant and a sequential
    // lookup returns bit-for-bit what the per-lane combinational read did.
    //
    // TIMING CONTRACT (narrowed here; it was previously unconditional):
    //   sample_strobe period must be >= 64 enabled steps for the piano tone.
    // One lane is issued per clock and rom_lane wraps every 32, so after a
    // phase change lane g is issued at worst 32 clocks later and written back
    // 3 clocks after that. Settling, counted from the strobe:
    //   piano_value[g] correct from clock 35, products[] from 37, sum5 from 42.
    // Tones 0-2 carry no such window; they stay combinational per lane.
    //
    // The board cannot violate this. sample_strobe comes from pt8211_tx, whose
    // BCK_HALF_PERIOD_CYCLES=15 gives a 32-clock BCK and 32 BCK per stereo
    // frame: 1024 clocks per sample, fixed by the DAC protocol and by the
    // 48 kHz / "32 BCK per stereo frame" requirement in the project spec.
    // At half-rate this is 512 enabled steps, 8x the stated bound. All fill/
    // settling counts above mean enabled steps (35 to cache, 42 to sum5).
    // tb_poly_mix_pipeline checks the internal
    // cycle-exactness outside the settling window at 64/256/1024-clock rates,
    // and tb_poly_mix_fast_strobe proves a sub-bound rate is actually detected
    // rather than silently tolerated.
    reg  signed [15:0] piano_value [0:31];
    reg  [4:0] rom_lane, rom_lane_d1, rom_lane_d2;
    reg  [7:0] rom_frac_d1;
    reg  signed [15:0] rom_point_d1, rom_point_d2;
    reg  signed [16:0] rom_delta_d1;
    reg  signed [25:0] rom_interp_d2;
    wire [31:0] rom_phase = phase_accumulator[rom_lane];
    // Only [31:17] feeds the table and the fraction, so the 32:1 read mux is
    // trimmed to those bits. One shared mux replaces 32 replicated tables.
    wire signed [26:0] rom_result =
        $signed({{11{rom_point_d2[15]}}, rom_point_d2}) + (rom_interp_d2 >>> 8);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) rom_lane <= 5'd0;
        else if ((!CE_ENABLE || clock_enable)) if (!bank_enabled) rom_lane <= 5'd0;
        else rom_lane <= rom_lane + 5'd1;
    end
    always @(posedge clk) if ((!CE_ENABLE || clock_enable)) begin
        rom_point_d1  <= piano_point(rom_phase[31:25]);
        rom_delta_d1  <= piano_delta(rom_phase[31:25]);
        rom_frac_d1   <= rom_phase[24:17];
        rom_lane_d1   <= rom_lane;
        rom_interp_d2 <= rom_delta_d1 * $signed({1'b0, rom_frac_d1});
        rom_point_d2  <= rom_point_d1;
        rom_lane_d2   <= rom_lane_d1;
    end

    generate
        for (g=0; g<32; g=g+1) begin: u_product
            // Reset/disable clears the lane's cached point so a fill window
            // never publishes an undefined sample. The bank holds phase at 0
            // while disabled, and 0 is this table's value at phase 0.
            always @(posedge clk or negedge reset_n) begin
                if (!reset_n) piano_value[g] <= 16'sd0;
                else if ((!CE_ENABLE || clock_enable)) if (!bank_enabled) piano_value[g] <= 16'sd0;
                else if (rom_lane_d2 == g) piano_value[g] <= rom_result[15:0];
            end
            always @(posedge clk) if ((!CE_ENABLE || clock_enable)) begin
                wave_q[g] <= waveform_shared(phase_accumulator[g], tone_select,
                                             piano_value[g]);
                gain_q[g] <= $signed({1'b0, envelope_gain[g]});
                products[g] <= wave_q[g] * gain_q[g];
            end
            // 8 extra gain bits retain the original fixed mix headroom.
            assign lane_sample[g] = {{3{products[g][28]}}, products[g][28:16]};
        end
        for (g=0; g<16; g=g+1) begin: u_sum1
            always @(posedge clk) if ((!CE_ENABLE || clock_enable)) sum1[g] <=
                $signed({lane_sample[2*g][15], lane_sample[2*g]}) +
                $signed({lane_sample[2*g+1][15], lane_sample[2*g+1]});
        end
        for (g=0; g<8; g=g+1) begin: u_sum2
            always @(posedge clk) if ((!CE_ENABLE || clock_enable)) sum2[g] <=
                $signed({sum1[2*g][16], sum1[2*g]}) +
                $signed({sum1[2*g+1][16], sum1[2*g+1]});
        end
        for (g=0; g<4; g=g+1) begin: u_sum3
            always @(posedge clk) if ((!CE_ENABLE || clock_enable)) sum3[g] <=
                $signed({sum2[2*g][17], sum2[2*g]}) +
                $signed({sum2[2*g+1][17], sum2[2*g+1]});
        end
        for (g=0; g<2; g=g+1) begin: u_sum4
            always @(posedge clk) if ((!CE_ENABLE || clock_enable)) sum4[g] <=
                $signed({sum3[2*g][18], sum3[2*g]}) +
                $signed({sum3[2*g+1][18], sum3[2*g+1]});
        end
    endgenerate
    always @(posedge clk) if ((!CE_ENABLE || clock_enable)) sum5 <=
        $signed({sum4[0][19], sum4[0]}) + $signed({sum4[1][19], sum4[1]});

    reg [7:0] pipeline_ready;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin sample <= 0; pipeline_ready <= 0; end
        else if ((!CE_ENABLE || clock_enable)) if (!bank_enabled) begin sample <= 0; pipeline_ready <= 0; end
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
