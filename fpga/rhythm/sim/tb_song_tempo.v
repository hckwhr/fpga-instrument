`timescale 1ns/1ps
module tb_song_tempo;
    `include "instrument_contract.vh"
    reg clk=0,strobe=0,s2=0;
    reg [2:0] keys=0;
    integer p,i,starts,last_start,quarter,span;
    av_top dut(.sys_clk(clk),.key0_n(1'b1),.key1_n(1'b1),.key2_n(1'b1),.setting_key(1'b0),
        .hc05_rx(1'b1),.hc05_tx(),.status_led(),.audio_bck(),.audio_ws(),.audio_din(),.audio_pa_en_n(),
        .lcd_pclk(),.lcd_hsync(),.lcd_vsync(),.lcd_de(),.lcd_bl(),.lcd_r(),.lcd_g(),.lcd_b());
    always #5 clk=~clk;
    task tick;begin @(posedge clk);#1;end endtask
    task slot;begin strobe=1;tick();strobe=0;repeat(11)tick();end endtask
    task press;input [2:0] k;begin
        @(negedge clk);keys=k;repeat(4)tick();@(negedge clk);keys=0;repeat(4)tick();end endtask
    task menu;begin
        @(negedge clk);s2=1;repeat(4)tick();@(negedge clk);s2=0;repeat(4)tick();end endtask
    initial begin
        force dut.audio_sample_strobe=strobe;
        force dut.key0_pressed=keys[0];force dut.key1_pressed=keys[1];force dut.key2_pressed=keys[2];
        force dut.setting_key_pressed=s2;
        repeat(20)tick();menu();press(4);repeat(7)press(1);repeat(7)press(2);
        // Prepare once; subsequent KEY2 presses cycle tempo without extra pages.
        press(4);
        if(dut.song_tempo!=1)$fatal(1,"prepare changed default tempo");
        for(p=0;p<4;p=p+1)begin
            if(p!=0)begin menu();repeat(7)press(1);press(4);press(4);end
            if(dut.song_tempo!=((p+1)%4))$fatal(1,"tempo cycle/retention");
            quarter=(p==0)?28800:(p==1)?24000:(p==2)?19200:36000;
            if(dut.status_payload_cdc_audio[ST_SONG_TEMPO+:2]!==dut.song_tempo)$fatal(1,"tempo snapshot");
            menu();
            if(p==0)press(1); // Ode includes dotted and eighth notes.
            starts=0;last_start=7199;span=7199+16*quarter;
            for(i=0;i<span;i=i+1)begin
                slot();
                if(dut.song_trigger)begin
                    if(i!=last_start || dut.polyphony_active_voice_count!=1)
                        $fatal(1,"tempo onset/release p=%0d note=%0d sample=%0d expected=%0d",p,starts,i,last_start);
                    last_start=last_start+((starts==12)?quarter+quarter/2:(starts==13)?quarter/2:(starts==14)?2*quarter:quarter);
                    starts=starts+1;
                end
                if(dut.audio_sample==32767 || dut.audio_sample==-32768)$fatal(1,"tempo PCM clips");
            end
            if(starts!=15 || !dut.song_select)$fatal(1,"tempo first phrase count");
        end
        $display("PASS: real menu 100/120/150/80 BPM, dotted/eighth timing, single allocated lane after old note release, no clipping");
        $finish;
    end
    initial begin #300000000;$fatal(1,"tempo timeout");end
endmodule
