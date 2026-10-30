`timescale 1ns/1ps
// Production top: real allocator, 1024-clock samples, CDC and LCD renderer.
// Batch injection is a simulation driver, not an on-board multitrack song.
module tb_song_poly_display;
    `include "instrument_contract.vh"
    reg clk=0,pixel_clk=0,valid=0,on=1,flush=0,frame=0;
    reg [15:0] id=0;
    reg [3:0] note=0;
    reg [9:0] divider=0;
    reg [10:0] x=60;
    reg [9:0] y=210;
    wire strobe=divider==0;
    integer clocks=0,accepted=0,start_clock,burst_clocks,k;
    integer peak=0,mag;
    reg [11:0] old_mask;
    av_top dut(.sys_clk(clk),.key0_n(1'b1),.key1_n(1'b1),.key2_n(1'b1),.setting_key(1'b0),
        .hc05_rx(1'b1),.hc05_tx(),.status_led(),.audio_bck(),.audio_ws(),.audio_din(),.audio_pa_en_n(),
        .lcd_pclk(),.lcd_hsync(),.lcd_vsync(),.lcd_de(),.lcd_bl(),.lcd_r(),.lcd_g(),.lcd_b());
    always #5 clk=~clk;
    always #7 pixel_clk=~pixel_clk;
    always @(negedge clk) divider=divider+1'b1;
    always @(posedge clk) begin
        clocks=clocks+1;
        if(valid && dut.song_event_ready)accepted=accepted+1;
    end
    task tick;begin @(posedge clk);#1;end endtask
    task samples;input integer n;integer s;
        begin for(s=0;s<n;s=s+1)begin
            @(posedge clk);while(!strobe)@(posedge clk);#1;
            if((^dut.audio_sample)===1'bx)$fatal(1,"unknown PCM");
            // Synthetic 32-note injection exceeds the five-held-note song
            // arrangement. Check the bank's original headroom here; the full
            // arrangement test checks final boosted PCM without clipping.
            mag=dut.polyphony_test_sample<0?-dut.polyphony_test_sample:dut.polyphony_test_sample;
            if(mag>=32767)$fatal(1,"bank burst clipped");if(mag>peak)peak=mag;
            if(dut.polyphony_test_sample>4095 && dut.song_audio_sample!==16'sh7fff)
                $fatal(1,"positive score gain failed to saturate");
            if(dut.polyphony_test_sample < -4096 && dut.song_audio_sample!==16'sh8000)
                $fatal(1,"negative score gain failed to saturate");
        end end
    endtask
    task send;input is_on;input[15:0] occurrence;input[3:0] pitch;
        begin @(negedge clk);valid=1;on=is_on;id=occurrence;note=pitch;
            @(posedge clk);while(!dut.song_event_ready)@(posedge clk);
            #1;@(negedge clk);valid=0;
        end
    endtask
    task settle;begin tick();while(dut.u_polyphony_bank_32.allocator_state!=0)tick();end endtask
    task display_mask;input[11:0] expected;integer p;
        begin
            // Permit the next audio snapshot and the real bundled CDC handshake.
            old_mask=dut.u_lcd_test_pattern.song_notes_active;
            samples(2);repeat(80)tick();
            if(dut.song_held_notes!==expected ||
                dut.status_payload_pixel[ST_HELD_NOTES+:12]!==expected)
                $fatal(1,"allocator/CDC note mask mismatch: expected=%h bank=%h pixel=%h",expected,dut.song_held_notes,dut.status_payload_pixel[ST_HELD_NOTES+:12]);
            if(dut.u_lcd_test_pattern.song_notes_active!==old_mask)
                $fatal(1,"keyboard changed within frame");
            @(negedge pixel_clk);frame=1;@(negedge pixel_clk);frame=0;tick();
            if(dut.u_lcd_test_pattern.song_notes_active!==expected)
                $fatal(1,"frame commit did not publish complete note mask");
            for(p=0;p<12;p=p+1)begin
                @(negedge clk);
                case(p)
                    0:begin x=60;y=210;end 1:begin x=120;y=130;end
                    2:begin x=170;y=210;end 3:begin x=230;y=130;end
                    4:begin x=280;y=210;end 5:begin x=390;y=210;end
                    6:begin x=450;y=130;end 7:begin x=500;y=210;end
                    8:begin x=560;y=130;end 9:begin x=610;y=210;end
                    10:begin x=670;y=130;end default:begin x=720;y=210;end
                endcase
                tick();
                if(dut.u_lcd_test_pattern.piano_note_index!==p[3:0] ||
                   dut.u_lcd_test_pattern.piano_note_pressed!==expected[p])
                    $fatal(1,"LCD piano key %0d disagrees with real held notes",p);
            end
        end
    endtask
    task clear_bank;begin
        @(negedge clk);flush=1;tick();
        if(dut.song_event_ready)$fatal(1,"flush accepted event");
        samples(1100);repeat(3)tick();
        if(dut.polyphony_active_voice_count || dut.audio_sample || dut.song_held_notes)
            $fatal(1,"flush retained voice/audio/keys");
        @(negedge clk);flush=0;repeat(3)tick();
    end endtask
    initial begin
        force dut.audio_sample_strobe=strobe;
        force dut.pixel_clk=pixel_clk;
        force dut.audition_mode=1'b1;force dut.audition_target=3'd7;
        force dut.setting_mode=1'b0;force dut.test_mode=1'b0;
        force dut.song_event_valid=valid;force dut.song_event_on=on;
        force dut.song_event_id=id;force dut.song_event_note=note;
        force dut.song_event_octave=2'd1;force dut.song_event_force=7'd96;
        force dut.song_event_flush=flush;
        force dut.lcd_frame_start=frame;force dut.lcd_active_x=x;force dut.lcd_active_y=y;
        repeat(25)tick();
        send(1,1,0);send(1,2,4);send(1,3,7);settle();display_mask(12'h091);
        send(0,3,0);display_mask(12'h011); // Last ON's OFF must not hide C/E.
        send(1,4,0);settle();send(0,1,0);display_mask(12'h011);
        send(0,4,0);display_mask(12'h010); // Same-pitch ownership OR, not toggle.
        send(1,2,11);settle();display_mask(12'h010); // Duplicate ID cannot relabel.
        send(1,5,12);settle();send(0,999,0);display_mask(12'h010);
        clear_bank();display_mask(0);

        // All 32 accepted/allocated before the next real sample boundary.
        while(divider!=10'd16)tick();start_clock=clocks;
        for(k=0;k<32;k=k+1)begin send(1,100+k,k%12);settle();end
        burst_clocks=clocks-start_clock;
        if(burst_clocks>=1008 || dut.polyphony_active_voice_count!=32)
            $fatal(1,"display throttles empty-bank 32-event burst: %0d clocks",burst_clocks);
        for(k=0;k<32;k=k+1)if(dut.u_polyphony_bank_32.envelope_gain[k]!=0)
            $fatal(1,"burst crossed sample boundary before all lanes were allocated");
        samples(1);repeat(2)tick();
        for(k=0;k<32;k=k+1)if(dut.u_polyphony_bank_32.envelope_gain[k]!=16)
            $fatal(1,"empty-bank simultaneous attack mismatch at lane %0d",k);
        display_mask(12'hfff);samples(256);
        // C is held by IDs 100,112,124. Only the last OFF unlights that key.
        send(0,100,0);send(0,112,0);display_mask(12'hfff);
        send(0,124,0);display_mask(12'hffe);
        clear_bank();display_mask(0);

        for(k=0;k<32;k=k+1)begin send(1,200+k,0);settle();end
        samples(256);display_mask(12'h001);
        send(1,300,7);settle();
        if(dut.u_polyphony_bank_32.held_notes_next!==12'h001)
            $fatal(1,"pending stolen pitch displayed before retune");
        samples(20);display_mask(12'h081);
        send(0,200,0);display_mask(12'h081); // Old victim OFF cannot clear G.
        send(0,300,0);display_mask(12'h001);
        clear_bank();display_mask(0);
        $display("PASS: real top 32-event burst=%0d clocks, common empty-bank attack boundary; triad/12 LCD keys, duplicate pitches/IDs, stale OFF, steal/flush, bundled CDC and frame atomicity; peak=%0d",burst_clocks,peak);
        $finish;
    end
    initial begin #120000000;$fatal(1,"polyphonic display timeout");end
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
