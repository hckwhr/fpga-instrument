`timescale 1ns/1ps
`default_nettype none
module tb_polyphony_bank_32;
    reg clk;
    reg reset_n;
    reg sample_strobe;
    reg enable;
    reg play_mode;
    reg keymap_select;
    reg [2:0] voice_trigger;
    reg [2:0] voice_gate;
    reg [1:0] tone_select;
    reg [1:0] octave_select;
    reg [3:0] note_select;
    reg [6:0] force_value;
    wire signed [15:0] sample;
    wire [5:0] active_voice_count;
    wire all_voices_active;
    integer error_count;
    integer index;
    integer peak_sample;
    integer sample_magnitude;
    integer ref_sum, ref_product, ref_index;
    integer stolen_index, stolen_gain;
    reg signed [15:0] ref_wave;
    reg [31:0] phase_before_steal, increment_before_steal;

    polyphony_bank_32 #(
        .PLUCK_DECAY_INTERVAL_SAMPLES(6000),
        .TOUCH_RELEASE_INTERVAL_SAMPLES(1),
        .ATTACK_STEP(12'd256)
    ) dut (
        .bend(8'sd0),.vibrato_depth(8'd0),.glide_select(2'd0),
        .event_mode(1'b0),.event_flush(1'b0),.event_valid(1'b0),.event_on(1'b0),
        .event_id(16'd0),.event_note(4'd0),.event_octave(2'd0),.event_force(7'd0),.event_ready(),
        .clk(clk), .reset_n(reset_n), .sample_strobe(sample_strobe),
        .enable(enable), .voice_trigger(voice_trigger), .voice_gate(voice_gate),
        .play_mode(play_mode), .tone_select(tone_select),
        .note_select(note_select), .keymap_select(keymap_select),
        .octave_select(octave_select), .force_value(force_value),
        .sample(sample), .active_voice_count(active_voice_count),
        .held_note_mask(), .all_voices_active(all_voices_active)
    );

    always #5 clk = ~clk;

    task clock_once;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task pulse_sample;
        begin
            ref_sum = 0;
            for (ref_index=0; ref_index<32; ref_index=ref_index+1) begin
                ref_wave = dut.waveform(dut.phase_accumulator[ref_index], tone_select);
                ref_product = ref_wave * $signed({1'b0, dut.envelope_gain[ref_index]});
                ref_sum = ref_sum + (ref_product >>> 16);
            end
            sample_strobe = 1'b1;
            clock_once();
            sample_strobe = 1'b0;
            voice_trigger = 0;
            if (enable && dut.pipeline_ready[7])
                expect(sample === ref_sum, "pipelined parallel mix differs from reference sum");
            repeat (320) clock_once();
            expect(dut.allocator_state == 0, "allocation exceeded 320-clock budget");
            repeat (703) clock_once();
        end
    endtask

    task trigger_key;
        input [2:0] key_value;
        begin
            voice_trigger = key_value;
            pulse_sample();
            voice_trigger = 3'b000;
        end
    endtask

    task expect;
        input condition;
        input [8*100-1:0] message;
        begin
            if (!condition) begin
                $display("ERROR: %0s", message);
                error_count = error_count + 1;
            end
        end
    endtask

    task apply_reset;
        begin
            reset_n = 1'b0;
            sample_strobe = 1'b0;
            enable = 1'b0;
            voice_trigger = 3'b000;
            voice_gate = 3'b000;
            repeat (3) clock_once();
            reset_n = 1'b1;
            clock_once();
            enable = 1'b1;
        end
    endtask

    initial begin
        clk = 1'b0;
        reset_n = 1'b0;
        sample_strobe = 1'b0;
        enable = 1'b0;
        voice_trigger = 3'b000;
        voice_gate = 3'b000;
        play_mode = 1'b1;
        tone_select = 2'd0;
        note_select = 4'd0;
        keymap_select = 1'b0;
        octave_select = 2'd1;
        force_value = 7'd96;
        error_count = 0;
        peak_sample = 0;

        apply_reset();
        expect(active_voice_count == 6'd0, "reset count was not zero");
        for (index = 0; index < 32; index = index + 1)
            trigger_key(3'b001);
        expect(active_voice_count == 6'd32, "32 presses did not reach 32/32");
        expect(all_voices_active, "all slots were not active");
        trigger_key(3'b010);
        stolen_index=-1;
        for(index=0;index<32;index=index+1)
            if(dut.voice_stealing[index]) stolen_index=index;
        expect(stolen_index>=0,"full bank did not schedule a faded replacement");
        if(stolen_index<0) $fatal(1,"no stolen lane");
        stolen_gain=dut.envelope_gain[stolen_index];
        for(index=0;index<32;index=index+1)
            expect(stolen_gain<=dut.envelope_gain[index],"allocator did not choose quietest lane");
        expect(dut.phase_increment_reg[stolen_index]==32'd23_409_859,
               "stolen lane changed pitch before fading out");
        expect(active_voice_count == 6'd32, "voice stealing changed full count");
        repeat(16) pulse_sample();
        expect(!dut.voice_stealing[stolen_index],"replacement fade exceeded 16 samples");
        expect(dut.phase_increment_reg[stolen_index] == 32'd26_276_679,
               "voice stealing note was not D4");
        for (index = 0; index < 64; index = index + 1) begin
            pulse_sample();
            sample_magnitude = (sample < 0) ? -sample : sample;
            if (sample_magnitude > peak_sample)
                peak_sample = sample_magnitude;
        end
        expect(peak_sample > 100, "dynamic mix was silent");
        expect(peak_sample < 16384, "dynamic mix exhausted headroom");

        apply_reset();
        keymap_select = 1'b1;
        play_mode = 1'b1;
        trigger_key(3'b001);
        expect(active_voice_count == 6'd3, "one chord key did not allocate triad");
        expect(dut.phase_increment_reg[0] == 32'd23_409_859, "C root incorrect");
        expect(dut.phase_increment_reg[1] == 32'd29_494_575, "E third incorrect");
        expect(dut.phase_increment_reg[2] == 32'd35_075_158, "G fifth incorrect");
        trigger_key(3'b010);
        expect(active_voice_count == 6'd6, "second chord did not add three voices");
        trigger_key(3'b111);
        expect(active_voice_count == 6'd15, "three simultaneous keys lost a triad");
        repeat (2) trigger_key(3'b111);
        expect(active_voice_count == 6'd32, "simultaneous triads failed to fill bank");
        trigger_key(3'b111);
        expect(active_voice_count == 6'd32, "full-bank nine-note steal failed");

        // A hole behind the round-robin cursor must be reused before stealing
        // First check a full bank: a released voice wins over a quieter held one.
        apply_reset(); keymap_select=0; play_mode=0; voice_gate=3'b011;
        repeat(16) trigger_key(3'b001);
        repeat(16) trigger_key(3'b010);
        voice_gate=3'b010;
        trigger_key(3'b010);
        expect((|dut.voice_stealing[15:0]) && !(|dut.voice_stealing[31:16]),
               "allocator replaced a held voice before a released voice");

        // A hole behind the round-robin cursor must be reused before stealing
        // a still-held voice. KEY0 releases, KEY1 remains held.
        apply_reset();
        keymap_select = 0;
        play_mode = 0;
        voice_gate = 3'b011;
        trigger_key(3'b001);
        trigger_key(3'b010);
        repeat (20) pulse_sample();
        voice_gate = 3'b010;
        repeat (1024) pulse_sample();
        expect(active_voice_count == 1, "independent key release failed");
        expect(dut.voice_active[1], "release killed unrelated held voice");
        repeat (30) trigger_key(3'b010);
        expect(active_voice_count == 31, "free bank fill incorrect");
        trigger_key(3'b010);
        expect(active_voice_count == 32 && dut.voice_active[0],
               "allocator stole a held lane instead of reusing free slot");

        apply_reset();
        keymap_select = 1'b0;
        play_mode = 1'b0;
        voice_gate = 3'b001;
        trigger_key(3'b001);
        repeat (20) pulse_sample();
        expect(active_voice_count == 6'd1, "touch voice did not remain held");
        voice_gate = 3'b000;
        repeat (1024) pulse_sample();
        expect(active_voice_count == 6'd0, "touch voice did not release");
        enable = 1'b0;
        pulse_sample();
        expect(sample == 16'sd0, "disable did not silence output");

        if (error_count == 0) begin
            $display("PASS: dynamic 32-voice allocation, one-key triads, voice stealing, release, and headroom checks passed");
            $finish;
        end else begin
            $fatal(1, "FAIL: %0d dynamic-polyphony checks failed", error_count);
        end
    end
endmodule
`default_nettype wire
