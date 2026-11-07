`timescale 1ns/1ps
module tb_instrumental_envelope;
    reg clk=0,reset_n=0,valid=0,on_event=1,live=0;
    reg [15:0] id=0;
    reg [3:0] note=0;
    reg [6:0] velocity=80;
    integer divider=0,i,k,lane_a,lane_b,lane_c,peak=0,magnitude;
    wire ce=!divider[0];
    wire strobe=divider==0;
    wire ready,reference_ready;
    wire signed [15:0] pcm,reference_pcm;
    wire [5:0] count;
    always #5 clk=~clk;
    always @(negedge clk) divider=(!reset_n || divider==127)?0:divider+1;
    polyphony_bank_32 #(.CE_ENABLE(1),.LIVE_EVENT_SUPPORT(1),
        .SCORE_ENVELOPE_ENABLE(1),.SUSTAIN_COMPARE_PIPELINE(1)) dut (
        .clk(clk),.reset_n(reset_n),.clock_enable(ce),.sample_strobe(strobe),.enable(1'b1),
        .voice_trigger(3'd0),.voice_gate(3'd0),.play_mode(1'b0),.tone_select(2'd3),
        .note_select(4'd0),.keymap_select(1'b0),.octave_select(2'd1),.force_value(7'd80),
        .key_forces(84'd0),.glide_select(2'd0),.bend(8'sd0),.vibrato_depth(8'd0),
        .event_mode(1'b1),.event_flush(1'b0),.event_valid(valid),.event_on(on_event),
        .event_id(id),.event_note(note),.event_octave(2'd1),.event_force(velocity),
        .live_event_enable(live),.keyboard_piano(1'b0),.wide_event_octave(1'b0),
        .event_ready(ready),.sample(pcm),.active_voice_count(count),.held_note_mask(),.all_voices_active());
    // Disabled feature is the executable legacy reference, including live force.
    polyphony_bank_32 #(.CE_ENABLE(1),.LIVE_EVENT_SUPPORT(1),
        .SCORE_ENVELOPE_ENABLE(0),.SUSTAIN_COMPARE_PIPELINE(1)) reference (
        .clk(clk),.reset_n(reset_n),.clock_enable(ce),.sample_strobe(strobe),.enable(1'b1),
        .voice_trigger(3'd0),.voice_gate(3'd0),.play_mode(1'b0),.tone_select(2'd3),
        .note_select(4'd0),.keymap_select(1'b0),.octave_select(2'd1),.force_value(7'd80),
        .key_forces(84'd0),.glide_select(2'd0),.bend(8'sd0),.vibrato_depth(8'd0),
        .event_mode(1'b1),.event_flush(1'b0),.event_valid(valid),.event_on(on_event),
        .event_id(id),.event_note(note),.event_octave(2'd1),.event_force(velocity),
        .live_event_enable(live),.keyboard_piano(1'b0),.wide_event_octave(1'b0),
        .event_ready(reference_ready),.sample(reference_pcm),.active_voice_count(),.held_note_mask(),.all_voices_active());
    task tick; begin @(posedge clk); #1; end endtask
    task reset_bank; begin
        @(negedge clk);reset_n=0;valid=0;repeat(4)tick();
        @(negedge clk);reset_n=1;repeat(4)tick();
    end endtask
    task send; input is_on; input [15:0] occurrence; input [3:0] pitch;
        begin
            @(negedge clk);valid=1;on_event=is_on;id=occurrence;note=pitch;
            @(posedge clk);while(!ready || !reference_ready || !ce)@(posedge clk);
            #1;@(negedge clk);valid=0;
            tick();while(dut.allocator_state!=0 || reference.allocator_state!=0)tick();
        end
    endtask
    task samples; input integer n; integer s;
        begin for(s=0;s<n;s=s+1)begin
            @(posedge clk);while(!strobe)@(posedge clk);#1;
            if((^pcm)===1'bx || pcm==32767 || pcm==-32768)$fatal(1,"invalid/clipped PCM");
            magnitude=pcm<0?-pcm:pcm;if(magnitude>peak)peak=magnitude;
            if(live && pcm!==reference_pcm)$fatal(1,"live keyboard changed at sample %0d",s);
        end end
    endtask
    function integer find; input [15:0] occurrence; integer j;
        begin find=-1;for(j=0;j<32;j=j+1)
            if(dut.voice_id_valid[j] && dut.voice_id[j]==occurrence)find=j;
        end
    endfunction
    initial begin
        reset_bank();
        send(1,1,0);lane_a=find(1);
        velocity=40;send(1,2,4);lane_b=find(2);
        velocity=127;send(1,3,7);lane_c=find(3);
        if(lane_a<0 || lane_b<0 || lane_c<0 || count!=3)$fatal(1,"chord allocation failed");
        samples(500);
        if(dut.envelope_gain[lane_a]>=2560 || dut.envelope_gain[lane_a]<=1280 ||
           !dut.voice_decaying[lane_a])$fatal(1,"score attack/decay missing");
        if(reference.envelope_gain[lane_a]!=2560)$fatal(1,"disabled legacy peak changed");
        samples(18000);
        if(dut.envelope_gain[lane_a]!=1280 || dut.envelope_gain[lane_b]!=640 ||
           dut.envelope_gain[lane_c]!=2040)$fatal(1,"velocity-dependent 50%% sustain incorrect");
        samples(128);
        if(dut.envelope_gain[lane_a]!=1280)$fatal(1,"sustain drift");
        send(0,1,0);samples(1200);
        if(dut.voice_active[lane_a] || !dut.voice_active[lane_b] || !dut.voice_active[lane_c])
            $fatal(1,"ID-specific OFF/release tail failed");
        // Repeated pitch uses a new owner; stale OFF must not kill the new ON.
        velocity=80;send(1,4,0);lane_a=find(4);samples(180);
        send(0,1,0);samples(10);
        if(lane_a<0 || !dut.voice_id_valid[lane_a] || dut.voice_releasing[lane_a])$fatal(1,"stale OFF killed retrigger");
        send(0,2,0);send(0,3,0);send(0,4,0);samples(1200);
        if(count || pcm)$fatal(1,"release did not silence all notes");
        // Production half-rate CE and all existing live envelope behavior match.
        live=1;reset_bank();velocity=80;send(1,10,0);samples(6000);
        send(0,10,0);samples(1200);
        if(count || peak<10)$fatal(1,"audio activity/release coverage missing");
        $display("PASS: score attack/decay/50%% sustain, velocity, chord, ID release/retrigger, half-rate CE, live bit-exact isolation; peak=%0d",peak);
        $finish;
    end
    initial begin #100000000;$fatal(1,"instrumental envelope timeout");end
endmodule
