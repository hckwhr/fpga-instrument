`timescale 1ns/1ps
// Real controller, song source, 32-lane event bank, effects and LCD snapshot.
// PLLs use existing mocks. Only sample spacing is compressed to 12 clocks;
// the number of 48-kHz audio samples and all musical durations stay real.
module tb_song_top;
    reg clk=0, strobe=0, s2=0;
    reg [2:0] keys=0;
    integer i, fd, starts=0, peak=0, mag, nonzero=0;
    reg previous_gate=0;
    av_top dut(.sys_clk(clk),.key0_n(1'b1),.key1_n(1'b1),.key2_n(1'b1),.setting_key(1'b0),
        .hc05_rx(1'b1),.hc05_tx(),
        .status_led(),.audio_bck(),.audio_ws(),.audio_din(),.audio_pa_en_n(),
        .lcd_pclk(),.lcd_hsync(),.lcd_vsync(),.lcd_de(),.lcd_bl(),.lcd_r(),.lcd_g(),.lcd_b());
    always #5 clk=~clk;
    task tick;begin @(posedge clk);#1;end endtask
    task slot;begin strobe=1;tick();strobe=0;repeat(11)tick();end endtask
    task press;input [2:0] k;
        begin @(negedge clk);keys=k;repeat(4)tick();@(negedge clk);keys=0;repeat(4)tick();end
    endtask
    task menu_key;begin @(negedge clk);s2=1;repeat(4)tick();@(negedge clk);s2=0;repeat(4)tick();end endtask
    initial begin
        force dut.audio_sample_strobe=strobe;
        force dut.key0_pressed=keys[0]; force dut.key1_pressed=keys[1]; force dut.key2_pressed=keys[2];
        force dut.setting_key_pressed=s2;
        repeat(20)tick();
        menu_key(); press(4); repeat(7)press(1); repeat(7)press(2);
        if(!dut.setting_mode || !dut.settings_page || dut.selected_field!=6 || dut.audition_target!=7)
            $fatal(1,"cannot select song from extension menu");
        press(4);
        if(!dut.audition_mode || dut.string_mode || dut.test_mode) $fatal(1,"song prepare source ownership");
        menu_key();
        if(!dut.song_active || !dut.u_polyphony_bank_32.event_mode || dut.active_effect_select!=0 || dut.routed_tone!=3)
            $fatal(1,"song cannot reach production piano output");
        fd=$fopen("sim/song_twinkle.csv","w");
        if(fd==0) $fatal(1,"cannot capture PCM");
        for(i=0;i<2840000;i=i+1) begin
            slot();
            if((^dut.audio_sample)===1'bx) $fatal(1,"unknown PCM");
            mag=dut.audio_sample<0?-dut.audio_sample:dut.audio_sample;
            if(mag>peak) peak=mag;
            if(mag>0)nonzero=nonzero+1;
            if(mag>=32767)$fatal(1,"song PCM clips");
            if(dut.song_trigger)begin
                starts=starts+1;
                if(previous_gate)$fatal(1,"repeated note did not release");
                if(dut.polyphony_active_voice_count!=1)$fatal(1,"score must allocate one lane after old note releases");
                if(dut.displayed_status_payload[16:13]!==dut.song_note || dut.displayed_status_payload[2:0]!=1)
                    $fatal(1,"LCD pitch/key snapshot differs from song");
                $display("SONG note=%0d pitch_class=%0d sample=%0d",starts,dut.song_note,i);
            end
            previous_gate=dut.song_gate;
            if(dut.song_note_index==42 && (dut.song_gate || dut.song_trigger || dut.audio_sample!=0))
                $fatal(1,"explicit rest was not silent");
            $fwrite(fd,"%0d\n",dut.audio_sample);
        end
        $fclose(fd);
        if(starts!=84 || !dut.song_done || dut.song_gate || dut.audio_sample!=0 || nonzero<500000 || peak<200)
            $fatal(1,"song incomplete/silent/hanging: notes=%0d peak=%0d nonzero=%0d",starts,peak,nonzero);
        press(4); repeat(7500)slot();
        if(dut.song_done || !dut.song_gate || dut.song_note_index!=0) $fatal(1,"KEY2 replay failed");
        press(2); repeat(11000)slot();
        if(!dut.song_done || dut.song_gate || dut.audio_sample!=0) $fatal(1,"KEY1 stop failed to release");
        press(4); repeat(7500)slot(); menu_key(); repeat(400)slot();
        if(dut.song_active || dut.audition_mode || dut.audio_sample!=0) $fatal(1,"S2 did not stop song");
        $display("PASS: full 58.8-second, 85-row score with rest through production event bank/piano/effects and LCD payload, peak=%0d; KEY1 stop, KEY2 replay, S2 exit",peak);
        $finish;
    end
    initial begin #400000000; $fatal(1,"song top timeout"); end
endmodule
