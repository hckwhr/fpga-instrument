`timescale 1ns/1ps
`define V dut.u_instrument
module tb_v3_production_top;
    `include "instrument_contract.vh"
    reg sys_clk=0,audio_clk=0,pixel_clk=0,locked=0,run_sys=1;
    always #10 if(run_sys)sys_clk=~sys_clk;
    always #10.172414 audio_clk=~audio_clk;
    always #15.151515 pixel_clk=~pixel_clk;
    reg [15:0] pressed=0;
    reg [9:0] fp=92,xp=503,yp=529;
    wire key_serial,load_n,key_clk,miso,sclk,mosi,cs,debug,bck,ws,din;
    integer ons=0,offs=0,debugs=0,peak=0,serial_peak=0,magnitude,bit_count=0;
    reg [15:0] serial_word=0,frame_pcm=0;
    reg [79:0] previous_display=0;
    reg previous_frame=0,display_seen=0;
    v3_instrument_top dut(
        .sys_clk(sys_clk),.key0_n(1'b1),.key1_n(1'b1),.key2_n(1'b1),.setting_key(1'b0),.hc05_rx(1'b1),
        .adc_miso(miso),.key_serial(key_serial),.key_load_n(load_n),.key_shift_clk(key_clk),.pluck_debug(debug),
        .adc_sclk(sclk),.adc_mosi(mosi),.adc_cs0_n(cs),.audio_bck(bck),.audio_ws(ws),.audio_din(din));
    v3_key_model key_model(load_n,key_clk,pressed,key_serial);
    v3_adc_model adc_model(cs,sclk,mosi,fp,xp,yp,miso);
    always @(posedge audio_clk)if(`V.audio_internal_reset_n)begin
        if(`V.v3_valid && `V.v3_bank_ready)begin if(`V.v3_on)ons++;else offs++;end
        if(debug)debugs++;
        if(`V.audio_sample_strobe)begin
            if((^`V.audio_sample)===1'bx)$fatal(1,"unknown production PCM");
            magnitude=$signed(`V.audio_sample)<0?-$signed(`V.audio_sample):$signed(`V.audio_sample);
            if(magnitude>=32767)$fatal(1,"production chord clipped");
            if(magnitude>peak)peak=magnitude;
        end
    end
    always @(posedge bck)if(`V.audio_internal_reset_n && !ws && `V.u_pt8211_tx.bit_index==0)frame_pcm=`V.audio_sample;
    always @(negedge bck)if(`V.audio_internal_reset_n)begin
        serial_word={serial_word[14:0],din};bit_count++;
        if(bit_count==16)begin
            bit_count=0;
            if(`V.audio_stream_ready && serial_word!==frame_pcm)$fatal(1,"PT8211 physical output mismatch");
            magnitude=$signed(serial_word)<0?-$signed(serial_word):$signed(serial_word);
            if(magnitude>serial_peak)serial_peak=magnitude;
        end
    end
    always @(posedge pixel_clk)if(`V.pixel_internal_reset_n)begin
        if(display_seen && !previous_frame && previous_display!=={`V.u_lcd_test_pattern.upload_active,`V.u_lcd_test_pattern.status_active})
            $fatal(1,"LCD status changed inside frame");
        previous_display={`V.u_lcd_test_pattern.upload_active,`V.u_lcd_test_pattern.status_active};
        previous_frame=`V.lcd_frame_start;display_seen=1;
    end
    task samples(input integer n);repeat(n)begin @(posedge `V.audio_sample_strobe);@(negedge audio_clk);end endtask
    task check_mask(input [11:0] expected);
        begin
            repeat(2)@(posedge `V.lcd_frame_start);samples(4);
            if(`V.song_held_notes!==expected || `V.keyboard_light_notes!==expected ||
                `V.u_lcd_test_pattern.status_active[ST_HELD_NOTES +: 12]!==expected)
                $fatal(1,"audio/LCD/LED held mask mismatch expected %h got %h/%h",expected,`V.song_held_notes,`V.keyboard_light_notes);
        end
    endtask
    initial begin
        force `V.audio_clk=audio_clk;force `V.pixel_clk=pixel_clk;
        force `V.audio_pll_locked=locked;force `V.lcd_pll_locked=locked;
        repeat(20)@(negedge sys_clk);locked=1;
        wait(`V.v3_live);samples(20);pressed=16'h0891;
        samples(180);if(ons!=4 || `V.polyphony_active_voice_count!=4)$fatal(1,"four-key polyphony missing %d/%d",ons,`V.polyphony_active_voice_count);
        check_mask(12'h891);
        fp=320;xp=950;yp=950;samples(300);
        if(`V.poly_bend<85 || `V.poly_vibrato<85 || `V.u_polyphony_bank_32.expression_bypass ||
            `V.u_polyphony_bank_32.expression_ratio<=262144)$fatal(1,"live event expression bypassed");
        if(`V.u_polyphony_bank_32.envelope_target[0]<3000)$fatal(1,"continuous live pressure missing");
        // Enter/leave settings via the physical MODE input while notes stay held.
        pressed=16'h1891;samples(100);if(!`V.setting_mode || `V.v3_live)$fatal(1,"physical MODE failed");
        pressed=16'h0891;samples(100);pressed=16'h1891;samples(100);
        if(`V.setting_mode)$fatal(1,"MODE did not leave settings");
        pressed=16'h0891;samples(180);if(ons!=4 || `V.song_held_notes!==0)$fatal(1,"held notes replayed after menu");
        pressed=0;fp=92;xp=503;yp=529;samples(200);
        pressed=16'h0005;samples(160);if(ons!=6)$fatal(1,"fresh notes failed after menu");
        pressed=0;samples(200);if(offs!=2 || `V.song_held_notes!==0)$fatal(1,"physical OFF lost");
        check_mask(0);
        pressed=1;samples(150);run_sys=0;samples(300);
        if(`V.v3_live || `V.song_held_notes!==0)$fatal(1,"stale inputs stuck notes");
        run_sys=1;samples(180);if(ons!=7)$fatal(1,"stale held key retriggered");
        pressed=0;samples(150);pressed=1;samples(150);if(ons!=8)$fatal(1,"timeout rearm failed");
        pressed=0;samples(1600);
        if(`V.audio_sample!==0 || `V.song_held_notes!==0 || `V.polyphony_active_voice_count!=0)$fatal(1,"release left audio active");
        // C18 carries the debounced key level now, not one pulse per note
        // event, so it must have been high while keys were held rather than
        // matching the ON count.
        if(peak<20 || serial_peak<20 || debugs==0)$fatal(1,"output or debug level missing");
        $display("PASS: production V3 SPI+165 to four-voice PCM/PT8211, live expression, frame-atomic LCD/LED mask, MODE, timeout/rearm; peak=%d serial=%d",peak,serial_peak);$finish;
    end
    initial begin #300000000;$fatal(1,"V3 production timeout");end
endmodule
`undef V
