`timescale 1ns/1ps
// Inject overlapping score events at the actual top-level receiver boundary.
// Keep the real 1024-clock sample cadence, allocator, mixer and effects path.
module tb_song_event_path;
    reg clk=0,valid=0,on=1,flush=0;
    reg [15:0] id=0;
    reg [3:0] note=0;
    reg [9:0] divider=0;
    wire strobe=divider==0;
    integer k,peak=0,mag,accepted=0,before_flush;
    av_top dut(.sys_clk(clk),.key0_n(1'b1),.key1_n(1'b1),.key2_n(1'b1),.setting_key(1'b0),
        .hc05_rx(1'b1),.hc05_tx(),.status_led(),.audio_bck(),.audio_ws(),.audio_din(),.audio_pa_en_n(),
        .lcd_pclk(),.lcd_hsync(),.lcd_vsync(),.lcd_de(),.lcd_bl(),.lcd_r(),.lcd_g(),.lcd_b());
    always #5 clk=~clk;
    always @(negedge clk)divider=divider+1'b1;
    always @(posedge clk)if(valid && dut.song_event_ready && !flush)accepted=accepted+1;
    task tick;begin @(posedge clk);#1;end endtask
    task samples;input integer n;integer s;
        begin for(s=0;s<n;s=s+1)begin
            @(posedge clk);while(!strobe)@(posedge clk);#1;
            if((^dut.audio_sample)===1'bx)$fatal(1,"unknown production PCM");
            if(dut.pre_effect_audio_sample!==dut.song_audio_sample ||
               $signed(dut.song_audio_sample)!==($signed(dut.polyphony_test_sample)*8))
                $fatal(1,"song bypassed event bank/fixed gain");
            mag=dut.audio_sample<0?-dut.audio_sample:dut.audio_sample;
            if(mag>=32767)$fatal(1,"event chord clipped");if(mag>peak)peak=mag;
            if(dut.displayed_voice_count!==dut.polyphony_active_voice_count)$fatal(1,"voice status count mismatch");
        end end
    endtask
    task send;input is_on;input[15:0] occurrence;input[3:0] pitch;
        begin @(negedge clk);valid=1;on=is_on;id=occurrence;note=pitch;
            @(posedge clk);while(!dut.song_event_ready)@(posedge clk);
            #1;@(negedge clk);valid=0;end
    endtask
    initial begin
        force dut.audio_sample_strobe=strobe;
        force dut.audition_mode=1'b1;force dut.audition_target=3'd7;
        force dut.setting_mode=1'b0;force dut.test_mode=1'b0;
        force dut.song_event_valid=valid;force dut.song_event_on=on;
        force dut.song_event_id=id;force dut.song_event_note=note;
        force dut.song_event_octave=2'd1;force dut.song_event_force=7'd96;
        force dut.song_event_flush=flush;
        // A distinctive old-engine sample proves the selected output is new.
        force dut.raw_audio_sample=16'sd12345;
        repeat(25)tick();
        send(1,10,0);send(1,20,4);send(1,30,7);samples(1200);
        if(dut.polyphony_active_voice_count!=3 || peak<500)$fatal(1,"overlapping triad not audible: count=%0d peak=%0d accepts=%0d",dut.polyphony_active_voice_count,peak,accepted);
        if(dut.u_polyphony_bank_32.phase_increment_reg[0]!=23409859 ||
           dut.u_polyphony_bank_32.phase_increment_reg[1]!=29494575 ||
           dut.u_polyphony_bank_32.phase_increment_reg[2]!=35075158)$fatal(1,"independent pitches lost");
        send(0,20,0);samples(1100);
        if(dut.polyphony_active_voice_count!=2 || dut.u_polyphony_bank_32.voice_active[1] ||
           !dut.u_polyphony_bank_32.voice_active[0] || !dut.u_polyphony_bank_32.voice_active[2])
            $fatal(1,"top-level OFF did not preserve the other two notes");
        if(accepted!=4)$fatal(1,"event consumed twice or lost");
        @(negedge clk);flush=1;samples(1100);
        if(dut.audio_sample || dut.polyphony_active_voice_count || dut.song_gate)$fatal(1,"production flush left audio/state");
        @(negedge clk);flush=0;send(1,40,2);samples(300);
        if(dut.polyphony_active_voice_count!=1 || accepted!=5)$fatal(1,"production restart failed");
        @(negedge clk);flush=1;samples(1100);@(negedge clk);flush=0;
        // Stop at each early allocator position. Acceptance must stop at once,
        // even though the bank receives the coherent control bundle next clock.
        for(k=0;k<8;k=k+1)begin
            send(1,100+k,0);repeat(k)tick();
            @(negedge clk);flush=1;valid=1;id=200+k;before_flush=accepted;
            #1;if(dut.song_event_ready)$fatal(1,"flush did not block event acceptance immediately");
            tick();@(negedge clk);valid=0;flush=0;
            samples(64);
            if(accepted!=before_flush || dut.polyphony_active_voice_count || dut.song_gate || dut.audio_sample)
                $fatal(1,"one-clock flush leaked event/state at allocator offset %0d",k);
        end
        $display("PASS: production 1024-clock overlapping C/E/G, exact acceptance, independent release, routing/count, flush/restart and 8 single-clock cancellation positions, peak=%0d",peak);
        $finish;
    end
    initial begin #100000000;$fatal(1,"production event path timeout");end
    // Stage 30b harness: this bench forces av_top's mode wires directly, which
    // bypasses instrument_control. The three mode decodes are now registered
    // inside that module, so follow the forced wires with the same decode the
    // top level used to build. tb_song_page_mirror proves the registered
    // copies equal this decode on every clock for unforced operation.
    initial begin
        force dut.audition_active = dut.audition_mode && !dut.setting_mode && !dut.test_mode;
        force dut.song_active = dut.audition_mode && !dut.setting_mode && !dut.test_mode && dut.audition_target == 3'd7;
        force dut.self_test_active = dut.test_mode && !dut.setting_mode;
    end
endmodule
