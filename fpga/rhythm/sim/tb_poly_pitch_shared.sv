`timescale 1ns/1ps
// Frozen 54e is the oracle: no copy of the shared scheduler in the reference.
module pitch_shared_case #(parameter PERIOD=1024, NEGATIVE=0, SHARED_LANES=32, HALF_RATE=0)(output reg done=0);
    reg physical_clk=0,ce=1,rst=0,enabled=1,events=1,live=1,flush=0;
    always #5 physical_clk=~physical_clk;
    always @(negedge physical_clk) if(HALF_RATE)ce<=!ce;
    wire clk=physical_clk && ce;
    integer divider=0;
    always @(negedge clk) divider=(!rst || divider==PERIOD-1)?0:divider+1;
    wire strobe=divider==0;
    reg valid=0,on=1;
    reg [15:0] id=0;
    reg [3:0] note=0,root=0;
    reg [1:0] octave=1,tone=0,glide=0;
    reg [2:0] trigger=0,gate=7;
    reg signed [7:0] bend=0;
    reg [7:0] depth=0;
    wire ready,ref_ready;
    wire signed [15:0] pcm,ref_pcm;
    wire [5:0] count,ref_count;
    wire [11:0] held,ref_held;
    polyphony_bank_32 #(.CE_ENABLE(HALF_RATE),.LIVE_EVENT_SUPPORT(1),.SHARED_PITCH(1),
        .SHARED_PITCH_LANES(SHARED_LANES)) dut(
        .clk(physical_clk),.clock_enable(ce),.reset_n(rst),.sample_strobe(strobe),.enable(enabled),
        .voice_trigger(trigger),.voice_gate(gate),.play_mode(1'b0),.tone_select(tone),
        .note_select(root),.keymap_select(1'b0),.octave_select(octave),.force_value(7'd96),
        .key_forces(84'd0),.glide_select(glide),.bend(bend),.vibrato_depth(depth),
        .event_mode(events),.event_flush(flush),.event_valid(valid),.event_on(on),
        .live_event_enable(live),.event_id(id),.event_note(note),.event_octave(octave),
        .wide_event_octave(1'b0),.event_force(7'd96),.event_ready(ready),
        .sample(pcm),.active_voice_count(count),.held_note_mask(held),.all_voices_active());
    stage54e_polyphony_bank_32 #(.LIVE_EVENT_SUPPORT(1)) reference(
        .clk(clk),.reset_n(rst),.sample_strobe(strobe),.enable(enabled),
        .voice_trigger(trigger),.voice_gate(gate),.play_mode(1'b0),.tone_select(tone),
        .note_select(root),.keymap_select(1'b0),.octave_select(octave),.force_value(7'd96),
        .key_forces(84'd0),.glide_select(glide),.bend(bend),.vibrato_depth(depth),
        .event_mode(events),.event_flush(flush),.event_valid(valid),.event_on(on),
        .live_event_enable(live),.event_id(id),.event_note(note),.event_octave(octave),
        .wide_event_octave(1'b0),.event_force(7'd96),.event_ready(ref_ready),
        .sample(ref_pcm),.active_voice_count(ref_count),.held_note_mask(ref_held),.all_voices_active());
    reg compare=0;
    integer phase_differences=0,pcm_differences=0,checks=0,retunes=0,allocations=0;
    wire [31:0] cached_pitch[0:31],reference_pitch[0:31];
    genvar g;
    generate for(g=0;g<32;g=g+1)begin: check_lane
        assign cached_pitch[g]=dut.u_voice_bank[g].modulated_q;
        assign reference_pitch[g]=reference.u_voice_bank[g].modulated_q;
        reg replaced,was_enabled;
        reg [1:0] old_valid;
        reg [31:0] old_unmodulated;
        // Check every edge around both ownership transitions. In particular,
        // return and replacement on the same edge must never set cache-ready.
        always @(posedge clk)if(rst && !done)begin
            replaced=dut.u_voice_bank[g].pitch_replaced;
            was_enabled=dut.bank_enabled;
            old_valid=dut.u_voice_bank[g].pitch_valid;
            old_unmodulated=dut.u_voice_bank[g].unmodulated_increment;
            if(replaced)begin
                if(strobe)retunes=retunes+1;else allocations=allocations+1;
            end
            if(strobe && compare && !NEGATIVE && dut.expressed_increment[g] !== reference.expressed_increment[g])
                $fatal(1,"Pitch at consuming edge lane=%0d period=%0d got=%h ref=%h",g,PERIOD,dut.expressed_increment[g],reference.expressed_increment[g]);
            #1;
            if(!was_enabled || replaced)begin
                if(dut.u_voice_bank[g].pitch_valid!==0 ||
                   (g<SHARED_LANES && dut.u_voice_bank[g].pitch_cache_ready!==0))
                    $fatal(1,"Replacement/disable left pitch valid lane=%0d",g);
            end else if(dut.u_voice_bank[g].pitch_valid!=={old_valid[0],1'b1})
                $fatal(1,"Two-clock pitch_valid semantics changed lane=%0d",g);
            if(!dut.u_voice_bank[g].pitch_cache_ready &&
                dut.expressed_increment[g]!==dut.u_voice_bank[g].unmodulated_increment)
                $fatal(1,"Old owner leaked during bypass lane=%0d",g);
            if(compare && dut.phase_accumulator[g]!==reference.phase_accumulator[g])begin
                phase_differences=phase_differences+1;
                if(!NEGATIVE)$fatal(1,"Independent phase differs lane=%0d period=%0d",g,PERIOD);
            end
        end
    end endgenerate
    always @(posedge clk)begin
        #2;
        if(rst && !done)begin
            if({ready,count,held,dut.voice_active,dut.voice_stealing,dut.voice_releasing} !==
               {ref_ready,ref_count,ref_held,reference.voice_active,reference.voice_stealing,reference.voice_releasing})
                $fatal(1,"Shared pitch changed allocator/envelope ownership period=%0d",PERIOD);
            if(compare)begin
                checks=checks+1;
                if(pcm!==ref_pcm)begin
                    pcm_differences=pcm_differences+1;
                    if(!NEGATIVE)$fatal(1,"PCM differs period=%0d time=%t",PERIOD,$time);
                end
            end
        end
    end
    task samples(input integer n);
        repeat(n)begin @(posedge strobe);@(negedge clk);end
    endtask
    task send(input integer number,input bit is_on);
        @(negedge clk);id=number;note=number%12;on=is_on;valid=1;
        do @(posedge clk);while(!ready);
        @(negedge clk);valid=0;
    endtask
    task strike(input [2:0] keys);
        samples(1);trigger=keys;samples(1);trigger=0;
    endtask
    integer i,k;
    reg signed [17:0] arithmetic_delta;
    initial begin
        repeat(5)@(negedge clk);rst=1;samples(4);
        // Fill with expression bypassed, then exercise all 32 lane products.
        for(i=0;i<32;i=i+1)begin send(i,1);samples(4);end
        samples(260);if(count!=32)$fatal(1,"Pitch test did not fill all 32 lanes");compare=1;
        samples(1);bend=-128;depth=128;samples(100);
        for(i=0;i<64;i=i+1)begin
            // The real performance controller updates on audio boundaries.
            samples(1);bend=(i%3==0)?-128:(i%3==1)?127:i-32;
            depth=(i%3==0)?255:(i%3==1)?0:64;tone=i%3;
            samples(3);
        end
        // Replace occupied lanes while modulation is active, including the
        // zero-gain handover. All oscillator/envelope state is still parallel.
        for(i=32;i<72;i=i+1)begin send(i,1);samples(20);end
        samples(40);
        for(i=40;i<72;i=i+1)send(i,0);
        samples(20);flush=1;samples(3);flush=0;samples(4);
        // Disable/owner change/reset with shared arithmetic in flight.
        enabled=0;samples(3);enabled=1;samples(3);events=0;samples(3);
        if(PERIOD==1024 || (HALF_RATE && PERIOD==512))begin
            glide=1;root=0;strike(1);samples(20);
            root=11;strike(2);samples(80);
            glide=2;root=2;strike(1);samples(80);
            glide=3;root=9;strike(4);samples(80);
            gate=0;samples(20);
        end
        rst=0;repeat(4)@(negedge clk);rst=1;samples(4);
        if(retunes==0 || allocations<32)$fatal(1,"Missing pitch ownership coverage");
        if(NEGATIVE && (phase_differences==0 || pcm_differences==0))
            $fatal(1,"Sub-bound pitch strobe did not diverge from frozen 54e");
        if(PERIOD==1024 || (HALF_RATE && PERIOD==512))begin
            compare=0;enabled=0;samples(1);enabled=1;samples(1);
            // Exercise full signed coefficient/increment widths, including
            // upper saturation, independently of the musical note range.
            force dut.pitch_delta=arithmetic_delta;
            force reference.pitch_delta=arithmetic_delta;
            for(k=0;k<5;k=k+1)begin
                arithmetic_delta=(k==0)?-18'sd131072:(k==1)?18'sd131071:
                    (k==2)?-18'sd1:(k==3)?18'sd0:18'sd1;
                @(negedge clk);
                for(i=0;i<32;i=i+1)begin
                    dut.phase_increment_reg[i]=(i%4==0)?32'd0:(i%4==1)?32'hffffffff:
                        (i%4==2)?32'h80000001:32'h000001ff+i;
                    reference.phase_increment_reg[i]=dut.phase_increment_reg[i];
                end
                repeat(40)@(negedge clk);
                for(i=0;i<32;i=i+1)if(cached_pitch[i]!==reference_pitch[i])
                    $fatal(1,"Pitch signed-width/saturation mismatch coefficient=%0d lane=%0d",arithmetic_delta,i);
            end
            release dut.pitch_delta;release reference.pitch_delta;
        end
        $display("Pitch shared lanes=%0d period=%0d negative=%0d checks=%0d phase_diff=%0d pcm_diff=%0d retunes=%0d allocations=%0d",SHARED_LANES,PERIOD,NEGATIVE,checks,phase_differences,pcm_differences,retunes,allocations);
        done=1;
    end
endmodule

module tb_half_rate_pitch;
    wire a,b,c;
    pitch_shared_case #(.HALF_RATE(1),.PERIOD(512),.SHARED_LANES(16)) production(a);
    pitch_shared_case #(.HALF_RATE(1),.PERIOD(64),.SHARED_LANES(16)) boundary(b);
    pitch_shared_case #(.HALF_RATE(1),.PERIOD(8),.NEGATIVE(1),.SHARED_LANES(16)) negative(c);
    initial begin wait(a && b && c);$display("PASS: real CE pitch at 512/64 engine steps matches frozen 54e; 8-step negative diverges, all 32 phases/owners checked");$finish;end
    initial begin #50000000;$fatal(1,"CE pitch timeout");end
endmodule

module tb_poly_pitch_shared;
    wire a,b;
    pitch_shared_case #(.PERIOD(1024)) production(a);
    pitch_shared_case #(.PERIOD(64)) boundary(b);
    initial begin wait(a && b);$display("PASS: shared pitch bit-exact phase/PCM against frozen 54e at 64/1024 clocks; 32 lanes, extrema, vibrato, glide, steals, reset, owner change");$finish;end
    initial begin #40000000;$fatal(1,"Shared pitch test timeout");end
endmodule

module tb_poly_pitch_fast_strobe;
    wire done;
    pitch_shared_case #(.PERIOD(16),.NEGATIVE(1)) negative(done);
    initial begin wait(done);$display("PASS: sub-bound 16-clock shared pitch produces phase AND PCM divergence from frozen 54e");$finish;end
    initial begin #4000000;$fatal(1,"Fast pitch test timeout");end
endmodule

module tb_poly_pitch_half_shared;
    wire a,b;
    pitch_shared_case #(.PERIOD(1024),.SHARED_LANES(16)) production(a);
    pitch_shared_case #(.PERIOD(64),.SHARED_LANES(16)) boundary(b);
    initial begin wait(a && b);$display("PASS: 16 shared plus 16 parallel pitch lanes match frozen 54e phase/PCM at 64/1024 clocks, including all 32 owners and saturation");$finish;end
    initial begin #40000000;$fatal(1,"Half-shared pitch test timeout");end
endmodule

module tb_poly_pitch_half_fast_strobe;
    wire done;
    pitch_shared_case #(.PERIOD(8),.NEGATIVE(1),.SHARED_LANES(16)) negative(done);
    initial begin wait(done);$display("PASS: sub-bound 8-clock half-shared pitch produces phase AND PCM divergence from frozen 54e");$finish;end
    initial begin #4000000;$fatal(1,"Fast half-shared pitch test timeout");end
endmodule
