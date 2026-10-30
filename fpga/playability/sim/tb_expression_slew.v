`timescale 1ns/1ps
// Virtual ADC/manual controls enter production av_top. Never force generated
// pitch, envelope, phase, sample enables or serial audio output.
module tb_expression_slew;
    reg clk=0,rst=0,sensors=0,frame=0,send_frames=0;
    reg [9:0] x=512,y=512;
    reg [1:0] manual=0,glide=0;
    reg [3:0] note=0;
    wire bck,ws,din;
    integer index=0,fd=0,cycles=0,bits=0,last_frame=-1,frames=0;
    integer previous_bend,previous_depth,delta,i,phase_checks=0;
    reg last_ws=1,have_left=0;
    reg [15:0] word=0,left_word=0;
    reg [31:0] expected_phase[0:3];
    real ratio0,ratio1,ratio2,ratio3,error;
    av_top dut(.sys_clk(clk),.key0_n(1'b1),.key1_n(1'b1),.key2_n(1'b1),.setting_key(1'b0),
        .hc05_rx(1'b1),.hc05_tx(),.status_led(),.audio_bck(bck),.audio_ws(ws),.audio_din(din),.audio_pa_en_n(),
        .lcd_pclk(),.lcd_hsync(),.lcd_vsync(),.lcd_de(),.lcd_bl(),.lcd_r(),.lcd_g(),.lcd_b());
    always #5 clk=~clk;
    always @(posedge clk)begin
        cycles=cycles+1;
        if(rst)begin
            previous_bend=$signed(dut.performance_bend);previous_depth=dut.performance_vibrato;
            if(dut.dds_sample_strobe && dut.legacy_voice.u_audio_voice_mixer.voice0_gain!=0 &&
               dut.legacy_voice.u_audio_voice_mixer.voice1_gain!=0 && dut.legacy_voice.u_audio_voice_mixer.voice2_gain!=0 &&
               dut.legacy_voice.u_audio_voice_mixer.voice3_gain!=0)begin
                expected_phase[0]=dut.legacy_voice.u_audio_voice_mixer.voice0_phase_accumulator+dut.legacy_voice.u_audio_voice_mixer.expression_increment[0];
                expected_phase[1]=dut.legacy_voice.u_audio_voice_mixer.voice1_phase_accumulator+dut.legacy_voice.u_audio_voice_mixer.expression_increment[1];
                expected_phase[2]=dut.legacy_voice.u_audio_voice_mixer.voice2_phase_accumulator+dut.legacy_voice.u_audio_voice_mixer.expression_increment[2];
                expected_phase[3]=dut.legacy_voice.u_audio_voice_mixer.voice3_phase_accumulator+dut.legacy_voice.u_audio_voice_mixer.expression_increment[3];
                #2;
                if({dut.legacy_voice.u_audio_voice_mixer.voice0_phase_accumulator,dut.legacy_voice.u_audio_voice_mixer.voice1_phase_accumulator,
                    dut.legacy_voice.u_audio_voice_mixer.voice2_phase_accumulator,dut.legacy_voice.u_audio_voice_mixer.voice3_phase_accumulator}!==
                   {expected_phase[0],expected_phase[1],expected_phase[2],expected_phase[3]})$fatal(1,"expression restarted oscillator phase");
                phase_checks=phase_checks+4;
            end else #2;
            delta=$signed(dut.performance_bend)-previous_bend;
            if(delta>1 || delta < -1)$fatal(1,"bend source switch jump=%0d",delta);
            delta=dut.performance_vibrato-previous_depth;
            if(delta>1 || delta < -1)$fatal(1,"vibrato source switch jump=%0d",delta);
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
                end
            end
        end
    end
    task stream;input integer n;integer k;begin
        for(k=0;k<n;k=k+1)begin
            @(posedge dut.audio_sample_strobe);@(negedge clk);
            if(send_frames && index%64==0)begin frame=1;@(negedge clk);frame=0;end
            // Let pitch multipliers settle before inspecting interval ratios.
            repeat(16)@(negedge clk);
            index=index+1;
            if(fd)$fwrite(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",index,
                dut.u_performance_controls.sensor_ready,$signed(dut.performance_bend),dut.performance_vibrato,
                dut.legacy_voice.u_audio_voice_mixer.expression_increment[0],dut.legacy_voice.u_audio_voice_mixer.expressions[0].pitch.unmodulated,$signed(left_word));
        end
    end endtask
    task endpoint;input integer b,d;begin
        if($signed(dut.performance_bend)!=b || dut.performance_vibrato!=d)
            $fatal(1,"endpoint expected %0d/%0d got %0d/%0d",b,d,$signed(dut.performance_bend),dut.performance_vibrato);
    end endtask
    task intervals;begin
        ratio0=$itor(dut.legacy_voice.u_audio_voice_mixer.expression_increment[0])/$itor(dut.legacy_voice.u_audio_voice_mixer.expressions[0].pitch.unmodulated);
        ratio1=$itor(dut.legacy_voice.u_audio_voice_mixer.expression_increment[1])/$itor(dut.legacy_voice.u_audio_voice_mixer.expressions[1].pitch.unmodulated);
        ratio2=$itor(dut.legacy_voice.u_audio_voice_mixer.expression_increment[2])/$itor(dut.legacy_voice.u_audio_voice_mixer.expressions[2].pitch.unmodulated);
        ratio3=$itor(dut.legacy_voice.u_audio_voice_mixer.expression_increment[3])/$itor(dut.legacy_voice.u_audio_voice_mixer.expressions[3].pitch.unmodulated);
        if(ratio0-ratio1>0.00001 || ratio0-ratio1 < -0.00001 ||
           ratio0-ratio2>0.00001 || ratio0-ratio2 < -0.00001 ||
           ratio0-ratio3>0.00001 || ratio0-ratio3 < -0.00001)
            $fatal(1,"shared expression changed chord intervals");
    end endtask
    initial begin
        force dut.audio_internal_reset_n=rst;
        force dut.test_mode=1'b0;force dut.string_mode=1'b0;force dut.song_active=1'b0;
        force dut.audition_active=1'b0;force dut.setting_mode=1'b0;force dut.key_play_mute=1'b0;
        force dut.play_mode=1'b0;force dut.keymap_select=1'b1;force dut.force_value=7'd96;
        force dut.tone_select=2'd3;force dut.octave_select=2'd1;force dut.note_select=note;
        force dut.vibrato_select=manual;force dut.glide_select=glide;
        force dut.key0_pressed=1'b1;force dut.key1_pressed=1'b0;force dut.key2_pressed=1'b0;
        force dut.active_effect_select=2'd0;
        force dut.u_performance_controls.sensor_enable=sensors;
        force dut.u_performance_controls.frame_valid=frame;
        force dut.u_performance_controls.force_raw=10'd800;
        force dut.u_performance_controls.x_raw=x;force dut.u_performance_controls.y_raw=y;
        repeat(8)@(negedge clk);rst=1;stream(300);
        fd=$fopen("sim/expression_slew.csv","w");if(!fd)$fatal(1,"capture open");
        $fwrite(fd,"sample,ready,bend,depth,increment,base,pcm\n");
        manual=3;stream(128);endpoint(0,128);intervals();
        manual=0;stream(128);endpoint(0,0);
        sensors=1;send_frames=1;x=1023;y=1023;stream(2000);endpoint(127,128);intervals();
        send_frames=0;stream(5200);endpoint(0,0);
        if(dut.u_performance_controls.sensor_ready)$fatal(1,"stale sensor still ready");
        send_frames=1;x=0;y=1023;stream(2000);endpoint(-128,128);intervals();
        sensors=0;send_frames=0;manual=1;stream(128);endpoint(0,32);
        for(i=0;i<100;i=i+1)begin manual=i%2?0:3;stream(1);end
        manual=0;stream(128);endpoint(0,0);
        // Existing glide still reaches the new chord without phase reset.
        glide=1;stream(2);note=5;stream(4200);intervals();
        if(dut.legacy_voice.u_audio_voice_mixer.expressions[0].pitch.glide_left!=0)$fatal(1,"glide not settled");
        if(dut.legacy_voice.u_audio_voice_mixer.expression_increment[0]!=dut.legacy_voice.u_audio_voice_mixer.voice0_phase_increment)$fatal(1,"glide missed endpoint");
        if(phase_checks<40000 || frames<10000)$fatal(1,"insufficient production coverage");
        if(dut.spectrum_deadline_misses!=0)$fatal(1,"DFT overrun");
        $fclose(fd);
        $display("PASS: manual depth on/off/chatter; virtual ADC endpoints/stale/recovery/disable; <=1 control step; %0d continuous four-lane phase checks; chord ratios; glide endpoint; %0d exact-cadence PT8211 stereo frames",phase_checks,frames);
        $finish;
    end
    initial begin #180000000;$fatal(1,"timeout");end
endmodule
