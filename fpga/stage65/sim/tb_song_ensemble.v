`timescale 1ns/1ps
// Full production score + controller + bank + effects. All event-bearing
// slots use the real 1024 clocks; only already-idle slots are shortened to 12.
// A separate initial passage uses 1024 unconditionally to check the contract.
module tb_song_ensemble;
    `include "instrument_contract.vh"
    reg clk=0,strobe=0,s2=0;
    reg [2:0] keys=0;
    integer i,j,p,fd,peak=0,mag,ons=0,offs=0,melody_ons=0;
    integer ticks=0,last_boundary=0,batch_start=0,max_batch=0;
    integer attack_groups=0,attack_lanes=0,max_voices=0,faults=0;
    integer starts_before,quarter,limit,ons_before,offs_before;
    reg slot_event=0;
    reg full_slots=0,check_attacks=1;
    reg [31:0] pending_lanes=0,attack_mask;
    reg [31:0] held_phase;
    wire [7:0] lead_row = dut.u_song_timeline.current_event[7:0];
    wire [7:0] twinkle_row = lead_row<42 ? lead_row : lead_row+8'd1;
    wire [3:0] expected_twinkle_note, expected_ode_note;
    song_score_twinkle reference_twinkle(.index(twinkle_row),.note(expected_twinkle_note),
        .duration_ticks(),.gate_ticks(),.octave(),.force_level(),.length());
    song_score_ode reference_ode(.index(lead_row),.note(expected_ode_note),
        .duration_ticks(),.gate_ticks(),.octave(),.force_level(),.length());
    av_top dut(.sys_clk(clk),.key0_n(1'b1),.key1_n(1'b1),.key2_n(1'b1),.setting_key(1'b0),
        .hc05_rx(1'b1),.hc05_tx(),.status_led(),.audio_bck(),.audio_ws(),.audio_din(),.audio_pa_en_n(),
        .lcd_pclk(),.lcd_hsync(),.lcd_vsync(),.lcd_de(),.lcd_bl(),.lcd_r(),.lcd_g(),.lcd_b());
    always #5 clk=~clk;
    task tick;begin @(posedge clk);#1;end endtask
    task slot;begin
        slot_event=0;
        strobe=1;tick();strobe=0;repeat(11)tick();
        if(full_slots || slot_event || dut.u_song_timeline.state==1 || dut.u_song_timeline.state==2 ||
           dut.u_song_timeline.state==4 || dut.u_song_timeline.state==5 || dut.song_event_valid)
            repeat(1012)tick();
        if((^dut.audio_sample)===1'bx)$fatal(1,"unknown ensemble PCM");
        mag=dut.audio_sample<0?-dut.audio_sample:dut.audio_sample;
        if(mag>=32767)$fatal(1,"ensemble clips");
        if(mag>peak)peak=mag;
        if(dut.polyphony_active_voice_count>max_voices)max_voices=dut.polyphony_active_voice_count;
        if(dut.polyphony_active_voice_count>9)$fatal(1,"score exceeded five held + four release tails");
    end endtask
    task press;input[2:0] k;begin
        @(negedge clk);keys=k;repeat(4)tick();@(negedge clk);keys=0;repeat(4)tick();
    end endtask
    task menu;begin @(negedge clk);s2=1;repeat(4)tick();@(negedge clk);s2=0;repeat(4)tick();end endtask
    always @(posedge clk) begin
        ticks=ticks+1;
        if(strobe)last_boundary=ticks;
        if(dut.ensemble_fault)faults=faults+1;
        if(dut.song_event_valid && dut.song_event_ready && dut.song_event_on)melody_ons=melody_ons+1;
        if(strobe && dut.u_song_timeline.state==3 && dut.u_song_timeline.music_boundary &&
           dut.u_song_timeline.group_tick==dut.u_song_timeline.due_tick)batch_start=ticks;
        if(dut.u_song_timeline.state==5 && dut.ensemble_ready)begin
            if(ticks-batch_start>max_batch)max_batch=ticks-batch_start;
            if(ticks-last_boundary>990)$fatal(1,"batch violates pipeline settling window");
        end
        if(dut.ensemble_valid && dut.ensemble_ready)begin
            slot_event=1;
            if(dut.ensemble_on && dut.ensemble_melody &&
               dut.ensemble_note !== (dut.song_select ? expected_ode_note : expected_twinkle_note))
                $fatal(1,"MIDI lead differs from verified solo melody at row %0d",lead_row);
            if(dut.ensemble_on)ons=ons+1;else offs=offs+1;
        end
        if(!dut.audio_internal_reset_n || dut.song_event_flush)pending_lanes=0;
        else if(check_attacks && dut.song_accompaniment)begin
            if(dut.u_polyphony_bank_32.allocate_voice)begin
                j=dut.u_polyphony_bank_32.search_index;
                if(dut.u_polyphony_bank_32.voice_active[j])$fatal(1,"bounded song unexpectedly steals a lane");
                pending_lanes[j]=1;
            end
            if(dut.poly_sample_strobe && pending_lanes!=0)begin
                attack_mask=pending_lanes;pending_lanes=0;attack_groups=attack_groups+1;
                for(j=0;j<32;j=j+1)if(attack_mask[j] && dut.u_polyphony_bank_32.envelope_gain[j]!=0)
                    $fatal(1,"a batch lane attacked before the common boundary");
                #1;
                for(j=0;j<32;j=j+1)if(attack_mask[j])begin
                    attack_lanes=attack_lanes+1;
                    if(dut.u_polyphony_bank_32.envelope_gain[j]!=16)
                        $fatal(1,"a batch lane missed the common boundary");
                end
            end
        end
    end
    initial begin
        force dut.audio_sample_strobe=strobe;
        force dut.key0_pressed=keys[0];force dut.key1_pressed=keys[1];force dut.key2_pressed=keys[2];
        force dut.setting_key_pressed=s2;
        repeat(20)tick();menu();press(4);repeat(7)press(1);repeat(7)press(2);press(4);menu();
        press(1);press(1);
        if(!dut.song_select || !dut.song_accompaniment)$fatal(1,"cannot select Ode ensemble");
        fd=$fopen("sim/song_ensemble.csv","w");if(!fd)$fatal(1,"capture failed");
        // Initial protection is empty: shorten it, then verify the onset and
        // first audible 512 samples with the actual 1024-clock spacing.
        for(i=0;i<936000;i=i+1)begin
            full_slots=(i>=7198 && i<7712);
            slot();$fwrite(fd,"%0d\n",dut.audio_sample);
            if(i==7600 && (dut.polyphony_active_voice_count!=5 || dut.song_held_notes!=12'h091))
                $fatal(1,"first melody/bass/triad or actual keyboard mask wrong");
        end
        $fclose(fd);full_slots=0;
        if(melody_ons!=30 || ons!=66 || offs!=66 || attack_lanes!=66 || attack_groups!=30 ||
           faults!=0 || max_batch>=500 || max_voices!=9 || peak<3000 ||
           !dut.song_done || dut.audio_sample!=0 || dut.polyphony_active_voice_count!=0)
            $fatal(1,"incomplete arrangement melody=%0d on/off=%0d/%0d attacks=%0d/%0d faults=%0d batch=%0d peak=%0d voices=%0d",
                melody_ons,ons,offs,attack_lanes,attack_groups,faults,max_batch,peak,max_voices);
        $display("ENSEMBLE full score: melody=30 harmony=36 peak=%0d maximum active=%0d maximum batch=%0d clocks",peak,max_voices,max_batch);
        // Second arranged song uses exactly the same scheduler, with a silent
        // two-beat gap and independent OFF timestamps (no melody-row adapter).
        press(1);ons_before=ons;offs_before=offs;starts_before=melody_ons;
        if(dut.song_select || !dut.song_accompaniment || dut.song_score_length!=84)
            $fatal(1,"cannot select data-driven Twinkle accompaniment");
        fd=$fopen("sim/song_twinkle_ensemble.csv","w");if(!fd)$fatal(1,"capture failed");
        for(i=0;i<2840000;i=i+1)begin
            slot();$fwrite(fd,"%0d\n",dut.audio_sample);
            if(i==1410000 && (dut.audio_sample!=0 || dut.polyphony_active_voice_count!=0))
                $fatal(1,"inter-verse rest contains audio");
        end
        $fclose(fd);
        if(ons-ons_before!=180 || offs-offs_before!=180 || melody_ons-starts_before!=84 ||
           !dut.song_done || faults!=0 || dut.audio_sample!=0 || dut.polyphony_active_voice_count!=0)
            $fatal(1,"Twinkle arrangement incomplete on/off=%0d/%0d lead=%0d",ons-ons_before,offs-offs_before,melody_ons-starts_before);
        $display("TWINKLE full score: melody=84 harmony=96 with inter-verse silence");
        press(1);press(1);press(1); // Twinkle solo -> Ode solo -> Ode accompaniment.
        // Replay, local stop priority and held selection; the whole group must release.
        press(4);repeat(7600)slot();press(3);repeat(1500)slot();
        if(!dut.song_done || !dut.song_accompaniment || dut.audio_sample!=0 || dut.polyphony_active_voice_count!=0)
            $fatal(1,"STOP did not beat change/release all lanes");
        press(4);repeat(7600)slot();menu();repeat(400)slot();
        if(dut.song_active || dut.audio_sample!=0)$fatal(1,"S2 left ensemble audio");
        // Four tempo settings through real menu; first bar transition contains
        // both old OFFs and new ONs and must preserve a five-note held set.
        for(p=0;p<4;p=p+1)begin
            if(p!=0)menu();repeat(7)press(1);press(4);press(4);
            quarter=(dut.song_tempo==0)?36000:(dut.song_tempo==1)?28800:(dut.song_tempo==2)?24000:19200;
            menu();starts_before=melody_ons;limit=7200+4*quarter+100;
            repeat(limit)slot();
            if(melody_ons-starts_before!=5 || dut.song_note_index!=4 || faults!=0)
                $fatal(1,"tempo changed score timeline/batch completion");
            press(2);repeat(1500)slot();
            if(dut.audio_sample || dut.polyphony_active_voice_count)$fatal(1,"tempo stop left notes");
        end
        // Deliberate backpressure past the deadline must stop, not partially
        // sound a batch at a later boundary. This is not a success-path sample.
        check_attacks=0;press(4);repeat(7199)slot();
        force dut.song_bank_ready=1'b0;full_slots=1;repeat(3)slot();
        release dut.song_bank_ready;full_slots=0;repeat(1500)slot();
        if(faults==0 || !dut.song_done || dut.audio_sample || dut.polyphony_active_voice_count)
            $fatal(1,"missed deadline failed to cancel performance");
        press(4);repeat(7600)slot();
        if(dut.song_done || dut.polyphony_active_voice_count!=5)$fatal(1,"fault recovery replay failed");
        // Exit accompanied Ode, then return to solo Ode through the same KEY0.
        @(negedge clk);keys=1;repeat(8)tick();repeat(50)slot();
        if(dut.song_select || !dut.song_accompaniment)$fatal(1,"held selection repeated");
        @(negedge clk);keys=0;repeat(4)tick();press(1);press(1);repeat(7600)slot();
        if(!dut.song_select || dut.song_accompaniment || dut.polyphony_active_voice_count!=1)
            $fatal(1,"solo/ensemble ownership switch leaked notes");
        $display("PASS: full Ode/Twinkle MIDI arrangements, common attack boundaries, independent OFFs/rests, bounded allocation, no clipping, four tempi, STOP/replay/S2, mode cycle and deadline fault cancellation");
        $finish;
    end
    initial begin #1000000000;$fatal(1,"ensemble timeout");end
endmodule
