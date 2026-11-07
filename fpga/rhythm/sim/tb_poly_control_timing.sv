`timescale 1ns/1ps
// Frozen pre-optimization RTL is the oracle. Inputs change off-edge; a stalled
// transaction retains its identity. Compare externally used state each clock,
// including reset/flush/owner changes and CE-low cycles. The gain datapath
// changes must preserve every externally observed update edge and PCM value.
module poly_control_timing_check #(parameter integer HALF=0)(output reg done=0);
    reg clk=0, reset_n=0, ce=0, strobe=0, enable=1;
    reg mode=1, flush=0, valid=0, on_event=1, live=1, single_note=1;
    reg [15:0] id=0, next_id=0;
    reg [3:0] note=0;
    reg [1:0] octave=1, instrument=0, tone=3;
    reg [2:0] trigger=0, gate=7;
    reg pluck=0;
    reg [6:0] force_value=96;
    reg [31:0] rng=32'h7281ac45;
    wire ready, old_ready, full, old_full;
    wire signed [15:0] pcm, old_pcm;
    wire [5:0] count, old_count;
    wire [11:0] held, old_held, guide, old_guide;
    reg accepted=0;
    integer cycle, lane, ons=0, offs=0, stalled=0, writes=0, steals=0, sound=0;
    always #5 clk=~clk;
`define TIMING_PARAMETERS .CE_ENABLE(HALF),.MULTI_TIMBRE_ENABLE(1), \
    .LIVE_EVENT_SUPPORT(1),.LIVE_ARTICULATION(1),.KEY_GUIDE_ENABLE(1), \
    .SCORE_ENVELOPE_ENABLE(1),.KEYBOARD_SCALE_SUPPORT(1), \
    .SHARED_PITCH(1),.SHARED_PITCH_LANES(16),.SUSTAIN_COMPARE_PIPELINE(1)
`define TIMING_INPUTS .clk(clk),.reset_n(reset_n),.clock_enable(ce), \
    .sample_strobe(strobe),.enable(enable),.voice_trigger(trigger),.voice_gate(gate), \
    .play_mode(pluck),.tone_select(tone),.instrument_select(instrument), \
    .note_select(note),.keymap_select(1'b0),.octave_select(octave), \
    .force_value(force_value),.key_forces({12{7'd96}}),.glide_select(2'd1), \
    .bend(8'sd4),.vibrato_depth(8'd24),.event_mode(mode),.event_flush(flush), \
    .event_valid(valid),.event_on(on_event),.live_event_enable(live), \
    .live_single_note(single_note),.keyboard_piano(1'b1),.custom_enabled(1'b0), \
    .custom_map(72'd0),.event_id(id),.event_note(note),.event_octave(octave), \
    .wide_event_octave(1'b0),.event_force(force_value)
    polyphony_bank_32 #(`TIMING_PARAMETERS) dut(`TIMING_INPUTS,
        .event_ready(ready),.sample(pcm),.active_voice_count(count),
        .held_note_mask(held),.guide_key_mask(guide),.all_voices_active(full));
    timing_reference_polyphony_bank_32 #(`TIMING_PARAMETERS) reference(`TIMING_INPUTS,
        .event_ready(old_ready),.sample(old_pcm),.active_voice_count(old_count),
        .held_note_mask(old_held),.guide_key_mask(old_guide),.all_voices_active(old_full));
`undef TIMING_PARAMETERS
`undef TIMING_INPUTS
    initial begin
        repeat(3) @(negedge clk);
        for(cycle=0;cycle<240000;cycle=cycle+1) begin
            @(negedge clk);
            ce=!cycle[0]; strobe=(cycle%1024==0);
            reset_n=(cycle%60001!=0);
            enable=(cycle%47003!=0);
            mode=(cycle%60000<50000);
            flush=(cycle%23003==0);
            live=(cycle%60000<40000);
            single_note=(cycle%16000<12000);
            trigger=(cycle%2048==0)?3'b101:3'b000;
            if(!reset_n || !enable || flush || !mode) valid=0;
            else if(accepted) valid=0;
            else if(!valid && cycle%7==0) begin
                rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
                next_id=next_id+1'b1; valid=1;
                on_event=(next_id%5!=0);
                // Repeated IDs, stale OFFs and invalid payloads are consumed
                // without changing allocation/ownership differently.
                id=on_event ? (next_id%13==0 ? next_id-1'b1 : next_id) : next_id-16'd2;
                note=(next_id%29==0)?4'd15:rng[3:0]%12;
                octave=(next_id%31==0)?2'd3:2'd1;
                force_value=(next_id%37==0)?7'd0:7'd96;
                pluck=rng[7]; instrument=rng[9:8]; tone=3;
            end
            @(posedge clk);
            accepted=reset_n && (!HALF || ce) && valid && ready;
            if(accepted) begin if(on_event)ons++;else offs++;end
            if(valid && !ready)stalled++;
            if(reset_n && (!HALF || ce) && dut.allocate_voice) begin
                writes++;if(dut.voice_active[dut.search_index])steals++;
            end
            #1;
            if({ready,pcm,count,held,guide,full}!=={old_ready,old_pcm,old_count,old_held,old_guide,old_full})
                $fatal(1,"HALF=%0d interface cycle=%0d pcm=%0d/%0d",HALF,cycle,pcm,old_pcm);
            if({dut.allocator_state,dut.next_voice_index,dut.search_index,dut.search_count,
                dut.best_valid,dut.best_released,dut.best_index,dut.best_gain,dut.allocate_voice}!==
               {reference.allocator_state,reference.next_voice_index,reference.search_index,reference.search_count,
                reference.best_valid,reference.best_released,reference.best_index,reference.best_gain,reference.allocate_voice})
                $fatal(1,"HALF=%0d allocator cycle=%0d",HALF,cycle);
            if({dut.voice_active,dut.voice_stealing,dut.voice_attacking,dut.voice_decaying,
                dut.voice_releasing,dut.voice_one_shot,dut.voice_id_valid}!==
               {reference.voice_active,reference.voice_stealing,reference.voice_attacking,reference.voice_decaying,
                reference.voice_releasing,reference.voice_one_shot,reference.voice_id_valid})
                $fatal(1,"HALF=%0d ownership/envelope flags cycle=%0d",HALF,cycle);
            for(lane=0;lane<32;lane++)begin
                if({dut.phase_accumulator[lane],dut.phase_increment_reg[lane],dut.pending_increment[lane],
                    dut.envelope_gain[lane],dut.envelope_target[lane],dut.envelope_count[lane],
                    dut.voice_id[lane],dut.voice_note[lane],dut.voice_source[lane],dut.voice_guide[lane]}!==
                   {reference.phase_accumulator[lane],reference.phase_increment_reg[lane],reference.pending_increment[lane],
                    reference.envelope_gain[lane],reference.envelope_target[lane],reference.envelope_count[lane],
                    reference.voice_id[lane],reference.voice_note[lane],reference.voice_source[lane],reference.voice_guide[lane]})
                    $fatal(1,"HALF=%0d lane=%0d cycle=%0d",HALF,lane,cycle);
            end
            if(pcm!=0)sound++;
        end
        if(ons<100 || offs<20 || stalled<100 || writes<100 || steals<10 || sound<1000)
            $fatal(1,"coverage HALF=%0d on=%0d off=%0d stall=%0d write=%0d steal=%0d sound=%0d",
                HALF,ons,offs,stalled,writes,steals,sound);
        $display("timing equivalence HALF=%0d cycles=240000 on=%0d off=%0d stall=%0d write=%0d steal=%0d sound=%0d",
            HALF,ons,offs,stalled,writes,steals,sound);
        done=1;
    end
endmodule

module tb_poly_control_timing;
    wire full_done, half_done;
    poly_control_timing_check #(.HALF(0)) full_rate(full_done);
    poly_control_timing_check #(.HALF(1)) half_rate(half_done);
    initial begin
        wait(full_done && half_done);
        $display("PASS: frozen RTL cycle-exact control/PCM comparison, 480000 clocks, full and half CE");
        $finish;
    end
    initial begin #2500000; $fatal(1,"control timing equivalence timeout"); end
endmodule
