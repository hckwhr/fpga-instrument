`timescale 1ns/1ps
`define H dut.u_instrument
`define S dut.u_instrument.strings_enabled.u_physical_string_bank
// No event/mode forces: dual ADC pins and debounced physical menu pins are
// the only stimuli. Only vendor PLL outputs are replaced by simulation clocks.
module tb_hdmi_instrument_pins;
    reg sys_clk=0,audio_clk=0,pixel_clk=0,render_clk=0,locked=0;
    always #10 sys_clk=~sys_clk;
    always #10.172414 audio_clk=~audio_clk;
    always #6.734006734 pixel_clk=~pixel_clk;
    always #13.468013468 render_clk=~render_clk;
    reg [159:0] values=0;
    reg [2:0] keys_n=7;
    reg setting=0;
    wire miso,sclk,mosi,cs0,cs1,bck,ws,din;
    v3_hdmi_top dut(.sys_clk(sys_clk),.key0_n(keys_n[0]),.key1_n(keys_n[1]),
        .key2_n(keys_n[2]),.setting_key(setting),.adc_miso(miso),.hc05_rx(1'b1),
        .adc_sclk(sclk),.adc_mosi(mosi),.adc_cs0_n(cs0),.adc_cs1_n(cs1),
        .audio_bck(bck),.audio_ws(ws),.audio_din(din),
        .hdmi_tx_enable(),.hdmi_data_n(),.hdmi_data_p(),.hdmi_clock_n(),.hdmi_clock_p(),
        .audio_pa_en_n(),.ws2812_data(),.hc05_tx(),.adc_led(),.pluck_debug());
    v3_dual_adc_model model(cs0,cs1,sclk,mosi,values,miso);
    // Frozen 66d renderer sees exactly the production registered raster and
    // physical-input-derived status/audio. Check RGB and control on EVERY
    // render edge, including blanking, row transitions and frame commits.
    wire [17:0] reference_rgb;
    wire reference_hs,reference_vs,reference_de;
    integer equivalent_pixels=0;
    stage67_panel_reference #(.COMPACT_SCOPE(1),.UPLOAD_UI(1),.LIVE_KEYBOARD(1),
        .ADDITIVE_BANK_ENABLE(0),.STRING_BANK_ENABLE(1),.KEYBOARD_MODE_ENABLE(1)) pixel_reference (
        .pixel_clk(`H.pixel_clk),.reset_n(`H.pixel_internal_reset_n),
        .active_x(`H.lcd_active_x),.next_active_x(`H.panel_next_x),.active_y(`H.lcd_active_y),
        .predecode_y(`H.raw_y),
        .data_enable(`H.panel_enable),.hsync_in(`H.lcd_hsync_timing),.vsync_in(`H.lcd_vsync_timing),
        .frame_start(`H.lcd_frame_start),.audio_sample(`H.pixel_audio_sample),
        .audio_sample_valid(`H.pixel_audio_sample_valid),.status_payload(`H.status_payload_pixel),
        .status_update(`H.status_payload_update_pixel),.upload_status(`H.upload_status_pixel),
        .red(reference_rgb[17:12]),.green(reference_rgb[11:6]),.blue(reference_rgb[5:0]),
        .hsync_out(reference_hs),.vsync_out(reference_vs),.de_out(reference_de));
    integer hdmi_pixels=0,hdmi_panels=0,hdmi_frames=0;
    reg [1:0] expected_de=0,expected_hs=0,expected_vs=0;
    reg [36:0] expected_raster;
    always @(posedge `H.pixel_clk)begin
        if(!`H.pixel_internal_reset_n)begin expected_de=0;expected_hs=0;expected_vs=0;end
        else begin
            expected_raster={`H.raw_hsync,`H.raw_vsync,`H.raw_de,`H.raw_frame,`H.raw_panel,
                             `H.raw_x,`H.raw_next_x,`H.raw_y};
            expected_de={expected_de[0],`H.lcd_de_timing};
            expected_hs={expected_hs[0],`H.lcd_hsync_timing};
            expected_vs={expected_vs[0],`H.lcd_vsync_timing};
            #0.01;
            if({`H.lcd_r_internal,`H.lcd_g_internal,`H.lcd_b_internal,
                `H.lcd_hsync_internal,`H.lcd_vsync_internal,`H.lcd_de_internal} !==
                {reference_rgb,reference_hs,reference_vs,reference_de})
                $fatal(1,"pin-driven pixel differs from frozen stage67 baseline x=%0d y=%0d",`H.lcd_active_x,`H.lcd_active_y);
            equivalent_pixels++;
            if({`H.lcd_hsync_timing,`H.lcd_vsync_timing,`H.lcd_de_timing,`H.lcd_frame_start,
                `H.panel_enable,`H.lcd_active_x,`H.panel_next_x,`H.lcd_active_y}!==expected_raster)
                $fatal(1,"Raster coordinate/control stage is not exactly one cycle");
            if(`H.de_delay!==expected_de || `H.hsync_delay!==expected_hs || `H.vsync_delay!==expected_vs)
                $fatal(1,"HDMI RGB/control pipeline misaligned");
            if(`H.de_delay[1])begin
                hdmi_pixels+=2;
                if((^`H.hdmi_rgb)===1'bx)$fatal(1,"Unknown HDMI pixel");
            end
            if(`H.panel_enable_delay[1])hdmi_panels+=2;
            if(`H.lcd_frame_start)hdmi_frames++;
        end
    end
    integer ons=0,offs=0,writes=0,frames=0,nonzero=0,bits=0;
    integer cycles=0,last_sample=-1,last_bck=-1,slot=0,i,k,old_on,old_off,old_write;
    reg previous_bck=0;
    reg [15:0] decoded=0,expected=0;
    reg measure=0;
    longint energy=0,soft_energy,hard_energy;
    integer magnitude;
    reg reference_pending=0;
    always @(posedge audio_clk)begin
        if(!`H.audio_internal_reset_n)begin
            cycles=0;last_sample=-1;last_bck=-1;previous_bck=0;bits=0;expected=0;
            reference_pending=0;
        end else begin
            // Frozen stage66c pulse rule, independent of the new PT8211 preview.
            if(`H.engine_sample_strobe!==(`H.audio_sample_strobe || reference_pending))
                $fatal(1,"New sample preview changed the accepted physical edge");
            if(`H.audio_sample_due && !`H.engine_ce)
                $fatal(1,"PT8211 frame load violated the common-reset CE phase contract");
            if(`H.engine_ce)reference_pending=0;
            else if(`H.audio_sample_strobe)reference_pending=1;
            cycles++;
            if(`H.engine_ce)begin
                if(`H.poly_event_mode && `H.string_event_mode)$fatal(1,"Both event owners enabled");
                if(`H.v3_valid && `H.v3_bank_ready)begin
                    if(`H.v3_on)ons++;else offs++;
                    if(!`H.string_event_mode)$fatal(1,"String key event routed to wrong bank");
                end
                if(`S.state==4)writes++;
            end
            if(`H.u_pt8211_tx.bck_half_counter==15 && !bck &&
                `H.u_pt8211_tx.frame_started && `H.u_pt8211_tx.bit_index==31)
                expected=(`H.audio_stream_ready || `H.u_pt8211_tx.silent_frame_count==63)?`H.audio_sample:0;
            #1;
            if(bck!=previous_bck)begin
                if(last_bck>=0 && cycles-last_bck!=16)$fatal(1,"BCK cadence changed");
                last_bck=cycles;previous_bck=bck;
            end
            if(`H.audio_sample_strobe)begin
                if(last_sample>=0 && cycles-last_sample!=1024)$fatal(1,"Sample cadence changed");
                last_sample=cycles;
            end
        end
    end
    always @(negedge bck)if(`H.audio_internal_reset_n)begin
        if(ws!==(bits>=16))$fatal(1,"PT8211 L/R order changed");
        decoded={decoded[14:0],din};
        if(bits==15 || bits==31)begin
            if(decoded!==expected)$fatal(1,"PT8211 PCM word mismatch");
            if(bits==31)begin
                frames++;
                if(decoded!=0)nonzero++;
                magnitude=$signed(decoded)<0?-$signed(decoded):$signed(decoded);
                if(measure)energy+=magnitude;
            end
        end
        if(bits==31)bits=0;else bits++;
    end
    task samples(input integer n);
        repeat(n)begin @(posedge `H.audio_sample_strobe);@(negedge audio_clk);end
    endtask
    task press(input [2:0] mask);
        begin keys_n=~mask;samples(70);keys_n=7;samples(70);end
    endtask
    task menu;
        begin setting=1;samples(300);setting=0;samples(300);end
    endtask
    task boot_strings;
        begin
            locked=0;keys_n=7;setting=0;measure=0;
            for(i=0;i<12;i++)values[i*10+:10]=20+i;
            values[129:120]=512;values[139:130]=512;values[149:140]=1023;
            repeat(20)@(negedge sys_clk);locked=1;
            wait(`H.v3_live);samples(20);
            menu();press(1);press(1);press(4);
            if(!`H.string_mode)$fatal(1,"Physical tone menu failed to select strings");
            menu();samples(8);
            if(!`H.v3_string_live || !`H.string_event_mode || `H.poly_event_mode)
                $fatal(1,"Pressure event owner did not switch to strings");
        end
    endtask
    initial begin
        force `H.audio_clk=audio_clk;force `H.hdmi_pixel_clk=pixel_clk;
        force `H.pixel_clk=render_clk;
        force `H.audio_pll_locked=locked;force `H.display_pll_locked=locked;
        boot_strings();
        // Every physical sensor must cause exactly one waveguide allocation
        // and its matching OFF. The 12-key allocator has its own steal test.
        for(k=0;k<12;k++)begin
            old_on=ons;old_off=offs;old_write=writes;
            values[k*10+:10]=300+k;samples(120);
            if(ons!=old_on+1 || writes!=old_write+1 || `S.voice_id_valid==0)
                $fatal(1,"Physical pressure key %0d failed ON/allocation",k);
            values[k*10+:10]=20+k;samples(120);
            if(offs!=old_off+1 || `S.voice_id_valid!=0)
                $fatal(1,"Physical pressure key %0d failed matching release",k);
        end
        if(nonzero<100)$fatal(1,"Pressure strings produced no serial audio");
        // Reset and replay the identical note/voice/noise seed. Only ADC force
        // changes; compare actual DAC words rather than an internal amplitude.
        // Hold sensitivity at 1x for the original 80/300-count A/B comparison;
        // the maximum sensitivity mapping has a separate exact ADC test.
        boot_strings();values[149:140]=0;samples(100);values[9:0]=100;samples(120);energy=0;measure=1;
        samples(96);measure=0;soft_energy=energy;
        values[9:0]=20;samples(120);
        if(`S.voice_id_valid!=0)$fatal(1,"Soft note release stuck");
        boot_strings();values[149:140]=0;samples(100);values[9:0]=320;samples(120);energy=0;measure=1;
        samples(96);measure=0;hard_energy=energy;
        // Soft must be clearly audible and hard clearly louder. The velocity
        // curve deliberately raises the quiet end -- a light press used to sit
        // at -20 dB -- so the ratio is smaller than the old linear map's while
        // the soft note itself is far stronger in absolute terms.
        if(soft_energy<=0 || hard_energy<=(soft_energy*5)/4)
            $fatal(1,"Physical force not audible: soft=%0d hard=%0d",soft_energy,hard_energy);
        values[9:0]=20;samples(120);
        if(`S.voice_id_valid!=0)$fatal(1,"Hard note release stuck");
        if(`H.additive_all_partials_active || `H.string_deadline_misses!=0)
            $fatal(1,"Unexpected additive engine or string deadline miss");
        menu();press(4);press(1);press(1);press(1);press(4);menu();samples(160);
        if(!`H.concurrent_active || `H.polyphony_active_voice_count!=32 ||
            `H.string_voice_count!=0 || `S.enable || `H.additive_all_partials_active ||
            `H.pre_effect_audio_sample!==`H.polyphony_test_sample)
            $fatal(1,"Restoring strings revived all-engine concurrent self-test");
        if(hdmi_pixels<2073600 || hdmi_panels<1536000 || hdmi_frames<2)
            $fatal(1,"HDMI dashboard not exercised");
        $display("Pixel equivalence: %0d render edges match frozen stage66d RGB/HS/VS/DE, including physical menu changes and reset",equivalent_pixels);
        $display("PASS: HDMI product physical dual-ADC pins -> all 12 keys -> 8 strings -> exact PT8211 words; ON=%0d OFF=%0d writes=%0d frames=%0d nonzero=%0d force_soft=%0d force_hard=%0d; 16 clocks/BCK half, 1024 clocks/frame",ons,offs,writes,frames,nonzero,soft_energy,hard_energy);
        $finish;
    end
    initial begin #400000000;$fatal(1,"V3 string pin timeout");end
endmodule
`undef H
`undef S
