`timescale 1ns/1ps
module tb_poly_expression_top;
    reg clk=0,rst=0,sensors=0,frame=0,send_frames=0;
    reg [9:0] x=512,y=512;
    reg [1:0] manual=0,octave=0;
    reg [3:0] note=0;
    reg [2:0] trigger=0,gate=1;
    wire bck,ws,din;
    integer i,index=0,cycles=0,bits=0,last_frame=-1,frames=0,checks=0,nonzero=0;
    integer fd=0,k,old_bend,old_depth,delta,peak=0;
    reg last_ws=1,have_left=0;
    reg [15:0] word=0,left_word=0;
    reg [31:0] expected[0:31],check_lanes;
    av_top dut(.sys_clk(clk),.key0_n(1'b1),.key1_n(1'b1),.key2_n(1'b1),.setting_key(1'b0),
        .hc05_rx(1'b1),.hc05_tx(),.status_led(),.audio_bck(bck),.audio_ws(ws),.audio_din(din),.audio_pa_en_n(),
        .lcd_pclk(),.lcd_hsync(),.lcd_vsync(),.lcd_de(),.lcd_bl(),.lcd_r(),.lcd_g(),.lcd_b());
    always #5 clk=~clk;
    always @(posedge clk)begin
        cycles=cycles+1;
        if(rst)begin
            old_bend=$signed(dut.poly_bend);old_depth=dut.poly_vibrato;
            check_lanes=0;
            if(dut.poly_sample_strobe)for(k=0;k<32;k=k+1)begin
                check_lanes[k]=dut.u_polyphony_bank_32.voice_active[k] &&
                    !dut.u_polyphony_bank_32.voice_stealing[k] &&
                    !(dut.u_polyphony_bank_32.allocate_voice && dut.u_polyphony_bank_32.search_index==k);
                expected[k]=dut.u_polyphony_bank_32.phase_accumulator[k]+dut.u_polyphony_bank_32.expressed_increment[k];
            end
            #2;
            for(k=0;k<32;k=k+1)if(check_lanes[k])begin
                if(dut.u_polyphony_bank_32.phase_accumulator[k]!==expected[k])$fatal(1,"top phase discontinuity");
                checks=checks+1;
            end
            delta=$signed(dut.poly_bend)-old_bend;if(delta>1 || delta < -1)$fatal(1,"top bend jump");
            delta=dut.poly_vibrato-old_depth;if(delta>1 || delta < -1)$fatal(1,"top depth jump");
        end
    end
    always @(negedge bck or negedge rst)begin
        if(!rst)begin bits=0;last_ws=1;have_left=0;last_frame=-1;end
        else begin
            if(ws!=last_ws)begin bits=1;word={15'd0,din};last_ws=ws;end
            else begin bits=bits+1;word={word[14:0],din};end
            if(bits==16)begin
                if((^word)===1'bx || word==16'h7fff || word==16'h8000)$fatal(1,"invalid DAC word");
                if(!ws)begin left_word=word;have_left=1;end
                else if(have_left)begin
                    if(word!==left_word)$fatal(1,"stereo mismatch");
                    if(last_frame>=0 && cycles-last_frame!=1024)$fatal(1,"DAC cadence");
                    last_frame=cycles;frames=frames+1;
                    if(word!=0)nonzero=nonzero+1;
                    if($signed(word)>peak)peak=$signed(word);if(-$signed(word)>peak)peak=-$signed(word);
                end
            end
        end
    end
    task stream;input integer n;integer t;begin
        for(t=0;t<n;t=t+1)begin
            @(posedge dut.audio_sample_strobe);@(negedge clk);
            if(send_frames && index%64==0)begin frame=1;@(negedge clk);frame=0;end
            repeat(24)@(negedge clk);index=index+1;
            if(fd)$fwrite(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",index,
                dut.u_performance_controls.sensor_ready,$signed(dut.poly_bend),dut.poly_vibrato,
                dut.u_polyphony_bank_32.expression_ratio,dut.u_polyphony_bank_32.expressed_increment[0],
                dut.polyphony_active_voice_count,$signed(left_word));
        end
    end endtask
    task endpoint;input integer b,d;begin
        if($signed(dut.poly_bend)!=b || dut.poly_vibrato!=d)$fatal(1,"top controls did not arrive");
        if(dut.polyphony_active_voice_count!=32)$fatal(1,"expression lost lanes");
    end endtask
    initial begin
        force dut.audio_internal_reset_n=rst;
        force dut.test_mode=1'b1;force dut.test_polyphony=1'b1;
        force dut.string_mode=1'b0;force dut.song_active=1'b0;force dut.audition_active=1'b0;
        force dut.setting_mode=1'b0;force dut.key_play_mute=1'b0;
        force dut.play_mode=1'b0;force dut.keymap_select=1'b0;force dut.force_value=7'd96;
        force dut.tone_select=2'd3;force dut.octave_select=octave;force dut.note_select=note;
        force dut.vibrato_select=manual;force dut.key_play_trigger=trigger;
        force dut.key0_pressed=gate[0];force dut.key1_pressed=gate[1];force dut.key2_pressed=gate[2];
        force dut.u_performance_controls.sensor_enable=sensors;
        force dut.u_performance_controls.frame_valid=frame;
        force dut.u_performance_controls.force_raw=10'd800;
        force dut.u_performance_controls.x_raw=x;force dut.u_performance_controls.y_raw=y;
        repeat(8)@(negedge clk);rst=1;stream(4);
        for(i=0;i<32;i=i+1)begin note=i%12;octave=i/12;trigger=1;stream(1);trigger=0;stream(1);end
        stream(4000);endpoint(0,0);
        fd=$fopen("sim/poly_expression_top.csv","w");if(!fd)$fatal(1,"capture open");
        $fwrite(fd,"sample,ready,bend,depth,ratio,step0,count,pcm\n");
        manual=3;stream(128);endpoint(0,128);
        manual=0;stream(128);endpoint(0,0);
        sensors=1;send_frames=1;x=1023;y=1023;stream(2000);endpoint(127,128);
        send_frames=0;stream(5200);endpoint(0,0);
        send_frames=1;x=0;y=1023;stream(2000);endpoint(-128,128);
        sensors=0;send_frames=0;manual=1;stream(128);endpoint(0,32);
        manual=0;stream(128);endpoint(0,0);
        $fclose(fd);fd=0;
        gate=0;stream(30000);
        if(dut.polyphony_active_voice_count!=0 || left_word!=0)$fatal(1,"top release not silent");
        if(dut.spectrum_deadline_misses!=0)$fatal(1,"DFT overrun");
        if(checks<500000 || frames<40000 || nonzero<5000)$fatal(1,"insufficient top coverage");
        $display("PASS: production controls/manual depth/virtual ADC timeout/recovery/disable; 32 live lanes; %0d phase checks; %0d stereo frames; %0d nonzero; peak=%0d; no DFT overrun",checks,frames,nonzero,peak);
        $finish;
    end
    initial begin #500000000;$fatal(1,"timeout");end
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
