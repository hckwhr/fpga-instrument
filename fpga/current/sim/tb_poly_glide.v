`timescale 1ns/1ps
module tb_poly_glide;
    reg clk=0,rst=0,enabled=1,events=0,pluck=0,chord=0;
    reg [2:0] trigger=0,gate=7;
    reg [3:0] note=0;
    reg [1:0] octave=0,glide=0;
    reg signed [7:0] bend=0;
    reg [7:0] depth=0;
    reg valid=0,on=1,flush=0;
    reg [15:0] id=1;
    wire ready;
    wire signed [15:0] pcm,old_pcm;
    wire [5:0] count;
    integer divider=0,i,j,speed,checks=0,ramps=0,steals=0,steps=0,slot=0,old_slot=0,fd;
    integer max_samples;
    reg [31:0] old_phase[0:31],old_step[0:31],old_base[0:31];
    reg [31:0] phase_check,ramp_check;
    wire [31:0] base[0:31];
    wire [31:0] unmodulated[0:31];
    wire [14:0] remaining[0:31];
    reg [31:0] origin,destination,previous,frozen;
    real actual_ratio,expected_ratio;
    wire strobe=divider==0;
    always #5 clk=~clk;
    always @(negedge clk) divider=(!rst || divider==1023)?0:divider+1;
    polyphony_bank_32 dut(.clk(clk),.reset_n(rst),.sample_strobe(strobe),.enable(enabled),
        .voice_trigger(trigger),.voice_gate(gate),.play_mode(pluck),.tone_select(2'd3),
        .note_select(note),.octave_select(octave),.keymap_select(chord),.force_value(7'd96),
        .glide_select(glide),.bend(bend),.vibrato_depth(depth),.event_mode(events),.event_flush(flush),
        .event_valid(valid),.event_on(on),.event_id(id),.event_note(note),.event_octave(octave),
        .event_force(7'd96),.event_ready(ready),.sample(pcm),.active_voice_count(count),
        .held_note_mask(),.all_voices_active());
    stage19_polyphony_bank_32 reference(.clk(clk),.reset_n(rst),.sample_strobe(strobe),.enable(enabled),
        .voice_trigger(trigger),.voice_gate(gate),.play_mode(pluck),.tone_select(2'd3),
        .note_select(note),.octave_select(octave),.keymap_select(chord),.force_value(7'd96),
        .bend(bend),.vibrato_depth(depth),.event_mode(events),.event_flush(flush),
        .event_valid(valid),.event_on(on),.event_id(id),.event_note(note),.event_octave(octave),
        .event_force(7'd96),.event_ready(),.sample(old_pcm),.active_voice_count(),
        .held_note_mask(),.all_voices_active());
    genvar g;
    generate for(g=0;g<32;g=g+1)begin: lanes
        assign base[g]=dut.u_voice_bank[g].glide_base;
        assign remaining[g]=dut.u_voice_bank[g].glide_left;
        assign unmodulated[g]=dut.u_voice_bank[g].unmodulated_increment;
        always @(posedge clk) if(rst && (strobe || (dut.allocate_voice && dut.search_index==g)))begin
            #2;
            if(dut.u_voice_bank[g].glide_active !== (remaining[g]!=15'd0))
                $fatal(1,"glide active/count mismatch lane %0d",g);
        end
        reg [31:0] outgoing;
        always @(posedge clk) if(rst && dut.allocate_voice && dut.search_index==g && dut.voice_active[g])begin
            outgoing=unmodulated[g];
            #2;
            if(dut.phase_increment_reg[g]!==outgoing)$fatal(1,"steal jumped from outgoing glide pitch");
        end
    end endgenerate
    always @(posedge clk) if(rst && strobe)begin
        phase_check=0;ramp_check=0;
        for(j=0;j<32;j=j+1)begin
            old_phase[j]=dut.phase_accumulator[j];old_step[j]=dut.expressed_increment[j];old_base[j]=base[j];
            phase_check[j]=enabled && !dut.owner_change && dut.voice_active[j] && !dut.voice_stealing[j] &&
                !(dut.allocate_voice && dut.search_index==j) && !(events && flush);
            ramp_check[j]=phase_check[j] && !events && glide!=0 && remaining[j]!=0;
        end
        #2;
        if((^pcm)===1'bx || pcm==32767 || pcm==-32768)$fatal(1,"unknown/clipped PCM");
        for(j=0;j<32;j=j+1)begin
            if(phase_check[j])begin
                if(dut.phase_accumulator[j]!==old_phase[j]+old_step[j])$fatal(1,"phase discontinuity lane %0d",j);
                checks=checks+1;
            end
            if(ramp_check[j])begin
                if((old_base[j]<dut.phase_increment_reg[j] && (base[j]<old_base[j] || base[j]>dut.phase_increment_reg[j])) ||
                   (old_base[j]>dut.phase_increment_reg[j] && (base[j]>old_base[j] || base[j]<dut.phase_increment_reg[j])))
                    $fatal(1,"ramp reversal/overshoot lane %0d",j);
                ramps=ramps+1;
            end
            if(dut.envelope_gain[j]!==reference.envelope_gain[j] || dut.voice_active[j]!==reference.voice_active[j])
                $fatal(1,"glide changed allocation/envelope lane %0d",j);
        end
        if(events && pcm!==old_pcm)$fatal(1,"glide leaked into score PCM");
    end
    task stream;input integer n;integer t;begin
        for(t=0;t<n;t=t+1)begin @(posedge clk);while(!strobe)@(posedge clk);#3;@(negedge clk);end
    end endtask
    task clear_bank;begin
        enabled=0;trigger=0;valid=0;stream(2);enabled=1;stream(2);
        if(count!=0 || dut.last_melody_valid)$fatal(1,"history/reset failure");
    end endtask
    task strike;input [2:0] keys;begin
        trigger=keys;stream(1);trigger=0;repeat(340)@(negedge clk);
        slot=(dut.next_voice_index-5'd1)&31;
    end endtask
    task finish_ramp;input integer limit;begin
        steps=0;destination=dut.phase_increment_reg[slot];
        while(remaining[slot]!=0 && steps<=limit)begin stream(1);steps=steps+1;end
        if(remaining[slot]!=0 || dut.expressed_increment[slot]!==destination)$fatal(1,"glide endpoint/duration");
        if(steps<limit-64 || steps>limit)$fatal(1,"unexpected glide length %0d expected <=%0d",steps,limit);
        $display("glide speed=%0d samples=%0d target=%0d",glide,steps,destination);
    end endtask
    initial begin
        repeat(8)@(negedge clk);rst=1;
        // Three durations, upward/downward across the full supported octave range.
        for(speed=1;speed<=3;speed=speed+1)begin
            clear_bank();glide=speed;note=0;octave=0;strike(1);
            if(remaining[slot]!=0)$fatal(1,"first note must start directly");
            origin=dut.phase_increment_reg[slot];note=11;octave=2;strike(1);
            if(base[slot]!==origin || remaining[slot]==0)$fatal(1,"upward origin");
            max_samples=4096<<(speed-1);finish_ramp(max_samples);
            origin=dut.phase_increment_reg[slot];note=0;octave=0;strike(1);
            if(base[slot]!==origin)$fatal(1,"downward origin");finish_ramp(max_samples);
            strike(1);if(remaining[slot]!=0)$fatal(1,"same-note unnecessary glide");
        end
        // Multiple keys and chord mapping are exact pitch, not a unison sweep.
        note=4;strike(3);if(dut.last_melody_valid)$fatal(1,"ambiguous history retained");
        if(remaining[slot]!=0 || remaining[(slot-1)&31]!=0)$fatal(1,"simultaneous keys glide");
        note=9;strike(1);if(remaining[slot]!=0)$fatal(1,"first after chord must be direct");
        chord=1;strike(7);
        if(dut.last_melody_valid)$fatal(1,"triad history retained");
        for(i=0;i<9;i=i+1)if(remaining[(slot-i)&31]!=0)$fatal(1,"mapped triad glide");
        // All lanes remain independent; full-pool steals freeze old ramps and fade.
        clear_bank();chord=0;glide=3;octave=1;
        for(i=0;i<32;i=i+1)begin note=i%12;strike(1);end
        if(count!=32)$fatal(1,"32 voice pool not full");
        stream(1000);
        for(i=0;i<8;i=i+1)begin
            note=(i+8)%12;strike(1);old_slot=slot;
            if(!dut.voice_stealing[slot])$fatal(1,"steal not active");
            frozen=dut.phase_increment_reg[slot];previous=base[slot];
            while(dut.voice_stealing[slot])begin
                if(dut.phase_increment_reg[slot]!==frozen || base[slot]!==previous)$fatal(1,"steal pitch not frozen");
                stream(1);
            end
            if(base[slot]!==previous || remaining[slot]==0)$fatal(1,"replacement glide lost");
            steals=steals+1;stream(10);
        end
        // Bend/vibrato multiply the current ramp pitch, then exact neutral bypass.
        bend=127;depth=64;stream(64);repeat(32)@(negedge clk);
        for(i=0;i<32;i=i+1)begin
            actual_ratio=$itor(dut.expressed_increment[i])/$itor(unmodulated[i]);
            expected_ratio=$itor(dut.expression_ratio)/262144.0;
            if(actual_ratio-expected_ratio>0.00001 || expected_ratio-actual_ratio>0.00001)
                $fatal(1,"expression not applied to gliding pitch lane %0d",i);
        end
        bend=0;depth=0;glide=0;stream(3);
        for(i=0;i<32;i=i+1)if(remaining[i]!=0 || dut.expressed_increment[i]!==dut.phase_increment_reg[i])
            $fatal(1,"off not exact");
        gate=0;stream(30000);if(count!=0 || pcm!=0)$fatal(1,"release not silent");
        // Pluck tail keeps its own ramp after release; disabling clears history.
        clear_bank();pluck=1;glide=1;note=0;strike(1);note=7;strike(1);
        if(remaining[slot]==0)$fatal(1,"pluck glide absent");finish_ramp(4096);
        clear_bank();note=4;strike(1);if(remaining[slot]!=0)$fatal(1,"disable retained history");
        // Nonzero settings must remain bit-exact through the event-owned path.
        events=1;glide=3;bend=-128;depth=128;stream(3);
        note=7;on=1;valid=1;@(posedge clk);while(!ready)@(posedge clk);@(negedge clk);valid=0;
        stream(1200);if(count!=1)$fatal(1,"score on failed");
        on=0;valid=1;@(posedge clk);while(!ready)@(posedge clk);@(negedge clk);valid=0;
        stream(3000);if(count!=0)$fatal(1,"score off failed");
        events=0;stream(3);note=0;strike(1);if(remaining[slot]!=0)$fatal(1,"owner change retained history");
        if(checks<100000 || ramps<10000 || steals!=8)$fatal(1,"insufficient coverage");
        $display("PASS: poly glide all speeds/up/down/same note/chord bypass/32 lanes/steals/pluck/tails/off/history/events; phase_checks=%0d ramp_checks=%0d steals=%0d",checks,ramps,steals);
        $finish;
    end
    initial begin #1800000000;$fatal(1,"timeout");end
endmodule
