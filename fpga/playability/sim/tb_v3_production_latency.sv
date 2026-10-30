`timescale 1ns/1ps
`define V dut.u_instrument
// Digital pin-to-pin latency. No analog switch/FSR, PLL jitter or DAC model.
module tb_v3_production_latency #(
    parameter integer SLOW_SCAN=0,
    parameter integer CASE_LIMIT=144
);
    reg sys_clk=0,audio_clk=0,pixel_clk=0,locked=0,measuring=0;
    always #10 sys_clk=~sys_clk;
    always #10.172413793 audio_clk=~audio_clk;
    always #15 pixel_clk=~pixel_clk;
    reg [15:0] pressed=0;
    reg [9:0] pressure=92;
    reg [1:0] tone=0;
    wire key_serial,load_n,key_clk,miso,sclk,mosi,cs,debug,bck,ws,din;
    integer fd,cases=0,t,p,f,load_case,expected_count,ons=0,offs=0,debugs=0;
    integer levels[0:2],phases[0:5];
    reg [11:0] expected_mask,seen_on=0,seen_off=0;
    realtime started,first_on,last_on,left_at,right_at,level_at,last_force_at=-1;
    realtime worst_right=0,worst_level=0,best_right=1.0e12;
    realtime adc_age;
    v3_instrument_top dut(
        .sys_clk(sys_clk),.key0_n(1'b1),.key1_n(1'b1),.key2_n(1'b1),
        .setting_key(1'b0),.hc05_rx(1'b1),.adc_miso(miso),.key_serial(key_serial),
        .key_load_n(load_n),.key_shift_clk(key_clk),.pluck_debug(debug),
        .adc_sclk(sclk),.adc_mosi(mosi),.adc_cs0_n(cs),
        .audio_bck(bck),.audio_ws(ws),.audio_din(din));
    v3_key_model key_model(load_n,key_clk,pressed,key_serial);
    v3_adc_model adc_model(cs,sclk,mosi,pressure,10'd503,10'd529,miso);

    always @(negedge sclk)
        if(adc_model.edges==5 && adc_model.command==5'b11000)
            last_force_at=$realtime;
    always @(posedge audio_clk) if(locked && measuring) begin
        if(debug)debugs++;
        if(`V.v3_valid && `V.v3_bank_ready)begin
            if(`V.v3_note>11)$fatal(1,"Invalid V3 event note");
            if(`V.v3_on)begin
                if(!expected_mask[`V.v3_note] || seen_on[`V.v3_note])
                    $fatal(1,"Unexpected/duplicate V3 ON");
                seen_on[`V.v3_note]=1;ons++;
                if(first_on<0)first_on=$realtime;
                last_on=$realtime;
            end else begin
                if(!seen_on[`V.v3_note] || seen_off[`V.v3_note])
                    $fatal(1,"Unexpected/duplicate V3 OFF");
                seen_off[`V.v3_note]=1;offs++;
            end
        end
    end

    // PT8211 captures DIN on falling BCK. Measure complete external words;
    // the internal PCM or debug pulse cannot satisfy the audio onset gate.
    integer bits=0;
    reg last_ws=1,have_left=0;
    reg [15:0] word=0,left_word=0;
    realtime last_frame=-1;
    always @(negedge bck or negedge locked)begin
        if(!locked)begin bits=0;last_ws=1;word=0;have_left=0;last_frame=-1;end
        else begin
            if(ws!=last_ws)begin
                if(bits!=0 && bits!=16)$fatal(1,"PT8211 half-frame length %0d",bits);
                bits=1;word={15'd0,din};last_ws=ws;
            end else begin bits++;word={word[14:0],din};end
            if(bits==16)begin
                if((^word)===1'bx)$fatal(1,"Unknown PT8211 output");
                if(!ws)begin
                    left_word=word;have_left=1;
                    if(measuring && word!=0 && left_at<0)left_at=$realtime;
                end else if(have_left)begin
                    if(word!==left_word)$fatal(1,"PT8211 stereo mismatch");
                    if(last_frame>=0 && (($realtime-last_frame)<20830 || ($realtime-last_frame)>20836))
                        $fatal(1,"PT8211 sample interval");
                    last_frame=$realtime;
                    if(measuring && word!=0 && right_at<0)right_at=$realtime;
                    if(measuring && level_at<0 && ($signed(word)>=33 || $signed(word)<=-33))level_at=$realtime;
                end
            end
        end
    end
    task samples(input integer n);
        repeat(n)begin @(posedge `V.audio_sample_strobe);@(negedge audio_clk);end
    endtask
    task scenario(input integer raw,phase,timbre,all_keys,solo_note);
        begin
            @(negedge sys_clk);measuring=0;locked=0;pressed=0;pressure=92;tone=timbre;
            repeat(20)@(negedge sys_clk);locked=1;
            wait(`V.v3_live);samples(20);
            if(!`V.audio_stream_ready || `V.audio_sample!==0 || `V.u_audio_effects.level!=128)
                $fatal(1,"Unsettled V3 production startup");
            expected_mask=all_keys ? 12'hfff : (12'b1<<solo_note);
            expected_count=all_keys ? 12 : 1;
            ons=0;offs=0;debugs=0;seen_on=0;seen_off=0;
            first_on=-1;last_on=-1;left_at=-1;right_at=-1;level_at=-1;
            // After LOAD releases, sweep the remainder of the real scan,
            // including the cycle immediately before the next LOAD.
            @(negedge load_n);repeat(phase)@(negedge sys_clk);
            started=$realtime;adc_age=started-last_force_at;
            measuring=1;pressure=raw;pressed={4'd0,expected_mask};
            #5000000;
            if(ons!=expected_count || debugs!=ons || seen_on!==expected_mask ||
               first_on<0 || left_at<0 || right_at<0 || level_at<0 ||
               right_at-started>5000000 || level_at-started>5000000)
                $fatal(1,"V3 onset gate failed case=%0d raw=%0d phase=%0d tone=%0d mask=%h ON=%0d L=%0f R=%0f R33=%0f",
                       cases,raw,phase,timbre,expected_mask,ons,left_at-started,right_at-started,level_at-started);
            if(`V.song_held_notes!==expected_mask || `V.polyphony_active_voice_count!=expected_count)
                $fatal(1,"V3 accepted/held/voice count mismatch");
            if(`V.string_deadline_misses!=0 || `V.spectrum_deadline_misses!=0)
                $fatal(1,"V3 audio/DFT deadline missed");
            if(right_at-started>worst_right)worst_right=right_at-started;
            if(level_at-started>worst_level)worst_level=level_at-started;
            if(right_at-started<best_right)best_right=right_at-started;
            $fwrite(fd,"%0d,%0d,%0d,%0d,%03h,%0.3f,%0.3f,%0.3f,%0.3f,%0.3f,%0.3f\n",
                    cases,raw,phase,timbre,expected_mask,adc_age,first_on-started,last_on-started,
                    left_at-started,right_at-started,level_at-started);
            // Each occurrence must release through the same scanner/CDC/bank.
            @(negedge sys_clk);pressed=0;pressure=92;
            #2000000;
            if(offs!=expected_count || seen_off!==expected_mask || `V.song_held_notes!==0 || ons!=expected_count)
                $fatal(1,"V3 release lost or held key retriggered");
            measuring=0;cases++;
            if(cases%12==0)$display("PROGRESS: %0d V3 production serial latency cases",cases);
        end
    endtask
    initial begin
        force `V.audio_clk=audio_clk;force `V.pixel_clk=pixel_clk;
        force `V.audio_pll_locked=locked;force `V.lcd_pll_locked=locked;
        // Model a menu choice only; leave production scan, calibration,
        // event arbitration, synthesis, effects and serialization intact.
        force `V.tone_select=tone;
        levels[0]=92;levels[1]=128;levels[2]=384;
        phases[0]=26;phases[1]=27;phases[2]=4400;
        phases[3]=8800;phases[4]=12498;phases[5]=13300;
        fd=$fopen(SLOW_SCAN ? "sim/v3_latency_negative.csv" : "sim/v3_production_latency.csv","w");
        if(!fd)$fatal(1,"Cannot open V3 latency CSV");
        $fwrite(fd,"case,raw,phase_sys_cycles,timbre,key_mask,adc_ch0_age_ns,first_on_ns,last_on_ns,left_ns,right_ns,right_level33_ns\n");
        for(t=0;t<4;t++)for(f=0;f<3;f++)for(load_case=0;load_case<2;load_case++)for(p=0;p<6;p++)
            if(cases<CASE_LIMIT)scenario(levels[f],phases[p],t,load_case,(t*3+f)%12);
        $fclose(fd);
        $display("PASS: %0d V3 production serial latency cases; right min=%0.3f ms max=%0.3f ms, right33 max=%0.3f ms",
                 cases,best_right/1000000.0,worst_right/1000000.0,worst_level/1000000.0);
        $finish;
    end
    initial begin #(64'd10000000000);$fatal(1,"V3 production latency timeout");end
endmodule

// Compiled but deliberately excluded from the normal passing regression.
module tb_v3_latency_slow_scan;
    tb_v3_production_latency #(.SLOW_SCAN(1),.CASE_LIMIT(1)) test();
    // Keep the override below its originating scope (ModelSim 10.6d).
    defparam test.dut.u_instrument.v3_input.u_inputs.SCAN_IDLE_CYCLES=100000;
endmodule
`undef V
