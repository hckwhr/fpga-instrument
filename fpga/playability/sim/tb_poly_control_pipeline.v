`timescale 1ns/1ps
// Production input register vs the unchanged bank with direct manual inputs.
// Compare every clock at exactly +1, including updates adjacent to strobes.
module tb_poly_control_pipeline;
    reg clk=0, strobe=0, enabled=0, pluck=0, keymap=0;
    reg [2:0] trigger=0,gate=0;
    reg [1:0] tone=3,octave=1;
    reg [3:0] note=0;
    reg [6:0] velocity=96;
    reg [31:0] rng=32'h18273645;
    wire signed [15:0] ref_pcm;
    wire [5:0] ref_count;
    wire ref_full;
    reg signed [15:0] expected_pcm;
    reg [5:0] expected_count;
    reg [31:0] expected_phase[0:31];
    reg [11:0] expected_gain[0:31];
    integer cycle,lane,nonzero=0;
    always #5 clk=~clk;
    av_top dut(.sys_clk(clk),.key0_n(1'b1),.key1_n(1'b1),.key2_n(1'b1),.setting_key(1'b0),
        .hc05_rx(1'b1),.hc05_tx(),.status_led(),.audio_bck(),.audio_ws(),.audio_din(),.audio_pa_en_n(),
        .lcd_pclk(),.lcd_hsync(),.lcd_vsync(),.lcd_de(),.lcd_bl(),.lcd_r(),.lcd_g(),.lcd_b());
    polyphony_bank_32 reference(
        .bend(8'sd0),.vibrato_depth(8'd0),.glide_select(2'd0),
        .clk(clk),.reset_n(dut.audio_internal_reset_n),.sample_strobe(strobe),.enable(enabled),
        .voice_trigger(trigger),.voice_gate(gate),.play_mode(pluck),.tone_select(tone),
        .note_select(note),.keymap_select(keymap),.octave_select(octave),.force_value(velocity),
        .event_mode(1'b0),.event_flush(1'b0),.event_valid(1'b0),.event_on(1'b0),
        .event_id(16'd0),.event_note(4'd0),.event_octave(2'd0),.event_force(7'd0),.event_ready(),
        .sample(ref_pcm),.active_voice_count(ref_count),.held_note_mask(),.all_voices_active(ref_full));
    initial begin
        force dut.audio_sample_strobe=strobe;
        force dut.self_test_active=enabled;force dut.test_polyphony=1'b1;force dut.audition_mode=1'b0;
        force dut.key_play_trigger=trigger;
        force dut.key0_pressed=gate[0];force dut.key1_pressed=gate[1];force dut.key2_pressed=gate[2];
        force dut.play_mode=pluck;force dut.keymap_select=keymap;
        force dut.tone_select=tone;force dut.octave_select=octave;force dut.note_select=note;
        force dut.performance_force=velocity;
        repeat(32)@(negedge clk);
        for(cycle=0;cycle<220000;cycle=cycle+1)begin
            @(negedge clk);
            strobe=(cycle%((cycle<110000)?1024:512)==0);trigger=0;
            enabled=(cycle%10013!=0);
            if(cycle%257==0)begin
                rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
                {pluck,keymap,tone}=rng[3:0];octave=rng[5:4]%3;note=rng[9:6]%12;
                velocity=32+{1'b0,rng[15:10]};gate=rng[18:16];trigger=rng[21:19];
            end
            @(posedge clk);
            expected_pcm=ref_pcm;expected_count=ref_count;
            for(lane=0;lane<32;lane=lane+1)begin
                expected_phase[lane]=reference.phase_accumulator[lane];
                expected_gain[lane]=reference.envelope_gain[lane];
            end
            #1;
            if(dut.polyphony_test_sample!==expected_pcm || dut.polyphony_active_voice_count!==expected_count)
                $fatal(1,"manual bank pipeline mismatch at clock %0d",cycle);
            for(lane=0;lane<32;lane=lane+1)
                if(dut.u_polyphony_bank_32.phase_accumulator[lane]!==expected_phase[lane] ||
                   dut.u_polyphony_bank_32.envelope_gain[lane]!==expected_gain[lane])
                    $fatal(1,"manual phase/gain mismatch clock=%0d lane=%0d",cycle,lane);
            if(dut.polyphony_test_sample!=0)nonzero=nonzero+1;
        end
        if(nonzero<10000)$fatal(1,"insufficient nonzero coverage: %0d",nonzero);
        $display("PASS: 220000 exact +1-clock manual PCM/count/all-lane phase/gain comparisons, 1024/512 cadence, boundary control changes, disable pulses; nonzero=%0d",nonzero);
        $finish;
    end
endmodule
