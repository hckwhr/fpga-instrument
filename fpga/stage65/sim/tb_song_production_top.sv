`timescale 1ns/1ps
// Full logical top: only PLL clocks/locks and debounced key levels are modeled.
// No forced PCM, sample strobes, score events, RAM, ACKs or display frame starts.
`define D dut.u_instrument
module tb_song_production_top;
    localparam CPB=8;
    reg sys_clk=0,audio_clk=0,pixel_clk=0,locked=0,audio_running=1,rx=1;
    reg stop_key=0,menu_key=0;
    always #10 sys_clk=~sys_clk;
    initial forever begin #10.172414;if(audio_running)audio_clk=~audio_clk;end
    always #15.151515 pixel_clk=~pixel_clk;
    wire tx,bck,ws,din;
    song_instrument_top #(.CLKS_PER_BIT(CPB)) dut(
        .sys_clk(sys_clk),.key0_n(1'b1),.key1_n(1'b1),.key2_n(1'b1),.setting_key(1'b0),.adc_miso(1'b0),.hc05_rx(rx),
        .adc_sclk(),.adc_mosi(),.adc_cs0_n(),.adc_cs1_n(),.adc_led(),.hc05_tx(tx),.status_led(),.ws2812_data(),.led_enable(),
        .audio_bck(bck),.audio_ws(ws),.audio_din(din),.audio_pa_en_n(),
        .lcd_pclk(),.lcd_hsync(),.lcd_vsync(),.lcd_de(),.lcd_bl(),.lcd_r(),.lcd_g(),.lcd_b());
    integer received=0,checked=0,bit_num,events=0,peak=0,serial_peak=0,magnitude,bit_count=0;
    reg [7:0] bytes[0:4095],decoded;
    reg [63:0] expected[0:3];
    reg [15:0] serial_word=0,frame_pcm=0;
    reg [79:0] previous_display=0;
    reg previous_frame=0,display_seen=0;
    always @(posedge audio_clk)if(`D.audio_internal_reset_n)begin
        if(`D.uploaded_valid && `D.uploaded_ready)begin
            if(events>=4 || {`D.uploaded_on,`D.uploaded_id,`D.uploaded_note,`D.uploaded_octave,`D.uploaded_force,`D.uploaded_melody}
                !=={expected[events][39:10],expected[events][8]})$fatal(1,"production event mismatch %d",events);
            events++;
        end
        if(`D.audio_sample_strobe)begin
            if((^`D.audio_sample)===1'bx)$fatal(1,"unknown production PCM");
            magnitude=$signed(`D.audio_sample)<0?-$signed(`D.audio_sample):$signed(`D.audio_sample);
            if(magnitude>=32767)$fatal(1,"production clipping");
            if(magnitude>peak)peak=magnitude;
            if(`D.uploaded_selected && (`D.pre_effect_audio_sample!==`D.song_audio_sample || `D.poly_tone!=3))
                $fatal(1,"upload bypassed production piano routing");
        end
    end
    always @(posedge bck)if(`D.audio_internal_reset_n && !ws && `D.u_pt8211_tx.bit_index==0)frame_pcm=`D.audio_sample;
    always @(negedge bck)if(`D.audio_internal_reset_n)begin
        serial_word={serial_word[14:0],din};bit_count++;
        if(bit_count==16)begin
            bit_count=0;
            if(`D.audio_stream_ready && serial_word!==frame_pcm)$fatal(1,"physical PT8211 word mismatch");
            magnitude=$signed(serial_word)<0?-$signed(serial_word):$signed(serial_word);
            if(magnitude>serial_peak)serial_peak=magnitude;
        end
    end
    always @(posedge pixel_clk)begin
        if(`D.pixel_internal_reset_n)begin
            if(display_seen && !previous_frame && previous_display!=={`D.u_lcd_test_pattern.upload_active,`D.u_lcd_test_pattern.status_active})
                $fatal(1,"LCD status changed inside a frame old=%h new=%h",previous_display,{`D.u_lcd_test_pattern.upload_active,`D.u_lcd_test_pattern.status_active});
            previous_display={`D.u_lcd_test_pattern.upload_active,`D.u_lcd_test_pattern.status_active};
            previous_frame=`D.lcd_frame_start;display_seen=1;
        end else begin display_seen=0;previous_frame=0;end
    end
    initial forever begin
        @(negedge tx);#(CPB*30);
        for(bit_num=0;bit_num<8;bit_num++)begin decoded[bit_num]=tx;#(CPB*20);end
        if(tx!==1'b1)$fatal(1,"UART stop bit");
        bytes[received]=decoded;received++;
    end
    task automatic send_text(input string request);
        begin for(integer j=0;j<request.len();j++)begin
            @(negedge sys_clk);rx=0;repeat(CPB)@(negedge sys_clk);
            for(integer b=0;b<8;b++)begin rx=request[j][b];repeat(CPB)@(negedge sys_clk);end
            rx=1;repeat(CPB)@(negedge sys_clk);
        end end
    endtask
    task automatic exchange(input string request,input string response);
        integer timeout;
        begin
            send_text(request);timeout=0;
            while(received<checked+response.len())begin @(negedge sys_clk);timeout++;if(timeout>100000)$fatal(1,"missing reply expected=%s",response);end
            for(integer j=0;j<response.len();j++)if(bytes[checked+j]!==response[j])$fatal(1,"reply offset %d got %h want %h expected=%s",j,bytes[checked+j],response[j],response);
            checked+=response.len();repeat(200)@(negedge sys_clk);
            if(received!=checked)$fatal(1,"unexpected duplicate reply");
        end
    endtask
    task silence;
        begin repeat(2200)@(posedge `D.audio_sample_strobe);
        if(`D.audio_sample!=0 || `D.song_held_notes!=0 || `D.polyphony_active_voice_count!=0 || `D.shared_link.endpoint.playback_busy)
            $fatal(1,"stop/completion left stuck audio or RAM ownership");end
    endtask
    task menu_press;
        begin @(negedge audio_clk);menu_key=1;repeat(5)@(negedge audio_clk);menu_key=0;repeat(8)@(negedge audio_clk);end
    endtask
    `include "production_vectors/commands.vh"
    initial begin
        force `D.audio_clk=audio_clk;force `D.pixel_clk=pixel_clk;
        force `D.audio_pll_locked=locked;force `D.lcd_pll_locked=locked;
        force `D.key1_pressed=stop_key;force `D.setting_key_pressed=menu_key;
        $readmemh("sim/upload_vectors/timeline.hex",expected);
        repeat(20)@(negedge sys_clk);locked=1;repeat(20)@(negedge sys_clk);
        exchange("PING\n","PONG\n");exchange("STATUS\n","STATUS,MANUAL\n");
        // Legacy replies now require actual audio-domain execution.
        @(negedge audio_clk);audio_running=0;send_text("PING\n");repeat(1000)@(negedge sys_clk);
        if(received!=checked)$fatal(1,"legacy false ACK with audio clock stopped");
        audio_running=1;exchange("","PONG\n");
        `include "control_vectors/pcm_upload.vh"
        if(events || peak || `D.uploaded_selected)$fatal(1,"upload auto-played");
        play_first();
        wait(events==1);wait(`D.u_lcd_test_pattern.uploaded_song && `D.u_lcd_test_pattern.song_notes_active==12'h001);
        if(`D.u_lcd_test_pattern.song_length!=2 || `D.u_lcd_test_pattern.tempo_bpm!=100 ||
           `D.u_lcd_test_pattern.status_glyph(0,0)!=130 || `D.u_lcd_test_pattern.status_glyph(0,1)!=25)
            $fatal(1,"LCD upload label/length/tempo wrong");
        repeat(30)@(posedge `D.audio_sample_strobe);
        if(peak<30 || serial_peak<30)$fatal(1,"upload silent at production PCM/PT8211 %d/%d",peak,serial_peak);
        exchange("PLAY\n","ERR,LOCAL\n"); // never switch to builtin while upload runs
        exchange("STATUS\n","STATUS,PLAYING,001/002\n");
        stop_first();silence();if(events!=1)$fatal(1,"STOP leaked later events");
        exchange("STATUS\n","STATUS,STOPPED,001/002\n");
        events=0;play_to_end();wait(events==4);wait(!`D.shared_link.endpoint.playback_busy);
        status_finished();silence();
        wait(`D.u_lcd_test_pattern.upload_active==4'b1011);
        if(`D.u_lcd_test_pattern.song_position!=2 || `D.u_lcd_test_pattern.song_length!=2)$fatal(1,"finished LCD progress");
        events=0;play_local_stop();@(negedge audio_clk);stop_key=1;repeat(10)@(negedge audio_clk);stop_key=0;
        status_local_stop();if(events || `D.uploaded_run)$fatal(1,"local stop ignored during launch");
        menu_press();if(!`D.setting_mode || `D.uploaded_selected)$fatal(1,"menu failed ownership exit");
        play_in_menu();
        menu_press();if(`D.setting_mode)$fatal(1,"manual return");
        exchange("PLAY\n","OK,PLAY\n");if(!`D.song_active || `D.uploaded_selected)$fatal(1,"legacy mode switch");
        play_in_builtin();exchange("STOP\n","OK,STOP\n");
        if(!`D.song_done)$fatal(1,"legacy STOP not executed");
        $display("PASS: real full top UART upload -> production piano/effects/PT8211, peak=%d serial=%d; RGB frame-atomic PC song/progress/keys, natural completion, remote/local STOP, menu/builtin rejection and clock-pause ACK",peak,serial_peak);
        $finish;
    end
    initial begin #800000000;$fatal(1,"production top timeout events=%d state=%d",events,`D.uploaded_state);end
endmodule
`undef D
