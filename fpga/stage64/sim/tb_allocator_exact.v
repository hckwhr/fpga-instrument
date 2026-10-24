`timescale 1ns/1ps
// Compare the production engine to frozen stage 16 on every clock, including
// scans that cross envelope updates. No forced internal state or reference mux.
//
// The accelerated phases below exist to hammer the allocator state machine, not
// to model a real sample rate: 16- and 32-clock strobes correspond to ~3 MHz and
// ~1.5 MHz audio. The board runs at 1024 clocks (48 kHz), fixed by pt8211_tx.
// The piano tone's wavetable is now one shared sequential table rather than 32
// combinational copies, and it needs >=64 clocks between strobes (see TIMING
// CONTRACT in polyphony_bank_32.v). So the accelerated phases drive tones 0-2,
// which stay combinational per lane and carry no such window, while the
// production-rate phases sweep all four tones including the piano. Allocation,
// stealing, envelopes and the published interface are compared every cycle in
// both, so no allocator coverage is given up.
// Verified while making this change: with the accelerated phases set to
// production rates instead, the original unrestricted stimulus passes all
// 300000 cycles, which is what identifies the settling window - not a defect -
// as the only reason the piano tone could not run at 16 clocks here.
module tb_allocator_exact;
    reg clk=0,reset_n=0,strobe=0,enable=1,mode=0,flush=0,valid=0,note_on=1;
    reg [2:0] triggers=0,gates=7;
    reg pluck=0,keymap=1;
    reg [1:0] tone=0,octave=1;
    reg [3:0] note=0,event_note=0;
    reg [6:0] velocity=96,event_force=96;
    reg [15:0] id=0,sequence_id=0;
    reg [31:0] rng=32'h710a462d;
    reg accepted_last=0;
    wire ready,old_ready,full,old_full;
    wire signed [15:0] pcm,old_pcm;
    wire [5:0] count,old_count;
    wire [11:0] mask,old_mask;
    integer cycle,lane,writes=0,steals=0,full_cycles=0,searches=0,boundaries=0,nonzero=0;
    always #5 clk=~clk;
    polyphony_bank_32 dut(
        .bend(8'sd0),.vibrato_depth(8'd0),.glide_select(2'd0),
        .clk(clk),.reset_n(reset_n),.sample_strobe(strobe),.enable(enable),
        .voice_trigger(triggers),.voice_gate(gates),.play_mode(pluck),.tone_select(tone),
        .note_select(note),.keymap_select(keymap),.octave_select(octave),.force_value(velocity),
        .event_mode(mode),.event_flush(flush),.event_valid(valid),.event_on(note_on),
        .event_id(id),.event_note(event_note),.event_octave(octave),.event_force(event_force),
        .event_ready(ready),.sample(pcm),.active_voice_count(count),.held_note_mask(mask),.all_voices_active(full));
    stage16_polyphony_bank_32 reference(
        .clk(clk),.reset_n(reset_n),.sample_strobe(strobe),.enable(enable),
        .voice_trigger(triggers),.voice_gate(gates),.play_mode(pluck),.tone_select(tone),
        .note_select(note),.keymap_select(keymap),.octave_select(octave),.force_value(velocity),
        .event_mode(mode),.event_flush(flush),.event_valid(valid),.event_on(note_on),
        .event_id(id),.event_note(event_note),.event_octave(octave),.event_force(event_force),
        .event_ready(old_ready),.sample(old_pcm),.active_voice_count(old_count),.held_note_mask(old_mask),.all_voices_active(old_full));
    initial begin
        repeat(3)@(negedge clk);reset_n=1;
        for(cycle=0;cycle<300000;cycle=cycle+1)begin
            @(negedge clk);
            // Accelerated stress, then both production and half-rate slots.
            strobe=(cycle%((cycle<100000)?16:(cycle<200000)?32:(cycle<250000)?1024:512)==0);
            reset_n=(cycle%99001!=0);enable=(cycle%37003!=0);
            mode=(cycle>=100000 && cycle<200000);flush=(cycle%19001==0);triggers=0;
            if(cycle%97==0)begin
                rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
                {pluck,keymap,tone}=rng[3:0];octave=rng[5:4]%3;note=rng[9:6]%12;
                // Piano (tone 3) needs >=64 clocks between strobes; the first
                // two phases are faster than that, so keep them on tones 0-2.
                if(cycle<200000 && tone==2'd3)tone=rng[10]?2'd0:2'd1;
                velocity=rng[16:10];gates=rng[19:17];triggers=rng[22:20];
            end
            if(!reset_n || !mode || flush)valid=0;
            else if(accepted_last)valid=0;
            else if(!valid && cycle%13==0)begin
                sequence_id=sequence_id+1'b1;
                valid=1;note_on=(sequence_id[2:0]!=0);
                id=note_on?sequence_id:sequence_id-16'd7;
                event_note=rng[3:0];event_force=rng[18:12];
            end
            @(posedge clk);
            accepted_last=valid && ready;
            if(reset_n && enable)begin
                if(dut.allocate_voice)begin
                    writes=writes+1;
                    if(dut.voice_active[dut.search_index])steals=steals+1;
                end
                if(dut.allocator_state==2)begin
                    searches=searches+1;
                    if(strobe)boundaries=boundaries+1;
                    if({dut.candidate_gain,dut.candidate_released,dut.candidate_better}!==
                       {reference.candidate_gain,reference.candidate_released,reference.candidate_better})
                        $fatal(1,"candidate differs cycle=%0d",cycle);
                end
            end
            #1;
            if({pcm,count,mask,ready,full}!=={old_pcm,old_count,old_mask,old_ready,old_full})
                $fatal(1,"engine interface differs cycle=%0d",cycle);
            if({dut.allocator_state,dut.next_voice_index,dut.search_index,dut.search_count,
                dut.best_valid,dut.best_released,dut.best_index,dut.best_gain,dut.allocate_voice}!==
               {reference.allocator_state,reference.next_voice_index,reference.search_index,reference.search_count,
                reference.best_valid,reference.best_released,reference.best_index,reference.best_gain,reference.allocate_voice})
                $fatal(1,"allocator state differs cycle=%0d",cycle);
            if({dut.voice_active,dut.voice_stealing,dut.voice_attacking,dut.voice_decaying,
                dut.voice_releasing,dut.voice_one_shot,dut.voice_id_valid}!==
               {reference.voice_active,reference.voice_stealing,reference.voice_attacking,reference.voice_decaying,
                reference.voice_releasing,reference.voice_one_shot,reference.voice_id_valid})
                $fatal(1,"lane flags differ cycle=%0d",cycle);
            for(lane=0;lane<32;lane=lane+1)begin
                if({dut.phase_accumulator[lane],dut.phase_increment_reg[lane],dut.pending_increment[lane],
                    dut.envelope_gain[lane],dut.envelope_target[lane],dut.envelope_count[lane],
                    dut.voice_id[lane],dut.voice_note[lane],dut.voice_source[lane]}!==
                   {reference.phase_accumulator[lane],reference.phase_increment_reg[lane],reference.pending_increment[lane],
                    reference.envelope_gain[lane],reference.envelope_target[lane],reference.envelope_count[lane],
                    reference.voice_id[lane],reference.voice_note[lane],reference.voice_source[lane]})
                    $fatal(1,"lane state differs lane=%0d cycle=%0d",lane,cycle);
            end
            if(full)full_cycles=full_cycles+1;
            if(pcm!=0)nonzero=nonzero+1;
        end
        if(writes<100 || steals<10 || full_cycles<1000 || boundaries<100 || nonzero<10000)
            $fatal(1,"insufficient coverage writes=%0d steals=%0d full=%0d boundaries=%0d pcm=%0d",writes,steals,full_cycles,boundaries,nonzero);
        $display("PASS: 300000 cycle-exact stage16 allocator/PCM and 32-lane state comparisons (tones 0-2 at 16/32-clock stress, all four tones at 1024/512-clock production rates); writes=%0d steals=%0d full_cycles=%0d searches=%0d sample_boundary_scans=%0d nonzero=%0d",writes,steals,full_cycles,searches,boundaries,nonzero);
        $finish;
    end
    initial begin #4000000;$fatal(1,"timeout");end
endmodule
