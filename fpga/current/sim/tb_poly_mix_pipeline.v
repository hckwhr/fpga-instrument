`timescale 1ns/1ps
// Frozen old allocator + waveform/mix, versus the added wave/gain register.
// Arbitrary edge-adjacent inputs exercise the exact +1 internal clock contract;
// Metadata/phase/envelope remain cycle-identical for unchanged pluck/events.
//
// Scope change: the piano tone's wavetable is now one shared sequential table
// instead of 32 combinational copies, so the per-lane product and the sum tree
// need a bounded settling window after each strobe (products from clock 37,
// sum5 from 42; see the TIMING CONTRACT in polyphony_bank_32.v). The published
// sample, the allocator/held-note interface and all 32 lanes' phase, envelope
// and voice_id stay cycle-identical to the frozen reference and are still
// checked unconditionally, every cycle, including inside that window.
// The strobe rates below were 12/32/1024; 12 and 32 are shorter than the
// stated 64-clock bound, so they moved to 64/256/1024. The board's rate is
// fixed at 1024 by pt8211_tx and by the 48 kHz spec. That a sub-bound rate is
// genuinely detected, rather than assumed safe, is proven separately by
// tb_poly_mix_fast_strobe.
// Manual touch now has intentional ADSR decay; covered by tb_poly_adsr.
module tb_poly_mix_pipeline;
    reg clk=0,reset_n=0,strobe=0,enable=1,mode=0,flush=0,valid=0,on=1;
    reg [2:0] triggers=0,gates=0;
    reg pluck=0,keymap=0;
    reg [1:0] tone=3,octave=1;
    reg [3:0] note=0,event_note=0;
    reg [6:0] velocity=96;
    reg [15:0] id=0;
    reg [31:0] rng=32'h29164578;
    wire ready,old_ready;
    wire signed [15:0] pcm,old_pcm;
    wire [5:0] count,old_count;
    wire [11:0] mask,old_mask;
    reg signed [28:0] old_products[0:31];
    reg signed [20:0] old_sum,delayed_old_sum;
    reg signed [15:0] expected_pcm=0;
    reg accepted_last=0;
    integer cycle,lane,nonzero=0,stable_pcm_checks=0;
    integer since_strobe=0,settled_checks=0;
    // products[] settle at 37 and sum5 at 42 after a strobe; 48 keeps margin.
    localparam integer SETTLED_AFTER=48;
    // Slower legal strobes mean fewer strobes per cycle, so the run is extended
    // to keep at least the original ~9200 strobes rather than lower the
    // coverage thresholds below. 8000 + 2000 + 250 = 10250 strobes.
    localparam integer PHASE1_END=512000, PHASE2_END=1024000, TOTAL=1280000;
    always #5 clk=~clk;
    polyphony_bank_32 dut(
        .bend(8'sd0),.vibrato_depth(8'd0),.glide_select(2'd0),
        .clk(clk),.reset_n(reset_n),.sample_strobe(strobe),.enable(enable),
        .voice_trigger(triggers),.voice_gate(gates),.play_mode(pluck),.tone_select(tone),
        .note_select(note),.keymap_select(keymap),.octave_select(octave),.force_value(velocity),
        .event_mode(mode),.event_flush(flush),.event_valid(valid),.event_on(on),
        .event_id(id),.event_note(event_note),.event_octave(2'd1),.event_force(7'd96),
        .event_ready(ready),.sample(pcm),.active_voice_count(count),.held_note_mask(mask),.all_voices_active());
    stage9_polyphony_bank_32 reference(
        .clk(clk),.reset_n(reset_n),.sample_strobe(strobe),.enable(enable),
        .voice_trigger(triggers),.voice_gate(gates),.play_mode(pluck),.tone_select(tone),
        .note_select(note),.keymap_select(keymap),.octave_select(octave),.force_value(velocity),
        .event_mode(mode),.event_flush(flush),.event_valid(valid),.event_on(on),
        .event_id(id),.event_note(event_note),.event_octave(2'd1),.event_force(7'd96),
        .event_ready(old_ready),.sample(old_pcm),.active_voice_count(old_count),.held_note_mask(old_mask),.all_voices_active());
    function signed [15:0] saturate;
        input signed [20:0] mixed;
        begin saturate=(mixed>21'sd32767)?16'sh7fff:
            (mixed < -21'sd32768)?16'sh8000:mixed[15:0];end
    endfunction
    initial begin
        repeat(3)@(negedge clk);reset_n=1;repeat(20)@(negedge clk);
        delayed_old_sum=reference.sum5;
        for(cycle=0;cycle<TOTAL;cycle=cycle+1)begin
            @(negedge clk);
            strobe=(cycle%((cycle<PHASE1_END)?64:(cycle<PHASE2_END)?256:1024)==0);
            reset_n=(cycle%100003!=0);enable=(cycle%17011!=0);
            mode=(cycle>=PHASE1_END);flush=(cycle%10007==0);triggers=0;
            if(cycle%97==0)begin
                rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
                {pluck,keymap,tone}=rng[3:0];octave=rng[5:4]%3;note=rng[9:6]%12;
                velocity=32+{1'b0,rng[15:10]};gates=rng[18:16];triggers=rng[21:19];
            end
            pluck=1; // Freeze the unchanged manual envelope for equivalence.
            if(!reset_n || !mode || flush)valid=0;
            else if(accepted_last)valid=0;
            else if(!valid && cycle%13==0)begin
                valid=1;id=id+1'b1;event_note=id%12;on=(id[2:0]!=0);
            end
            @(posedge clk);
            accepted_last=valid && ready;
            for(lane=0;lane<32;lane=lane+1)old_products[lane]=reference.products[lane];
            old_sum=reference.sum5;
            if(!reset_n || !enable || mode!=dut.event_mode_d)expected_pcm=0;
            else if(strobe)expected_pcm=dut.pipeline_ready[7]?saturate(delayed_old_sum):16'sd0;
            #1;
            since_strobe=strobe?0:since_strobe+1;
            if(pcm!==expected_pcm)$fatal(1,"retimed PCM contract cycle=%0d",cycle);
            if({count,mask,ready}!=={old_count,old_mask,old_ready})
                $fatal(1,"allocator/held-note interface changed cycle=%0d",cycle);
            if(since_strobe>=SETTLED_AFTER)begin
                if(dut.sum5!==old_sum)$fatal(1,"sum tree is not exact +1 clock at %0d",cycle);
                settled_checks=settled_checks+1;
            end
            for(lane=0;lane<32;lane=lane+1)begin
                if(since_strobe>=SETTLED_AFTER && dut.products[lane]!==old_products[lane])
                    $fatal(1,"unaligned wave/gain lane=%0d cycle=%0d",lane,cycle);
                // Voice state is never retimed: checked every cycle, settled or not.
                if({dut.phase_accumulator[lane],dut.envelope_gain[lane],dut.voice_id[lane]}!==
                   {reference.phase_accumulator[lane],reference.envelope_gain[lane],reference.voice_id[lane]})
                    $fatal(1,"voice state changed lane=%0d cycle=%0d",lane,cycle);
            end
            if(strobe && dut.pipeline_ready[7] && old_sum===delayed_old_sum)begin
                if(pcm!==old_pcm)$fatal(1,"settled sample differs");
                stable_pcm_checks=stable_pcm_checks+1;
            end
            delayed_old_sum=old_sum;
            if(pcm!=0)nonzero=nonzero+1;
        end
        if(nonzero<10000 || stable_pcm_checks<3000)$fatal(1,"insufficient audio coverage");
        if(settled_checks<50000)$fatal(1,"settled-window coverage too thin: %0d",settled_checks);
        $display("PASS: %0d frozen-stage9 checks at 64/256/1024-clock strobes; PCM, allocator interface and all 32 lanes' phase/envelope/voice_id cycle-identical every cycle; product/sum-tree exactness on %0d settled cycles; settled PCM checks=%0d nonzero=%0d",TOTAL,settled_checks,stable_pcm_checks,nonzero);
        $finish;
    end
endmodule
