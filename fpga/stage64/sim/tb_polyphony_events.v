`timescale 1ns/1ps
module tb_polyphony_events;
    reg clk=0, reset_n=0, enable=1, mode=1, flush=0, valid=0, note_on=1;
    reg [15:0] id=0;
    reg [3:0] note=0;
    reg [1:0] octave=1;
    reg [6:0] velocity=96;
    reg [2:0] keys=0, gates=0;
    integer divider=0, slot_clocks=1024, clocks=0;
    wire strobe=divider==0;
    wire ready;
    wire signed [15:0] pcm;
    wire [5:0] count;
    wire full;
    integer i,j,lane_a,lane_b,old_id,begin_clock,burst_clocks,max_on_clocks=0;
    integer peak=0,magnitude;
    polyphony_bank_32 dut(
        .bend(8'sd0),.vibrato_depth(8'd0),.glide_select(2'd0),
        .clk(clk),.reset_n(reset_n),.sample_strobe(strobe),.enable(enable),
        .voice_trigger(keys),.voice_gate(gates),.play_mode(1'b0),.tone_select(2'd3),
        .note_select(4'd0),.keymap_select(1'b0),.octave_select(2'd1),.force_value(7'd96),
        .event_mode(mode),.event_flush(flush),.event_valid(valid),.event_on(note_on),
        .event_id(id),.event_note(note),.event_octave(octave),.event_force(velocity),
        .event_ready(ready),.sample(pcm),.active_voice_count(count),.held_note_mask(),.all_voices_active(full));
    always #5 clk=~clk;
    always @(negedge clk) divider=(!reset_n || divider>=slot_clocks-1)?0:divider+1;
    always @(posedge clk) clocks=clocks+1;
    task tick; begin @(posedge clk); #1; end endtask
    task samples; input integer n; integer s;
        begin for(s=0;s<n;s=s+1)begin
            @(posedge clk); while(!strobe)@(posedge clk); #1;
            if((^pcm)===1'bx || pcm==32767 || pcm==-32768)$fatal(1,"unknown/clipped PCM");
            magnitude=pcm<0?-pcm:pcm;if(magnitude>peak)peak=magnitude;
        end end
    endtask
    task send_event; input on; input [15:0] occurrence; input [3:0] pitch;
        begin
            @(negedge clk);valid=1;note_on=on;id=occurrence;note=pitch;
            @(posedge clk);while(!ready)@(posedge clk);
            #1;@(negedge clk);valid=0;
        end
    endtask
    task settled;
        integer start;
        begin
            start=clocks;tick();while(dut.allocator_state!=0)tick();
            if(clocks-start>max_on_clocks)max_on_clocks=clocks-start;
        end
    endtask
    function integer find_id; input [15:0] occurrence; integer k;
        begin find_id=-1;for(k=0;k<32;k=k+1)
            if(dut.voice_id_valid[k] && dut.voice_id[k]==occurrence)find_id=k;
        end
    endfunction
    task reset_bank;
        begin @(negedge clk);reset_n=0;valid=0;flush=0;mode=1;keys=0;gates=0;
            repeat(3)tick();@(negedge clk);reset_n=1;repeat(3)tick();end
    endtask
    initial begin
        reset_bank();
        // The same pitch with two occurrence IDs must occupy two distinct lanes.
        send_event(1,16'hfffe,0);settled();send_event(1,16'hffff,0);settled();
        lane_a=find_id(16'hfffe);lane_b=find_id(16'hffff);
        if(count!=2 || lane_a<0 || lane_b<0 || lane_a==lane_b)$fatal(1,"same pitch merged occurrences");
        samples(256);
        send_event(0,16'hfffe,15);samples(1100);
        if(count!=1 || !dut.voice_active[lane_b] || dut.voice_releasing[lane_b])$fatal(1,"OFF released unrelated ID");
        send_event(1,16'hffff,7);settled();
        if(count!=1 || dut.phase_increment_reg[lane_b]!=23409859)$fatal(1,"duplicate ID retriggered/retuned");
        send_event(0,16'h1234,0);samples(2);
        if(count!=1 || dut.voice_releasing[lane_b])$fatal(1,"stale OFF released live note");
        send_event(1,0,7);settled();if(count!=2)$fatal(1,"wrapped ID zero invalid");
        send_event(1,1,12);settled();octave=3;send_event(1,2,0);settled();
        octave=1;velocity=0;send_event(1,3,0);settled();velocity=96;
        if(count!=2)$fatal(1,"invalid ON allocated a lane");
        // Physical input cannot leak into event ownership.
        keys=7;gates=7;samples(2);keys=0;
        if(count!=2)$fatal(1,"manual triggers leaked into score");

        reset_bank();begin_clock=clocks;
        for(i=0;i<32;i=i+1)begin send_event(1,i,i%12);settled();end
        burst_clocks=clocks-begin_clock;
        if(!full || count!=32)$fatal(1,"32 events failed to fill independent lanes");
        $display("EVENT empty-bank 32 ON burst=%0d clocks",burst_clocks);
        samples(256);
        // Full-bank replacement retains the old pitch until the fade ends.
        send_event(0,7,0);
        send_event(1,100,11);settled();lane_a=find_id(100);
        if(lane_a<0 || !dut.voice_stealing[lane_a] || count!=32)$fatal(1,"33rd note did not steal");
        if(lane_a!=7)$fatal(1,"event allocator replaced held note before released note");
        old_id=lane_a; // Initial sequential fill maps IDs 0..31 to lanes 0..31.
        send_event(0,old_id,0);samples(1);
        if(dut.voice_releasing[lane_a])$fatal(1,"old OFF killed stolen lane's new owner");
        send_event(0,100,0);samples(1100);
        if(dut.voice_active[lane_a] || count!=31)$fatal(1,"OFF during replacement left pending note alive");
        send_event(1,101,7);settled();samples(256);
        if(count!=32)$fatal(1,"freed lane not reused");
        // Measure full-bank burst separately; it is not an atomic 1024-clock batch.
        begin_clock=clocks;
        for(i=0;i<32;i=i+1)begin send_event(1,200+i,i%12);settled();end
        $display("EVENT full-bank 32 ON burst=%0d clocks; max observed allocation wait=%0d",clocks-begin_clock,max_on_clocks);
        // With every lane already fading, keep a new ON accepted/busy, then flush.
        send_event(1,999,0);
        @(negedge clk);flush=1;valid=1;note_on=1;id=1000;
        repeat(5)tick();if(ready || dut.allocator_state!=0)$fatal(1,"flush failed to cancel/stall transaction");
        @(negedge clk);valid=0;
        // Holding flush must continue fading, rather than freeze the envelopes.
        slot_clocks=32;samples(1100);
        if(count || pcm || dut.voice_id_valid || dut.voice_stealing)$fatal(1,"held flush failed to silence/clear IDs");
        @(negedge clk);flush=0;repeat(4)tick();samples(4);
        if(count)$fatal(1,"canceled allocation reappeared");
        send_event(1,1001,4);settled();samples(256);
        if(count!=1 || pcm==0)$fatal(1,"restart after flush failed");
        // Ownership change clears score lanes and permits normal key allocation.
        @(negedge clk);mode=0;tick();
        if(count || ready || pcm)$fatal(1,"owner transition retained score state");
        @(negedge clk);keys=1;gates=1;tick();@(negedge clk);keys=0;samples(2);settled();
        if(count!=1)$fatal(1,"manual owner cannot allocate after score");
        @(negedge clk);mode=1;tick();if(count)$fatal(1,"manual lane leaked into score");
        // Worst coherent mix: all lanes at maximum velocity, equal pitch/phase.
        reset_bank();slot_clocks=1024;velocity=127;
        for(i=0;i<32;i=i+1)begin send_event(1,2000+i,0);settled();end
        samples(1024);
        if(count!=32 || peak<10000 || peak>=16384)$fatal(1,"32-lane coherent full-force headroom failed: %0d",peak);
        enable=0;tick();if(ready || count || pcm)$fatal(1,"disable contract failed");
        if(peak<100 || peak>=32767)$fatal(1,"audio headroom coverage failed");
        $display("PASS: ID-specific release, repeated pitches, duplicate/invalid/stale events, wrap, 32 lanes, stealing cancellation, held flush, restart, owner isolation, peak=%0d",peak);
        $finish;
    end
    initial begin #150000000;$fatal(1,"event allocator timeout");end
endmodule
