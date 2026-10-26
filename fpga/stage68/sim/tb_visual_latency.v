`timescale 1ns/1ps
module tb_visual_latency;
    reg clk=0,key_n=1,rst=0;
    reg play=1,poly=0,strings=0;
    wire bck,ws,din;
    integer cycles=0,start_cycle,onset_cycle,trigger_cycle,triggers=0;
    integer i,j,bits=0,fd,min_latency=999999,max_latency=0;
    reg last_ws=1;
    reg [15:0] word=0;
    av_top dut(.sys_clk(clk),.key0_n(key_n),.key1_n(1'b1),.key2_n(1'b1),.setting_key(1'b0),
        .hc05_rx(1'b1),.hc05_tx(),
        .audio_bck(bck),.audio_ws(ws),.audio_din(din),.status_led(),.audio_pa_en_n(),
        .lcd_pclk(),.lcd_hsync(),.lcd_vsync(),.lcd_de(),.lcd_bl(),.lcd_r(),.lcd_g(),.lcd_b());
    always #5 clk=~clk;
    always @(posedge clk)begin
        cycles=cycles+1;
        #1;
        if(rst && dut.key_play_trigger!=0)begin triggers=triggers+1;trigger_cycle=cycles;end
    end
    // Decode actual serialized PT8211 left words at the DAC sampling edge.
    always @(negedge bck or negedge rst)begin
        if(!rst)begin bits=0;last_ws=1;word=0;end
        else begin
            if(ws!=last_ws)begin bits=1;word={15'd0,din};last_ws=ws;end
            else begin bits=bits+1;word={word[14:0],din};end
            if(bits==16 && ws==0 && word!=0 && onset_cycle<0)onset_cycle=cycles;
        end
    end
    task tick;begin @(posedge clk);#2;end endtask
    initial begin
        fd=$fopen("sim/visual_latency.csv","w");
        if(!fd)$fatal(1,"latency output open failed");
        force dut.audio_internal_reset_n=rst;
        force dut.play_mode=play;
        force dut.test_mode=poly;
        force dut.test_polyphony=1'b1;
        force dut.string_mode=strings;
        for(i=0;i<4;i=i+1)for(j=0;j<3;j=j+1)begin
            rst=0;key_n=1;repeat(4)tick();
            play=(i!=1);poly=(i==2);strings=(i==3);
            onset_cycle=-1;trigger_cycle=-1;triggers=0;rst=1;
            repeat(70000+j*311)tick();
            // Short interference pulse must not cause a note.
            key_n=0;repeat(10000)tick();key_n=1;repeat(50000)tick();
            if(onset_cycle>=0 || triggers!=0)$fatal(1,"short key glitch passed debounce path=%0d phase=%0d onset=%0d triggers=%0d pressed=%b sample=%d",i,j,onset_cycle,triggers,dut.key0_pressed,dut.audio_sample);
            @(negedge clk);key_n=0;start_cycle=cycles;
            repeat(220000)tick();
            if(onset_cycle<0 || onset_cycle-start_cycle>245762)$fatal(1,"latency exceeded 5ms or no DAC audio");
            if(triggers!=1)$fatal(1,"held key retriggered");
            if(dut.spectrum_deadline_misses!=0)$fatal(1,"production spectrum overrun");
            if(onset_cycle-start_cycle<min_latency)min_latency=onset_cycle-start_cycle;
            if(onset_cycle-start_cycle>max_latency)max_latency=onset_cycle-start_cycle;
            $fwrite(fd,"%0d,%0d,%0d,%0d\n",i,j,trigger_cycle-start_cycle,onset_cycle-start_cycle);
            $display("LATENCY path=%0d phase=%0d trigger=%0d DAC=%0d clocks",i,j,trigger_cycle-start_cycle,onset_cycle-start_cycle);
        end
        $fclose(fd);
        $display("PASS: actual debounce/controller/synth/effect/PT8211 path, 12 phase cases, no short-glitch/held-key retrigger, DFT no overrun; DAC=%0d..%0d clocks",min_latency,max_latency);
        $finish;
    end
endmodule
