`timescale 1ns/1ps
`define H dut.u_instrument
module tb_v3_hardware_top #(parameter MUTATION=0);
    `include "instrument_contract.vh"
    reg sys_clk=0,audio_clk=0,pixel_clk=0,locked=0,running=1;
    always #10 if(running)sys_clk=~sys_clk;
    always #10.172414 audio_clk=~audio_clk;
    always #15.0 pixel_clk=~pixel_clk;
    reg [159:0] values=0;
    reg [2:0] board_keys_n=3'b111;
    reg setting=0;
    reg [2:0] board_triggers=0;
    integer audible_words=0,previous_words;
    reg [2:0] previous_field;
    wire miso,sclk,mosi,cs0,cs1,debug,bck,ws,din;
    integer ons=0,offs=0,i,bits=0;
    reg last_ws=1;
    reg [15:0] word=0;
    realtime started=-1,right_at=-1;
    // Observe the production serializer pins, not an emulated sample clock.
    integer audio_cycles=0,last_bck_edge=-1,last_sample=-1,last_accept=-1;
    integer serial_bits=0,protocol_frames=0,raw_samples=0,accepted_samples=0;
    reg previous_bck=0;
    reg [15:0] expected_word=0,decoded_word=0;
    always @(posedge audio_clk)begin
        if(!`H.audio_internal_reset_n)begin
            audio_cycles=0;last_bck_edge=-1;last_sample=-1;last_accept=-1;
            previous_bck=0;expected_word=0;raw_samples=0;accepted_samples=0;
        end else begin
            audio_cycles++;
            if(`H.engine_ce && `H.engine_sample_strobe)begin
                if(last_accept>=0 && audio_cycles-last_accept!=1024)
                    $fatal(1,"Engine lost/duplicated sample CE: %0d clocks",audio_cycles-last_accept);
                last_accept=audio_cycles;accepted_samples++;
            end
            if(`H.u_pt8211_tx.bck_half_counter==15 && !bck &&
               `H.u_pt8211_tx.frame_started && `H.u_pt8211_tx.bit_index==31)
                expected_word=(`H.audio_stream_ready || `H.u_pt8211_tx.silent_frame_count==63)
                    ? `H.audio_sample : 16'd0;
            #1;
            if(bck!=previous_bck)begin
                if(last_bck_edge>=0 && audio_cycles-last_bck_edge!=16)
                    $fatal(1,"PT8211 BCK half-period changed");
                last_bck_edge=audio_cycles;previous_bck=bck;
            end
            if(`H.audio_sample_strobe)begin
                if(last_sample>=0 && audio_cycles-last_sample!=1024)
                    $fatal(1,"PT8211 sample interval changed");
                last_sample=audio_cycles;raw_samples++;
            end
        end
    end
    always @(negedge bck)if(`H.audio_internal_reset_n)begin
        if(ws!==(serial_bits>=16))$fatal(1,"PT8211 left/right word order changed");
        decoded_word={decoded_word[14:0],din};
        if(serial_bits==15 || serial_bits==31)
            if(decoded_word!==expected_word)$fatal(1,"PT8211 word differs: got=%h expected=%h",decoded_word,expected_word);
        if(serial_bits==31)begin serial_bits=0;protocol_frames++;end
        else serial_bits++;
    end
    // Negative controls change only this isolated simulation, never production RTL.
    wire [2:0] input_keys_n=MUTATION==1 ? 3'b111 : board_keys_n;
    // Retain the accepted stage55 configuration and all its assertions.
    v3_hardware_top #(.STRING_BANK_ENABLE(0)) dut(.sys_clk(sys_clk),.key0_n(input_keys_n[0]),.key1_n(input_keys_n[1]),.key2_n(input_keys_n[2]),
        .setting_key(setting),.adc_miso(miso),.hc05_rx(1'b1),.adc_sclk(sclk),.adc_mosi(mosi),
        .adc_cs0_n(cs0),.adc_cs1_n(cs1),.pluck_debug(debug),.audio_bck(bck),.audio_ws(ws),.audio_din(din));
    v3_dual_adc_model model(cs0,cs1,sclk,mosi,values,miso);
    genvar lane;
    generate for(lane=0;lane<32;lane=lane+1)begin: check_sustain_compare
        always @(posedge audio_clk)if(`H.audio_internal_reset_n && `H.engine_ce && `H.poly_sample_strobe &&
            `H.poly_enable && !`H.poly_event_flush && `H.u_polyphony_bank_32.voice_decaying[lane])
            if(`H.u_polyphony_bank_32.u_voice_bank[lane].gain_at_sustain !==
               (`H.u_polyphony_bank_32.envelope_gain[lane] <=
                `H.u_polyphony_bank_32.u_voice_bank[lane].sustain_gain_q))
                $fatal(1,"Sustain comparator differs in lane %0d",lane);
    end endgenerate
    always @(posedge audio_clk)if(`H.audio_internal_reset_n && `H.engine_ce)begin
        if(debug)ons++;
        board_triggers=board_triggers | `H.key_play_trigger;
        if(`H.v3_valid && `H.v3_bank_ready && !`H.v3_on)offs++;
    end
    always @(negedge bck)if(locked)begin
        if(ws!=last_ws)begin bits=1;word={15'd0,din};last_ws=ws;end
        else begin bits++;word={word[14:0],din};end
        if(bits==16 && started>=0 && ws && word!=0 && right_at<0)right_at=$realtime;
        if(bits==16 && ws && word!=0)audible_words++;
    end
    task samples(input integer n);repeat(n)begin @(posedge `H.audio_sample_strobe);@(negedge audio_clk);end endtask
    initial begin
        force `H.audio_clk=audio_clk;force `H.pixel_clk=pixel_clk;
        force `H.audio_pll_locked=locked;force `H.lcd_pll_locked=locked;
        if(MUTATION==2) force `H.key_play_trigger=3'd0;
        for(i=0;i<12;i++)values[i*10+:10]=20+i;
        values[129:120]=529;values[139:130]=503;values[149:140]=1023;
        repeat(20)@(negedge sys_clk);locked=1;wait(`H.v3_live);samples(20);
        started=$realtime;
        for(i=0;i<12;i++)values[i*10+:10]=100+i*15;
        #5000000;
        if(ons!=12 || `H.song_held_notes!==12'hfff || right_at<0 || right_at-started>5000000)
            $fatal(1,"Actual V3 chord/serial latency failed ON=%d mask=%h delay=%f",ons,`H.song_held_notes,right_at-started);
        repeat(2)@(posedge `H.lcd_frame_start);samples(4);
        if(`H.keyboard_light_notes!==12'hfff || `H.u_lcd_test_pattern.status_active[ST_HELD_NOTES+:12]!==12'hfff)
            $fatal(1,"V3 LCD/LED mask mismatch");
        values[139:130]=950;values[129:120]=950;samples(250);
        if(`H.poly_bend<85 || `H.poly_vibrato<85)$fatal(1,"Joystick expression did not reach audio bank");
        running=0;samples(260);
        if(`H.v3_live || `H.song_held_notes!==0)$fatal(1,"Timeout left notes sounding");
        running=1;samples(100);if(ons!=12)$fatal(1,"Held notes retriggered after timeout");
        for(i=0;i<12;i++)values[i*10+:10]=20+i;
        samples(100);values[9:0]=320;samples(100);if(ons!=13)$fatal(1,"Release/rearm failed");
        values[9:0]=20;samples(100);if(offs!=1 || `H.song_held_notes!==0)$fatal(1,"Physical OFF lost");
        // Physical board keys still generate events; the V3 build omits their
        // obsolete DDS engine. Their physical menu path is checked below.
        for(i=0;i<3;i++)begin
            previous_words=audible_words;board_keys_n=3'b111 ^ (3'b001<<i);samples(450);
            if(!board_triggers[i] || `H.raw_audio_sample!==0 ||
                `H.pre_effect_audio_sample!==`H.live_mix_sample)
                $fatal(1,"Board key %0d failed through physical input/audio selection",i);
            board_keys_n=3'b111;samples(350);
        end
        setting=1;samples(350);setting=0;samples(350);
        if(!`H.setting_mode || `H.v3_live)$fatal(1,"Board setting pin did not enter menu");
        previous_field=`H.selected_field;
        board_keys_n=3'b110;samples(350);board_keys_n=3'b111;samples(350);
        if(`H.selected_field==previous_field)$fatal(1,"Board menu navigation failed");
        // KEY0 moves from basic row 0 to tone row 1; KEY2 increments the default
        // piano back into triangle, skipping disabled strings. Real pins only.
        board_keys_n=3'b110;samples(350);board_keys_n=3'b111;samples(350);
        board_keys_n=3'b011;samples(350);board_keys_n=3'b111;samples(350);
        if(`H.string_mode || `H.tone_select!=0)$fatal(1,"Disabled strings remain in tone menu");
        setting=1;samples(350);setting=0;samples(350);
        if(`H.setting_mode || `H.string_path_active || !`H.v3_live)
            $fatal(1,"Tone menu left keyboard silent");
        previous_words=audible_words;values[9:0]=320;samples(450);
        if(audible_words==previous_words || `H.polyphony_active_voice_count==0)
            $fatal(1,"Physical pressure key lost after tone wrap");
        values[9:0]=20;samples(350);
        repeat(2)@(posedge `H.lcd_frame_start);samples(4);
        if(`H.u_lcd_test_pattern.status_active[ST_STRING])$fatal(1,"Disabled strings shown on LCD");
        // Enter extension row 2 (32 voices), using production debounce and pins.
        setting=1;samples(350);setting=0;samples(350);
        board_keys_n=3'b011;samples(350);board_keys_n=3'b111;samples(350);
        for(i=0;i<3;i++)begin
            board_keys_n=3'b110;samples(350);board_keys_n=3'b111;samples(350);
        end
        if(`H.u_instrument_control.edit_field!=FIELD_POLYPHONY)
            $fatal(1,"Trimmed extension menu mapping differs");
        board_keys_n=3'b011;samples(350);board_keys_n=3'b111;samples(350);
        setting=1;samples(350);setting=0;samples(600);
        if(!`H.concurrent_active || `H.polyphony_active_voice_count!=32 ||
            !`H.polyphony_all_voices_active || `H.string_voice_count!=0 ||
            `H.additive_all_partials_active || `H.pre_effect_audio_sample!==`H.polyphony_test_sample)
            $fatal(1,"32-voice contest self-test not fully active");
        if(protocol_frames<100 || accepted_samples<100 || raw_samples-accepted_samples>1 || accepted_samples>raw_samples)
            $fatal(1,"Insufficient/incorrect production frame and CE sample coverage");
        $display("PT8211 pin assertions: %0d frames, BCK half-period 16, 32 BCK/frame, 1024 clocks/sample, 16-bit L then R, words exact; raw=%0d accepted=%0d",protocol_frames,raw_samples,accepted_samples);
        $display("PASS: contest V3 dual SPI -> 12 voices -> PT8211 right word %0.6f ms, LCD/LED, joystick, timeout/rearm, physical menu -> 32 self-test voices, four-tone wrap, no disabled engine",(right_at-started)/1000000.0);$finish;
    end
    initial begin #600000000;$fatal(1,"Actual V3 top timeout");end
endmodule
`undef H
