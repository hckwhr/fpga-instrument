`timescale 1ns/1ps
`define FSR_DUT dut.u_instrument
module tb_fsr_production_latency;
    reg clk=0, audio_clk=0, pixel_clk=0, rst=0, miso=0, measuring=0;
    reg [9:0] code=0, frame_code;
    reg [4:0] command;
    reg [1:0] tone=3;
    reg strings=0;
    wire sclk, mosi, cs0, cs1, bck, ws, din;
    integer edges=0, bits=0, triggers=0, fd, cases=0, t, p, f, j;
    integer levels[0:2];
    integer phases[0:3];
    reg last_ws=1, have_left=0;
    reg [15:0] word=0, left_word=0;
    realtime started, trigger_at, left_at, right_at, level_at, last_frame;
    realtime worst_right=0, worst_level=0;
    // Actual production wrapper, with no FSR parameter overrides.
    fsr_instrument_top dut(
        .sys_clk(clk), .key0_n(1'b1), .key1_n(1'b1), .key2_n(1'b1),
        .setting_key(1'b0), .adc_miso(miso), .adc_sclk(sclk), .adc_mosi(mosi),
        .adc_cs0_n(cs0), .adc_cs1_n(cs1), .audio_bck(bck), .audio_ws(ws), .audio_din(din),
        .adc_led(), .audio_pa_en_n(), .lcd_pclk(), .lcd_hsync(), .lcd_vsync(),
        .lcd_de(), .lcd_bl(), .lcd_r(), .lcd_g(), .lcd_b());
`ifdef FSR_LATENCY_OLD_PERIOD
    // Negative control only: the old production scan must fail this same gate.
    defparam dut.u_instrument.FSR_SAMPLE_PERIOD_CYCLES=250000;
`endif
    always #10 clk=~clk;
    // PLL ratios: audio=50 MHz*58/59, pixel=50 MHz*2/3.
    // 1 ps resolution; does not model physical PLL jitter or analog DAC delay.
    always #10.172413793 audio_clk=~audio_clk;
    always #15 pixel_clk=~pixel_clk;
    always @(negedge cs0) begin
        edges=0;command=0;frame_code=code;miso=0;
    end
    always @(posedge sclk) begin
        if(cs1!==1'b1 || cs0!==1'b0) $fatal(1,"ADC CS conflict");
        if(edges<5) command={command[3:0],mosi};
        edges=edges+1;
        if(edges==5 && command!==5'b11000) $fatal(1,"Wrong ADC CH0 command");
    end
    always @(negedge sclk)
        if(edges>=6 && edges<=15) miso=frame_code[15-edges]; else miso=0;
    always @(posedge `FSR_DUT.fsr_trigger) if(measuring) begin
        if(trigger_at<0) trigger_at=$realtime;
        triggers=triggers+1;
    end
    // Complete words at the external PT8211 sampling edge.
    always @(negedge bck or negedge rst) begin
        if(!rst) begin bits=0;last_ws=1;word=0;have_left=0;last_frame=-1;end
        else begin
            if(ws!=last_ws) begin bits=1;word={15'd0,din};last_ws=ws;end
            else begin bits=bits+1;word={word[14:0],din};end
            if(bits==16) begin
                if((^word)===1'bx) $fatal(1,"Unknown serialized word");
                if(!ws) begin
                    left_word=word;have_left=1;
                    if(measuring && word!=0 && left_at<0) left_at=$realtime;
                end else if(have_left) begin
                    if(word!==left_word) $fatal(1,"Stereo mismatch");
                    if(last_frame>=0 && (($realtime-last_frame)<20830 || ($realtime-last_frame)>20836))
                        $fatal(1,"Unexpected serial audio sample interval");
                    last_frame=$realtime;
                    if(measuring && word!=0 && right_at<0) right_at=$realtime;
                    if(measuring && level_at<0 && ($signed(word)>=33 || $signed(word)<=-33))
                        level_at=$realtime;
                end
            end
        end
    end
    task settle;
        begin
            @(negedge clk);measuring=0;rst=0;code=0;
            repeat(10) @(negedge clk);
            rst=1;
            // Serializer startup, effect gain ramp and real idle release.
            repeat(230000) @(negedge audio_clk);
            wait(`FSR_DUT.fsr_ready && `FSR_DUT.fsr_input.u_fsr.armed);
            @(negedge audio_clk);
            if(!`FSR_DUT.fsr_ready || !`FSR_DUT.fsr_input.u_fsr.armed ||
               `FSR_DUT.audio_sample!==0 || `FSR_DUT.u_audio_effects.level!=128)
                $fatal(1,"Unsettled production startup");
            trigger_at=-1;left_at=-1;right_at=-1;level_at=-1;triggers=0;
        end
    endtask
    task scenario;
        input integer raw, phase, timbre;
        begin
            tone=(timbre==4)?3:timbre;strings=(timbre==4);
            settle();
            // Zero was just latched. Sweep the entire 266 us interval,
            // including just before the next acquisition.
            @(negedge cs0);repeat(phase) @(negedge clk);
            started=$realtime;measuring=1;code=raw;
            #5000000;
            if(triggers!=1 || trigger_at<0 || left_at<0 || right_at<0 || level_at<0)
                $fatal(1,"Missing/duplicate onset raw=%0d phase=%0d tone=%0d trigger=%0d L=%0f R=%0f level=%0f",
                       raw,phase,timbre,triggers,left_at-started,right_at-started,level_at-started);
            if(right_at-started>5000000 || level_at-started>5000000)
                $fatal(1,"Digital FSR onset exceeded 5 ms");
            if(`FSR_DUT.string_deadline_misses!=0 || `FSR_DUT.spectrum_deadline_misses!=0)
                $fatal(1,"Audio/DFT deadline missed");
            if(right_at-started>worst_right) worst_right=right_at-started;
            if(level_at-started>worst_level) worst_level=level_at-started;
            $fwrite(fd,"%0d,%0d,%0d,%0d,%0.3f,%0.3f,%0.3f,%0.3f\n",cases,raw,phase,timbre,
                    trigger_at-started,left_at-started,right_at-started,level_at-started);
            cases=cases+1;measuring=0;
            if(cases%12==0) $display("PROGRESS: %0d FSR serial latency cases",cases);
        end
    endtask
    initial begin
        force `FSR_DUT.audio_clk=audio_clk;
        force `FSR_DUT.pixel_clk=pixel_clk;
        force `FSR_DUT.sys_async_reset_n=rst;
        force `FSR_DUT.audio_async_reset_n=rst;
        force `FSR_DUT.pixel_async_reset_n=rst;
        // Only clocks/reset and menu choices are modeled. Never force sensor
        // readiness, filtering, trigger, synthesis, PCM or serializer.
        force `FSR_DUT.tone_select=tone;
        force `FSR_DUT.string_mode=strings;
        force `FSR_DUT.play_mode=1'b1;
        force `FSR_DUT.setting_mode=1'b0;
        force `FSR_DUT.note_select=4'd0;
        levels[0]=180;levels[1]=256;levels[2]=384;
        phases[0]=1;phases[1]=4433;phases[2]=8866;phases[3]=13299;
        fd=$fopen("sim/fsr_production_latency.csv","w");if(!fd)$fatal(1,"Cannot open latency CSV");
        $fwrite(fd,"case,raw,phase_sys_cycles,timbre,trigger_ns,left_ns,right_ns,right_level33_ns\n");
        for(t=0;t<5;t=t+1) for(f=0;f<3;f=f+1) for(p=0;p<4;p=p+1)
            scenario(levels[f],phases[p],t);
        $fclose(fd);
        // Reject subthreshold noise and a single full-scale ADC spike.
        settle();measuring=1;
        for(j=0;j<24;j=j+1) begin @(posedge cs0);code=(j%2)?124:100;end
        #3000000;
        if(triggers!=0 || `FSR_DUT.fsr_gate) $fatal(1,"Subthreshold noise played a note");
        code=0;#5000000;
        @(posedge cs0);code=1023;@(negedge cs0);@(posedge cs0);code=0;
        #5000000;
        if(triggers!=0 || `FSR_DUT.fsr_gate) $fatal(1,"Single ADC spike played a note");
        $display("PASS: %0d production-wrapper FSR serial cases; worst right=%0.3f ms, right33=%0.3f ms; noise/spike rejected",
                 cases,worst_right/1000000.0,worst_level/1000000.0);
        $finish;
    end
    initial begin #1000000000;$fatal(1,"Production FSR latency timeout");end
endmodule
`undef FSR_DUT
