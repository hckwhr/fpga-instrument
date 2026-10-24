`timescale 1ns/1ps
`define P dut.u_instrument
module tb_v3_playability_pins;
    `include "instrument_contract.vh"
    reg sys_clk=0,audio_clk=0,pixel_clk=0,locked=0;
    always #10 sys_clk=~sys_clk;
    always #10.172414 audio_clk=~audio_clk;
    always #15 pixel_clk=~pixel_clk;
    reg [159:0] values=0;
    reg [2:0] keys_n=7;
    reg setting=0;
    wire miso,sclk,mosi,cs0,cs1,bck,ws,din;
    v3_hardware_top dut(.sys_clk(sys_clk),.key0_n(keys_n[0]),.key1_n(keys_n[1]),
        .key2_n(keys_n[2]),.setting_key(setting),.adc_miso(miso),.hc05_rx(1'b1),
        .adc_sclk(sclk),.adc_mosi(mosi),.adc_cs0_n(cs0),.adc_cs1_n(cs1),
        .audio_bck(bck),.audio_ws(ws),.audio_din(din));
    v3_dual_adc_model model(cs0,cs1,sclk,mosi,values,miso);
    // Shorten only the mechanical debounce dwell in this expression test.
    // The retained tb_v3_string_pins exercises the production dwell values.
    // All inputs still traverse the real synchronizers/debouncers and common
    // CE; ADC scan timing, audio clocks and 1024-clock PCM cadence stay real.
    defparam dut.u_instrument.u_key0_debounce.STABLE_CYCLES=8;
    defparam dut.u_instrument.u_key1_debounce.STABLE_CYCLES=8;
    defparam dut.u_instrument.u_key2_debounce.STABLE_CYCLES=8;
    defparam dut.u_instrument.u_setting_key_debounce.STABLE_CYCLES=8;
    integer i,n,bits=0,nonzero=0,before_words,changes;
    reg [15:0] decoded=0;
    reg [31:0] neutral_increment,minimum_increment,maximum_increment;
    longint low_difference=0,bright_difference=0;
    integer source_now,bright_now,source_old=0,bright_old=0;
    reg measure=0;
    function [31:0] held_increment;
        integer lane, match_count;
        begin
            held_increment=0;match_count=0;
            for(lane=0;lane<32;lane++)begin
                if(`P.u_polyphony_bank_32.voice_id_valid[lane] &&
                    !`P.u_polyphony_bank_32.voice_releasing[lane])begin
                    held_increment=`P.u_polyphony_bank_32.expressed_increment[lane];
                    match_count++;
                end
            end
            if(match_count!=1)$fatal(1,"Expected exactly one held live voice, got %0d",match_count);
        end
    endfunction
    always @(negedge bck)if(`P.audio_internal_reset_n)begin
        decoded={decoded[14:0],din};
        if(bits==31)begin bits=0;if(decoded!=0)nonzero++;end
        else bits++;
    end
    always @(posedge audio_clk)if(`P.engine_ce && `P.engine_sample_strobe && measure)begin
        source_now=$signed(`P.audition_source);bright_now=$signed(`P.effects_input);
        // Capture PCM evidence. Exact serial word/protocol checks are retained
        // in tb_v3_string_pins, not replaced by these pitch assertions.
        low_difference+=source_now>source_old ? source_now-source_old : source_old-source_now;
        bright_difference+=bright_now>bright_old ? bright_now-bright_old : bright_old-bright_now;
        source_old=source_now;bright_old=bright_now;
    end
    task samples(input integer count);
        repeat(count)begin @(posedge `P.audio_sample_strobe);@(negedge audio_clk);end
    endtask
    task press(input [2:0] mask);begin keys_n=~mask;samples(6);keys_n=7;samples(6);end endtask
    task menu;begin setting=1;samples(6);setting=0;samples(6);end endtask
    initial begin
        // Only vendor clocks/locks are substituted; all menu/pressure/joystick
        // stimuli enter through physical pins, with the production half-rate CE.
        force `P.audio_clk=audio_clk;force `P.pixel_clk=pixel_clk;
        force `P.audio_pll_locked=locked;force `P.lcd_pll_locked=locked;
        for(i=0;i<12;i++)values[i*10+:10]=20+i;
        values[129:120]=512;values[139:130]=512;values[149:140]=0;
        repeat(20)@(negedge sys_clk);locked=1;wait(`P.v3_live);samples(100);
        // A centred, valid ADC must not mask the menu vibrato preset.
        menu();press(4);repeat(5)press(1);
        if(`P.u_instrument_control.edit_field!=FIELD_EXPRESSION)$fatal(1,"Expression row missing");
        press(4);
        if(`P.status_payload_cdc_audio[ST_GLIDE+:2]!=3)$fatal(1,"Top status packed score over glide");
        press(4);
        if(`P.status_payload_cdc_audio[ST_VIBRATO+:2]!=3)$fatal(1,"Top status packed score over vibrato");
        menu();values[9:0]=200;samples(600);
        if(`P.poly_vibrato!=128 || `P.polyphony_active_voice_count==0)$fatal(1,"Menu vibrato lost at centred joystick");
        minimum_increment=32'hffffffff;maximum_increment=0;
        for(n=0;n<600;n++)begin
            samples(1);
            if(held_increment()<minimum_increment)minimum_increment=held_increment();
            if(held_increment()>maximum_increment)maximum_increment=held_increment();
        end
        if(maximum_increment-minimum_increment<1000)$fatal(1,"Vibrato does not modulate a live voice");
        $display("CHECK: centred joystick preserves menu vibrato; increment range=%0d..%0d",minimum_increment,maximum_increment);
        values[9:0]=20;samples(120);
        menu();press(4);repeat(5)press(1);press(4);menu();samples(180);
        if(`P.poly_vibrato!=0)$fatal(1,"Acoustic preset failed to stop vibrato");
        values[9:0]=200;samples(300);neutral_increment=held_increment();
        values[139:130]=1000;samples(400);
        if(`P.poly_bend<100 || held_increment()<=neutral_increment)
            $fatal(1,"Physical X axis does not bend a held note upward");
        values[139:130]=24;samples(500);
        if(`P.poly_bend> -100 || held_increment()>=neutral_increment)
            $fatal(1,"Physical X axis does not bend a held note downward");
        values[139:130]=512;values[129:120]=1000;samples(500);
        if(`P.poly_vibrato<100)$fatal(1,"Physical Y axis does not add vibrato");
        values[129:120]=512;samples(500);
        if(`P.poly_bend!=0 || `P.poly_vibrato!=0)$fatal(1,"Joystick does not return to neutral");
        $display("CHECK: ADC pins bend held note in both directions and control Y vibrato/neutral");
        measure=1;samples(1024);measure=0;
        if(low_difference==0 || bright_difference<=low_difference)$fatal(1,"Brightness did not increase high-frequency energy");
        values[9:0]=20;samples(160);
        // Select every audition using real board pins, arm and leave settings.
        // All seven non-score targets must now drive the existing poly bank;
        // target 6 starts with the dry comparator before the wet string half.
        for(i=0;i<7;i++)begin
            menu();press(4);repeat(6)press(1);
            while(`P.audition_target!=i)press(2);
            press(4);menu();before_words=nonzero;samples(350);
            if(!`P.bank_audition || !`P.poly_enable || `P.poly_event_mode ||
                `P.polyphony_active_voice_count==0 || nonzero==before_words)
                $fatal(1,"Audition %0d has a silent entry",i);
            if(`P.audition_target!=i)$fatal(1,"Audition target changed during playback");
            // Deposit once, do not force: a forced register retains 191999
            // after release until its next assignment, toggling wet twice.
            // Only the four-second wait is shortened; the real rollover,
            // retrigger, engine routing and DAC output remain under test.
            @(negedge audio_clk);
            `P.u_expression_audition.sample_index=18'd191999;
            before_words=nonzero;samples(350);
            if(!`P.audition_wet || nonzero==before_words)
                $fatal(1,"Audition %0d wet failed wet=%0d words=%0d/%0d",i,`P.audition_wet,nonzero,before_words);
            if(i==0 && `P.poly_glide!=3)$fatal(1,"Wet glide audition disconnected");
            if(i==1 && `P.poly_vibrato!=128)$fatal(1,"Wet vibrato audition disconnected");
            if(i>=2 && i<=4 && `P.active_effect_select!=i-1)
                $fatal(1,"Wet effect audition disconnected");
            if(i==6 && `P.string_voice_count==0)$fatal(1,"Wet string audition disconnected");
            $display("CHECK: audition %0d dry/wet produce serial PCM and route their controls",i);
        end
        menu();press(4);repeat(6)press(1);press(2);
        if(`P.audition_target!=7)$fatal(1,"Score target inaccessible");
        press(2);if(`P.audition_target!=0)$fatal(1,"Score target cannot be left");
        $display("PASS: real menu/ADC pins -> centred manual vibrato, bidirectional bend, Y vibrato/neutral, seven audible auditions and score escape; serial_words=%0d bright_diff=%0d original_diff=%0d",nonzero,bright_difference,low_difference);
        $finish;
    end
    initial begin #1000000000;$fatal(1,"V3 playability pin timeout");end
endmodule
`undef P
