`timescale 1ns/1ps
module tb_poly_force_top;
    reg clk=0,rst=0,sensors=0,frame=0,send_frames=0;
    reg [9:0] raw=0;
    reg [2:0] triggers=0,gates=1;
    wire bck,ws,din;
    integer i,fd,index=0,bits=0,frames=0,last_frame=-1,cycles=0,delta;
    integer before_target,before_gain;
    reg last_ws=1,have_left=0;
    reg [15:0] word=0,left_word=0;
    av_top dut(.sys_clk(clk),.key0_n(1'b1),.key1_n(1'b1),.key2_n(1'b1),.setting_key(1'b0),
        .hc05_rx(1'b1),.hc05_tx(),.status_led(),.audio_bck(bck),.audio_ws(ws),.audio_din(din),.audio_pa_en_n(),
        .lcd_pclk(),.lcd_hsync(),.lcd_vsync(),.lcd_de(),.lcd_bl(),.lcd_r(),.lcd_g(),.lcd_b());
    always #5 clk=~clk;
    always @(posedge clk)begin
        cycles=cycles+1;
        if(rst && dut.poly_sample_strobe && dut.u_polyphony_bank_32.voice_active[0])begin
            before_target=dut.u_polyphony_bank_32.envelope_target[0];
            before_gain=dut.u_polyphony_bank_32.envelope_gain[0];
            #2;
            delta=dut.u_polyphony_bank_32.envelope_target[0]-before_target;
            if(delta>16 || delta < -16)$fatal(1,"adapter/fallback bypassed target smoothing");
            delta=dut.u_polyphony_bank_32.envelope_gain[0]-before_gain;
            if(delta>16 || delta < -16)$fatal(1,"adapter/fallback gain jump");
        end
    end
    always @(negedge bck or negedge rst)begin
        if(!rst)begin bits=0;last_ws=1;word=0;have_left=0;last_frame=-1;end
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
    task tick;begin @(posedge clk);#3;end endtask
    task sample_once;begin
        @(posedge dut.audio_sample_strobe);@(negedge clk);
        if(send_frames && index%64==0)begin frame=1;tick();@(negedge clk);frame=0;end
        index=index+1;
    end endtask
    task stream;input integer n;integer k;begin
        for(k=0;k<n;k=k+1)begin
            sample_once();
            if(fd)$fwrite(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",index,raw,
                dut.u_performance_controls.sensor_ready,dut.performance_force,
                dut.u_polyphony_bank_32.envelope_target[0],dut.u_polyphony_bank_32.envelope_gain[0],$signed(left_word));
        end
    end endtask
    initial begin
        fd=0;
        force dut.audio_internal_reset_n=rst;
        force dut.test_mode=1'b1;force dut.test_polyphony=1'b1;
        force dut.play_mode=1'b0;force dut.keymap_select=1'b0;force dut.force_value=7'd96;
        force dut.tone_select=2'd0;force dut.octave_select=2'd1;
        force dut.key_play_trigger=triggers;
        force dut.key0_pressed=gates[0];force dut.key1_pressed=gates[1];force dut.key2_pressed=gates[2];
        // Virtual ADC frame boundary only. Keep production calibration, timeout,
        // smoothing, registered controls, bank, effects route and PT8211 active.
        force dut.u_performance_controls.sensor_enable=sensors;
        force dut.u_performance_controls.frame_valid=frame;
        force dut.u_performance_controls.force_raw=raw;
        repeat(8)tick();rst=1;repeat(300)sample_once();
        for(i=0;i<32;i=i+1)begin
            @(negedge clk);triggers=1;tick();@(negedge clk);triggers=0;
            repeat(2)sample_once();
        end
        stream(5000);if(dut.polyphony_active_voice_count!=32)$fatal(1,"not 32 top-level voices");
        fd=$fopen("sim/poly_force_sensor.csv","w");if(!fd)$fatal(1,"capture open");
        $fwrite(fd,"sample,raw,ready,force,target,gain,pcm\n");
        sensors=1;send_frames=1;raw=0;stream(800);
        if(dut.performance_force!=0 || dut.u_polyphony_bank_32.envelope_gain[0]!=0 || left_word!=0)
            $fatal(1,"zero pressure not silent");
        // The existing ADC IIR advances per frame (one frame per 64 samples).
        // Allow 31 frames to settle before checking the calibrated endpoint.
        raw=1023;stream(2000);
        // Existing calibration 508/4096 maps ADC full scale to 126, not 127.
        if(dut.performance_force!=126 || dut.u_polyphony_bank_32.envelope_gain[0]!=3024)
            $fatal(1,"ADC force did not reach held voices: force=%0d target=%0d gain=%0d",dut.performance_force,dut.u_polyphony_bank_32.envelope_target[0],dut.u_polyphony_bank_32.envelope_gain[0]);
        send_frames=0;stream(5200);
        if(dut.u_performance_controls.sensor_ready || dut.performance_force!=96 || dut.u_polyphony_bank_32.envelope_gain[0]!=2304)
            $fatal(1,"stale sensor fallback failed");
        send_frames=1;raw=0;stream(2000);
        if(dut.u_polyphony_bank_32.envelope_gain[0]!=0)$fatal(1,"sensor recovery failed");
        sensors=0;send_frames=0;stream(800);
        if(dut.u_polyphony_bank_32.envelope_gain[0]!=2304)$fatal(1,"sensor disable fallback failed");
        gates=0;stream(30000);$fclose(fd);fd=0;
        if(dut.polyphony_active_voice_count || left_word)$fatal(1,"top-level final silence");
        if(dut.spectrum_deadline_misses!=0)$fatal(1,"DFT overrun");
        $display("PASS: production virtual ADC -> calibrated/smoothed force -> 32 held voices -> %0d PT8211 stereo frames; zero/full pressure; stale/disable/recovery; bounded slew; final silence",frames);
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
