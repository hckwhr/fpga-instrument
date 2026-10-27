`timescale 1ns/1ps
module tb_hc05_top;
    reg clk=0,rx=1,s2=0;
    reg [2:0] keys=0;
    reg [3:0] divider=0;
    wire strobe=(divider==0);
    integer i,nonzero=0;
    av_top #(.HC05_CLKS_PER_BIT(16)) dut (
        .sys_clk(clk),.key0_n(1'b1),.key1_n(1'b1),.key2_n(1'b1),.setting_key(1'b0),
        .hc05_rx(rx),.hc05_tx(),.status_led(),.audio_bck(),.audio_ws(),.audio_din(),.audio_pa_en_n(),
        .lcd_pclk(),.lcd_hsync(),.lcd_vsync(),.lcd_de(),.lcd_bl(),.lcd_r(),.lcd_g(),.lcd_b());
    always #5 clk=~clk;
    always @(negedge clk) divider <= divider==11 ? 0 : divider+1'b1;
    task tick; begin @(posedge clk); #1; end endtask
    task send(input string command);
        integer k,b; begin
            for(k=0;k<command.len();k=k+1) begin
                @(negedge clk); rx=0; #160;
                for(b=0;b<8;b=b+1) begin rx=(command[k]>>b)&1; #160; end
                rx=1; #160;
            end
            repeat(8000)tick();
        end
    endtask
    task key(input [2:0] value);
        begin @(negedge clk); keys=value; repeat(5)tick(); @(negedge clk);keys=0;repeat(5)tick();end
    endtask
    initial begin
        force dut.audio_sample_strobe=strobe;
        force dut.key0_pressed=keys[0];force dut.key1_pressed=keys[1];force dut.key2_pressed=keys[2];
        force dut.setting_key_pressed=s2;
        repeat(25)tick();
        send("PLAY\n");
        if(!dut.song_active || dut.routed_tone!=3 || dut.routed_play_mode || dut.active_effect_select!=0)
            $fatal(1,"remote PLAY not routed through piano preset");
        repeat(100000)begin tick();if(dut.audio_sample!=0)nonzero=nonzero+1;end
        if(!dut.song_gate || nonzero<1000 || dut.displayed_status_payload[2:0]!=1)
            $fatal(1,"remote song silent or LCD key missing");
        send("PLAY\n");
        if(dut.u_song_player.launch_pending)$fatal(1,"duplicate PLAY reset the song");
        send("STOP\n");repeat(120000)tick();
        if(!dut.song_done || dut.song_gate || dut.audio_sample!=0)$fatal(1,"remote STOP left sound hanging");
        send("PLAY\n");repeat(100000)tick();
        if(!dut.song_gate || dut.song_note_index!=0)$fatal(1,"remote restart failed");
        @(negedge clk);keys=4;repeat(100000)tick();
        send("STOP\n");repeat(120000)tick();
        send("PLAY\n");repeat(100000)tick();
        if(!dut.song_gate || dut.song_done)$fatal(1,"held KEY2 swallowed remote restart");
        @(negedge clk);keys=0;repeat(5)tick();
        key(2);repeat(120000)tick();
        if(!dut.song_done || dut.audio_sample!=0)$fatal(1,"local KEY1 stop lost");
        send("PLAY\n");repeat(100000)tick();
        @(negedge clk);s2=1;repeat(5)tick();@(negedge clk);s2=0;repeat(5000)tick();
        if(!dut.setting_mode || dut.song_active || dut.audio_sample!=0)$fatal(1,"local S2 exit lost");
        send("PLAY\n");
        if(dut.song_active || !dut.setting_mode)$fatal(1,"remote PLAY overrode menu");
        $display("PASS: real UART remote PLAY/STOP/restart, production piano PCM and LCD, local KEY1/S2 priority");
        $finish;
    end
    initial begin #15000000;$fatal(1,"HC05 top timeout");end
endmodule
