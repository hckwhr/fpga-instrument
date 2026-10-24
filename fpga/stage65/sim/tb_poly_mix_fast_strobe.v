`timescale 1ns/1ps
// Negative test for the shared piano wavetable's timing contract.
//
// polyphony_bank_32 states that sample_strobe must be at least 64 clocks apart
// for the piano tone, because the shared table refreshes one lane per clock and
// wraps every 32. tb_poly_mix_pipeline checks the compliant side of that bound.
// This bench drives a 16-clock strobe, deliberately below it, and REQUIRES the
// published sample to diverge from the frozen stage9 reference.
//
// A pass here means the bound is real and observable. If the two never diverged
// the bound would be unfounded, and the settling window that tb_poly_mix_pipeline
// now skips would be hiding a defect instead of documenting one - so "no
// divergence" is a failure in this bench, not a success.
module tb_poly_mix_fast_strobe;
    reg clk=0,reset_n=0,strobe=0,enable=1;
    reg [2:0] triggers=0,gates=3'b111;
    reg [1:0] tone=2'd3,octave=2'd1;   // tone 3 = piano: the shared table
    reg [3:0] note=0;
    reg [6:0] velocity=96;
    wire ready,old_ready;
    wire signed [15:0] pcm,old_pcm;
    wire [5:0] count,old_count;
    wire [11:0] mask,old_mask;
    integer cycle,divergences=0,nonzero=0;
    always #5 clk=~clk;

    polyphony_bank_32 dut(
        .bend(8'sd0),.vibrato_depth(8'd0),.glide_select(2'd0),
        .clk(clk),.reset_n(reset_n),.sample_strobe(strobe),.enable(enable),
        .voice_trigger(triggers),.voice_gate(gates),.play_mode(1'b1),.tone_select(tone),
        .note_select(note),.keymap_select(1'b0),.octave_select(octave),.force_value(velocity),
        .event_mode(1'b0),.event_flush(1'b0),.event_valid(1'b0),.event_on(1'b1),
        .event_id(16'd0),.event_note(4'd0),.event_octave(2'd1),.event_force(7'd96),
        .event_ready(ready),.sample(pcm),.active_voice_count(count),
        .held_note_mask(mask),.all_voices_active());
    stage9_polyphony_bank_32 reference(
        .clk(clk),.reset_n(reset_n),.sample_strobe(strobe),.enable(enable),
        .voice_trigger(triggers),.voice_gate(gates),.play_mode(1'b1),.tone_select(tone),
        .note_select(note),.keymap_select(1'b0),.octave_select(octave),.force_value(velocity),
        .event_mode(1'b0),.event_flush(1'b0),.event_valid(1'b0),.event_on(1'b1),
        .event_id(16'd0),.event_note(4'd0),.event_octave(2'd1),.event_force(7'd96),
        .event_ready(old_ready),.sample(old_pcm),.active_voice_count(old_count),
        .held_note_mask(old_mask),.all_voices_active());

    initial begin
        repeat(3)@(negedge clk);reset_n=1;repeat(20)@(negedge clk);
        for(cycle=0;cycle<60000;cycle=cycle+1)begin
            @(negedge clk);
            strobe=(cycle%16==0);          // below the stated 64-clock bound
            triggers=0;
            if(cycle%1301==0)begin         // keep fresh piano voices sounding
                note=(note+4'd3)%12; triggers=3'b001;
            end
            @(posedge clk);
            #1;
            if(pcm!==old_pcm)divergences=divergences+1;
            if(old_pcm!=0)nonzero=nonzero+1;
        end
        if(nonzero<5000)
            $fatal(1,"reference produced too little audio to judge: %0d",nonzero);
        if(divergences==0)
            $fatal(1,"a 16-clock strobe did not disturb the shared table; the stated 64-clock bound is unfounded and tb_poly_mix_pipeline's settling window must be re-examined");
        $display("PASS: sub-bound 16-clock strobe diverges from frozen stage9 on %0d of 60000 cycles (reference nonzero=%0d), so the 64-clock piano contract is observable, not assumed",divergences,nonzero);
        $finish;
    end
endmodule
