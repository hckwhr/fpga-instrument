`timescale 1ns/1ps
`define KM dut.u_instrument
`define KB dut.u_instrument.u_polyphony_bank_32
module tb_keyboard_modes_pins;
    `include "instrument_contract.vh"
    reg sys_clk=0,audio_clk=0,pixel_clk=0,locked=0,setting=0;
    reg [2:0] keys_n=7;
    reg [159:0] values=0;
    wire miso,sclk,mosi,cs0,cs1,bck,ws,din;
    always #10 sys_clk=~sys_clk;
    always #10.172414 audio_clk=~audio_clk;
    always #15 pixel_clk=~pixel_clk;
    v3_hardware_top dut(.sys_clk(sys_clk),.key0_n(keys_n[0]),.key1_n(keys_n[1]),
        .key2_n(keys_n[2]),.setting_key(setting),.adc_miso(miso),.hc05_rx(1'b1),
        .adc_sclk(sclk),.adc_mosi(mosi),.adc_cs0_n(cs0),.adc_cs1_n(cs1),
        .audio_bck(bck),.audio_ws(ws),.audio_din(din));
    v3_dual_adc_model model(cs0,cs1,sclk,mosi,values,miso);
    // Only mechanical menu dwell is shortened. The 125 retained checks include
    // production debounce; ADC/SPI, CE, audio frame, event and DAC paths are real.
    defparam dut.u_instrument.u_key0_debounce.STABLE_CYCLES=8;
    defparam dut.u_instrument.u_key1_debounce.STABLE_CYCLES=8;
    defparam dut.u_instrument.u_key2_debounce.STABLE_CYCLES=8;
    defparam dut.u_instrument.u_setting_key_debounce.STABLE_CYCLES=8;
    integer i,k,lane,found,bits=0,frames=0,nonzero=0,clipped=0,start_words;
    integer c_lane,high_lane,clocks=0,last_frame=0;
    reg [15:0] decoded=0,expected_word=0;
    reg [31:0] pitch[0:11];
    reg measure=0;
    always @(posedge audio_clk)if(`KM.audio_internal_reset_n)begin
        clocks++;
        if(`KM.audio_sample_strobe)begin
            if(last_frame!=0 && clocks-last_frame!=1024)$fatal(1,"Sample rate changed");
            last_frame=clocks;
        end
        if(`KM.u_pt8211_tx.bck_half_counter==15 && !bck &&
           `KM.u_pt8211_tx.frame_started && `KM.u_pt8211_tx.bit_index==31)
            expected_word=(`KM.audio_stream_ready || `KM.u_pt8211_tx.silent_frame_count==63)?`KM.audio_sample:0;
        if(`KM.v3_live && `KM.v3_string_live)$fatal(1,"Both banks own live keys");
    end
    always @(negedge bck)if(`KM.audio_internal_reset_n)begin
        if(ws!==(bits>=16))$fatal(1,"DAC channel order changed");
        decoded={decoded[14:0],din};
        if(bits==15 || bits==31)if(decoded!==expected_word)$fatal(1,"DAC word mismatch");
        if(bits==31)begin
            frames++;
            if(measure)begin
                if(decoded!=0)nonzero++;
                if(decoded==16'h7fff || decoded==16'h8000)clipped++;
            end
            bits=0;
        end else bits++;
    end
    task samples(input integer n);repeat(n)begin @(posedge `KM.audio_sample_strobe);@(negedge audio_clk);end endtask
    task press(input [2:0] mask);begin keys_n=~mask;samples(6);keys_n=7;samples(6);end endtask
    task menu;begin setting=1;samples(6);setting=0;samples(6);end endtask
    task release_keys;begin for(k=0;k<12;k++)values[k*10+:10]=20;samples(80);end endtask
    task audible;begin
        start_words=nonzero;measure=1;samples(64);measure=0;
        if(nonzero-start_words<50 || clipped!=0)$fatal(1,"Silent/clipped physical output");
    end endtask
    task check_key(input integer key);begin
        found=0;
        for(lane=0;lane<32;lane++)if(`KB.voice_id_valid[lane] && !`KB.voice_releasing[lane] && `KB.voice_note[lane]==key)begin
            found++;
            if(`KB.phase_increment_reg[lane]!==pitch[key])$fatal(1,"Physical key %0d wrong pitch",key+1);
        end
        if(found!=1)$fatal(1,"Physical key %0d missing/duplicated",key+1);
    end endtask
    initial begin
        force `KM.audio_clk=audio_clk;force `KM.pixel_clk=pixel_clk;
        force `KM.audio_pll_locked=locked;force `KM.lcd_pll_locked=locked;
        for(k=0;k<12;k++)values[k*10+:10]=20;
        values[129:120]=512;values[139:130]=512;values[149:140]=1023;
        pitch[0]=23409859;pitch[1]=26276679;pitch[2]=29494575;pitch[3]=31248413;
        pitch[4]=35075158;pitch[5]=39370534;pitch[6]=44191930;
        pitch[7]=46819718;pitch[8]=52553358;pitch[9]=58989150;pitch[10]=62496826;pitch[11]=70150316;
        repeat(20)@(negedge sys_clk);locked=1;wait(`KM.v3_live);samples(100);
        // Keep a real string selection underneath the piano overlay.
        menu();press(4);repeat(4)press(1);press(4);
        if(!`KM.string_mode)$fatal(1,"String setting not selected");
        repeat(3)press(1);
        if(`KM.u_instrument_control.edit_field!=FIELD_KEYBOARD)$fatal(1,"New row unreachable from pins");
        press(4);
        if(!`KM.status_payload_cdc_audio[ST_KEYBOARD_PIANO])$fatal(1,"Mode not sent to LCD");
        if(!`KM.status_payload_cdc_audio[ST_STRING])$fatal(1,"Piano overlay hides stored string selection in settings");
        press(1); // value must remain correct when focus returns to tabs
        if(!`KM.status_payload_cdc_audio[ST_KEYBOARD_PIANO])$fatal(1,"Unfocused mode label lost");
        menu();samples(120);
        if(!`KM.v3_live || `KM.v3_string_live || `KM.poly_tone!=3 || !`KM.string_mode)
            $fatal(1,"Piano overlay routed incorrectly or erased string setting");
        for(i=0;i<12;i++)begin
            values[i*10+:10]=400;samples(180);check_key(i);audible();release_keys();
            $display("CHECK: physical white key %0d increment=%0d audible on PT8211",i+1,pitch[i]);
        end
        // At maximum sensitivity ADC=150 already saturates to force=127.
        // Use 90 for an actually distinct lower pressure, not two full levels.
        values[9:0]=90;values[79:70]=400;samples(300);check_key(0);check_key(7);
        c_lane=-1;high_lane=-1;
        for(lane=0;lane<32;lane++)if(`KB.voice_id_valid[lane] && !`KB.voice_releasing[lane])begin
            if(`KB.voice_note[lane]==0)c_lane=lane;
            if(`KB.voice_note[lane]==7)high_lane=lane;
        end
        if(`KM.v3_key_forces[6:0]>=`KM.v3_key_forces[55:49])$fatal(1,"Pressure fixture saturated both keys");
        if(`KB.envelope_target[c_lane]>=`KB.envelope_target[high_lane])$fatal(1,"Physical octave forces alias");
        audible();values[9:0]=20;samples(100);
        if(`KM.v3_held_notes!=12'h080)$fatal(1,"One OFF affects both octave keys");
        check_key(7);audible();
        // Mode change while held must flush, require release, then restore the
        // original string configuration rather than retrigger a stale owner.
        menu();press(4);repeat(7)press(1);press(2);menu();samples(150);
        if(`KM.keyboard_piano || !`KM.v3_string_live || `KM.v3_held_notes!=0)
            $fatal(1,"Switch-back failed or held key retriggered");
        release_keys();values[19:10]=400;samples(300);
        if(`KM.string_voice_count==0 || `KM.v3_held_notes!=12'h002)$fatal(1,"Original string mode not restored");
        audible();release_keys();
        $display("PASS: real menu + ADC pins, all 12 white notes, independent C/high-C force and release, mode switch while held, string restore, exact PT8211 words and 1024-clock frames; frames=%0d",frames);
        $finish;
    end
    initial begin #1000000000;$fatal(1,"Keyboard mode pin timeout");end
endmodule
`undef KM
`undef KB
