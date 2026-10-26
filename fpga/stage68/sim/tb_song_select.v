`timescale 1ns/1ps
module tb_song_select;
    `include "instrument_contract.vh"
    reg clk=0, strobe=0, s2=0;
    reg [2:0] keys=0;
    integer i, fd, starts=0, offs=0, due=7199, peak=0, mag, nonzero=0;
    reg previous_gate=0;
    reg [3:0] notes[0:29];
    av_top dut(.sys_clk(clk),.key0_n(1'b1),.key1_n(1'b1),.key2_n(1'b1),.setting_key(1'b0),
        .hc05_rx(1'b1),.hc05_tx(),.status_led(),.audio_bck(),.audio_ws(),.audio_din(),.audio_pa_en_n(),
        .lcd_pclk(),.lcd_hsync(),.lcd_vsync(),.lcd_de(),.lcd_bl(),.lcd_r(),.lcd_g(),.lcd_b());
    always #5 clk=~clk;
    task tick;begin @(posedge clk);#1;end endtask
    task slot;begin strobe=1;tick();strobe=0;repeat(11)tick();end endtask
    task press;input [2:0] k;
        begin @(negedge clk);keys=k;repeat(4)tick();@(negedge clk);keys=0;repeat(4)tick();end
    endtask
    task menu_key;begin @(negedge clk);s2=1;repeat(4)tick();@(negedge clk);s2=0;repeat(4)tick();end endtask
    always @(posedge clk) if(dut.audio_internal_reset_n && dut.song_event_valid &&
        dut.song_event_ready && !dut.song_event_flush && !dut.song_event_on) offs=offs+1;
    initial begin
        {notes[0],notes[1],notes[2],notes[3],notes[4],notes[5],notes[6],notes[7],notes[8],notes[9],notes[10],notes[11],notes[12],notes[13],notes[14]}=60'h445775420024422;
        {notes[15],notes[16],notes[17],notes[18],notes[19],notes[20],notes[21],notes[22],notes[23],notes[24],notes[25],notes[26],notes[27],notes[28],notes[29]}=60'h445775420024200;
        force dut.audio_sample_strobe=strobe;
        force dut.key0_pressed=keys[0];force dut.key1_pressed=keys[1];force dut.key2_pressed=keys[2];
        force dut.setting_key_pressed=s2;
        repeat(20)tick();
        press(1); if(dut.song_select) $fatal(1,"manual KEY0 selected a song");
        menu_key();press(4);repeat(7)press(1);repeat(7)press(2);press(4);menu_key();
        repeat(9000)slot();
        if(!dut.song_gate || dut.song_select || dut.polyphony_active_voice_count!=1)
            $fatal(1,"Twinkle switching precondition");
        press(1);
        if(!dut.song_select || dut.song_gate || dut.song_trigger || dut.song_note_index!=0 ||
            !dut.status_payload_cdc_audio[ST_SONG_SELECT]) $fatal(1,"selection did not flush/update status");
        fd=$fopen("sim/song_ode.csv","w"); if(!fd) $fatal(1,"capture failed");
        for(i=0;i<936000;i=i+1) begin
            slot();
            if((^dut.audio_sample)===1'bx) $fatal(1,"unknown PCM");
            mag=dut.audio_sample<0?-dut.audio_sample:dut.audio_sample;
            if(mag>peak)peak=mag;
            if(mag>0)nonzero=nonzero+1;
            if(mag>=32767)$fatal(1,"Ode PCM clips");
            if(dut.song_trigger)begin
                if(starts>=30)$fatal(1,"Ode looped");
                if(i!=due || dut.song_note!==notes[starts] || dut.song_note_index!=starts)
                    $fatal(1,"Ode row %0d pitch/time mismatch at %0d expected %0d",starts,i,due);
                if(previous_gate || dut.polyphony_active_voice_count!=1)
                    $fatal(1,"pitch switched before old envelope released");
                if(dut.displayed_status_payload[ST_NOTE+:4]!==notes[starts]) $fatal(1,"LCD pitch mismatch");
                due=due+((starts==12 || starts==27)?43200:(starts==13 || starts==28)?14400:
                         (starts==14 || starts==29)?57600:28800);
                starts=starts+1;
            end
            previous_gate=dut.song_gate;
            $fwrite(fd,"%0d\n",dut.audio_sample);
        end
        $fclose(fd);
        if(starts!=30 || offs!=30 || due!=928799 || !dut.song_done || dut.song_gate ||
           dut.audio_sample!=0 || peak<200 || nonzero<300000)$fatal(1,"Ode incomplete or silent");
        // KEY2 keeps the selected song, KEY1 beats a simultaneous KEY0.
        press(4);repeat(9000)slot();
        if(!dut.song_select || dut.song_note!=4 || !dut.song_gate)$fatal(1,"Ode replay failed");
        press(3);repeat(11000)slot();
        if(!dut.song_select || !dut.song_done || dut.audio_sample!=0)$fatal(1,"stop priority failed");
        // A held KEY0 selects once; switching while stopped starts the next song.
        press(1);press(1); // Ode ensemble, Twinkle ensemble; next returns to solo.
        @(negedge clk);keys=1;repeat(4)tick();repeat(9000)slot();
        if(dut.song_select || dut.song_done || dut.song_note!=0 || !dut.song_gate)$fatal(1,"held selection repeated");
        @(negedge clk);keys=0;repeat(4)tick();
        // Repeated selections during release cancel stale starts.
        press(1);repeat(200)slot();press(1);repeat(200)slot();press(1);repeat(200)slot();press(1);repeat(200)slot();press(1);repeat(7500)slot();
        if(!dut.song_select || dut.song_note!=4 || !dut.song_gate)$fatal(1,"rapid switches leaked old start");
        // S2 wins over KEY0, and the chosen song is retained in the menu.
        @(negedge clk);keys=1;s2=1;repeat(4)tick();@(negedge clk);keys=0;s2=0;
        repeat(400)slot();
        if(!dut.setting_mode || dut.song_active || !dut.song_select || dut.audio_sample!=0 ||
           dut.status_payload_cdc_audio[ST_GLIDE+:2]!==dut.glide_select ||
           dut.status_payload_cdc_audio[ST_VIBRATO+:2]!==dut.vibrato_select ||
           dut.status_payload_cdc_audio[ST_DEADLINES+:8]!==dut.string_deadline_misses)
            $fatal(1,"S2 exit/selection retention or string counter failed");
        // On the tabs the packed slot now shows expressions. Song metadata
        // is restored when the score row owns focus; song selection persists.
        repeat(7)press(1);
        if(!dut.song_menu_context || !dut.status_payload_cdc_audio[ST_SONG_SELECT])
            $fatal(1,"Score row failed to restore retained song metadata");
        press(4);menu_key();repeat(7500)slot();
        if(!dut.song_select || !dut.song_gate || dut.song_note!=4)$fatal(1,"reentry lost selected song");
        $display("PASS: complete 30-note/32-beat Ode PCM, peak=%0d; active/stopped/held/rapid selection, replay, STOP/S2 priority, LCD and menu retention",peak);
        $finish;
    end
    initial begin #180000000;$fatal(1,"song selection timeout");end
endmodule
