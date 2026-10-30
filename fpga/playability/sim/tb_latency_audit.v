`timescale 1ns/1ps
module tb_latency_audit;
    reg clk=0, rst=0, armed=0;
    reg [2:0] keys_n=7;
    reg play=0, poly=0, strings=0, chord=0;
    reg [1:0] tone=3, octave=0, effect=0;
    wire bck,ws,din;
    integer cycles=0, last_strobe=0, start_cycle=0;
    integer pressed_at,trigger_at,raw_at,effect_at,left_at,right_at,level_at;
    integer triggers,bits=0,fd,cases=0,p,t,o,e,k,phase;
    integer phases[0:31];
    reg last_ws=1, have_left=0;
    reg [15:0] word=0,left_word=0;
    integer last_frame=-1,stereo_frames=0;
    av_top dut(.sys_clk(clk),.key0_n(keys_n[0]),.key1_n(keys_n[1]),.key2_n(keys_n[2]),
        .setting_key(1'b0),.hc05_rx(1'b1),.hc05_tx(),
        .audio_bck(bck),.audio_ws(ws),.audio_din(din),.status_led(),.audio_pa_en_n(),
        .lcd_pclk(),.lcd_hsync(),.lcd_vsync(),.lcd_de(),.lcd_bl(),.lcd_r(),.lcd_g(),.lcd_b());
    always #5 clk=~clk;
    always @(posedge clk) begin
        cycles=cycles+1;
        #1;
        if(dut.audio_sample_strobe) last_strobe=cycles;
        if(armed) begin
            if(pressed_at<0 && (dut.key0_pressed || dut.key1_pressed || dut.key2_pressed)) pressed_at=cycles;
            if(dut.key_play_trigger!=0) begin
                if(trigger_at<0) trigger_at=cycles;
                triggers=triggers+1;
            end
            if(raw_at<0 && dut.pre_effect_audio_sample!=0) raw_at=cycles;
            if(effect_at<0 && dut.audio_sample!=0) effect_at=cycles;
        end
    end
    // Complete left and right words, captured at the PT8211 falling BCK edge.
    always @(negedge bck or negedge rst) begin
        if(!rst) begin bits=0;last_ws=1;word=0;have_left=0;last_frame=-1;end
        else begin
            if(ws!=last_ws) begin bits=1;word={15'd0,din};last_ws=ws;end
            else begin bits=bits+1;word={word[14:0],din};end
            if(bits==16) begin
                if((^word)===1'bx) $fatal(1,"unknown serialized word");
                if(!ws) begin
                    left_word=word;have_left=1;
                    if(armed && word!=0 && left_at<0) left_at=cycles;
                    if(armed && level_at<0 && ($signed(word)>=33 || $signed(word)<=-33)) level_at=cycles;
                end else if(have_left) begin
                    if(word!==left_word) $fatal(1,"stereo mismatch");
                    if(last_frame>=0 && cycles-last_frame!=1024) $fatal(1,"sample period jitter");
                    last_frame=cycles;stereo_frames=stereo_frames+1;
                    if(armed && word!=0 && right_at<0) right_at=cycles;
                end
            end
        end
    end
    task tick;begin @(posedge clk);#2;end endtask
    task scenario;
        input integer group_id,path_id,phase_offset,timbre,oct,fx,key_mask,chord_map;
        begin
            @(negedge clk);armed=0;rst=0;keys_n=7;
            play=(path_id==0);poly=(path_id==2);strings=(path_id==3);
            tone=timbre;octave=oct;effect=fx;chord=chord_map;
            repeat(4)tick();@(negedge clk);rst=1;
            // 64 silent startup frames and 128-sample effect gain ramp settle.
            repeat(220000)tick();
            if(dut.u_audio_effects.level!=128 || dut.audio_sample!=0)
                $fatal(1,"unsettled startup");
            @(posedge dut.audio_sample_strobe);
            repeat(phase_offset)tick();@(negedge clk);
            start_cycle=cycles;
            if(cycles-last_strobe!=phase_offset) $fatal(1,"phase scheduling mismatch");
            pressed_at=-1;trigger_at=-1;raw_at=-1;effect_at=-1;
            left_at=-1;right_at=-1;level_at=-1;triggers=0;
            armed=1;keys_n=~key_mask;
            repeat(200000)tick();
            if(pressed_at-start_cycle!=49154 || trigger_at-pressed_at!=98305)
                $fatal(1,"debounce/guard contract changed pressed=%0d trigger=%0d",pressed_at-start_cycle,trigger_at-pressed_at);
            if(left_at<0 || right_at<0 || raw_at<0 || effect_at<0 || level_at<0)
                $fatal(1,"missing onset group=%0d path=%0d tone=%0d octave=%0d fx=%0d",group_id,path_id,timbre,oct,fx);
            if(right_at-start_cycle>245762) $fatal(1,"digital onset exceeded 5ms");
            if(triggers!=1) $fatal(1,"held key retrigger");
            if(dut.string_deadline_misses!=0 || dut.spectrum_deadline_misses!=0)
                $fatal(1,"audio/DFT deadline missed");
            $fwrite(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                cases,group_id,path_id,phase_offset,timbre,oct,fx,key_mask,chord_map,
                pressed_at-start_cycle,trigger_at-start_cycle,raw_at-start_cycle,
                effect_at-start_cycle,left_at-start_cycle,right_at-start_cycle,level_at-start_cycle);
            cases=cases+1;
            if(cases%32==0) $display("PROGRESS latency cases=%0d",cases);
            armed=0;
        end
    endtask
    initial begin
        force dut.audio_internal_reset_n=rst;
        // Menu-selected controls only. Keep the input synchronizers, debounce,
        // controller, synthesis, effects and serializer on their production path.
        force dut.play_mode=play;
        force dut.test_mode=poly;
        force dut.test_polyphony=1'b1;
        force dut.string_mode=strings;
        force dut.tone_select=tone;
        force dut.octave_select=octave;
        force dut.effect_select=effect;
        force dut.effect_strength=2'd2;
        force dut.note_select=4'd0;
        force dut.force_value=7'd96;
        force dut.keymap_select=chord;
        phases[0]=0;phases[1]=1;phases[2]=2;phases[3]=3;
        phases[4]=15;phases[5]=16;phases[6]=17;phases[7]=31;
        phases[8]=32;phases[9]=33;phases[10]=511;phases[11]=512;
        phases[12]=513;phases[13]=1021;phases[14]=1022;phases[15]=1023;
        for(k=16;k<32;k=k+1) phases[k]=(k-16)*64;
        fd=$fopen("latency.csv","w");if(!fd)$fatal(1,"open output");
        $fwrite(fd,"case,group,path,phase,tone,octave,effect,keys,chord,debounce,trigger,raw,effected,left,right,level33\n");
        for(p=0;p<4;p=p+1) for(k=0;k<32;k=k+1)
            scenario(0,p,phases[k],3,0,0,1,0);
        for(p=0;p<2;p=p+1) for(t=0;t<4;t=t+1) for(o=0;o<3;o=o+1) for(e=0;e<4;e=e+1)
            scenario(1,p,((t+o+e)%2)?0:1023,t,o,e,1<<((t+o+e)%3),0);
        for(t=0;t<4;t=t+1) for(o=0;o<3;o=o+1) for(k=0;k<2;k=k+1)
            scenario(2,2,k?1023:0,t,o,0,7,k);
        for(o=0;o<3;o=o+1) for(e=0;e<4;e=e+1)
            scenario(3,3,e%2?1023:0,3,o,e,7,0);
        // Repeated identical runs check determinism; phase scan checks variability.
        for(p=0;p<4;p=p+1) for(k=0;k<3;k=k+1)
            scenario(4,p,513,3,0,0,1,0);
        $fclose(fd);
        $display("PASS: %0d production top latency cases; %0d stereo frames; fixed debounce/guard; no retrigger/deadline miss",cases,stereo_frames);
        $finish;
    end
    initial begin #1600000000; $fatal(1,"timeout"); end
endmodule

// Logical clock models: convert measured audio-clock counts using production
// PLL ratio in analysis. No claim about analog PLL jitter or pixel rendering.
module audio_pll(input clkin,init_clk,output clkout0,lock);
    assign clkout0=clkin;
    assign lock=1'b1;
endmodule
module lcd_pll(input clkin,init_clk,output clkout0,lock);
    assign clkout0=1'b0;
    assign lock=1'b1;
endmodule
module ODDR(input D0,D1,TX,CLK,output Q0,Q1);
    assign Q0=CLK?D1:D0;
    assign Q1=TX;
endmodule
