`timescale 1ns/1ps
// Virtual menu/key controls only; real sample divider, production mixer and DAC.
module tb_string_expression_top;
    reg clk=0,rst=0,settings=0;
    reg [2:0] trigger=0,gate=0;
    reg [3:0] note=0;
    reg [1:0] octave=1;
    reg [1:0] vibrato=3;
    reg sensor=0,frame_valid=0;
    reg [9:0] sensor_x=512,sensor_y=512;
    integer fractional_updates=0,max_busy_clocks=0,busy_clocks=0;
    reg [20:0] previous_delay[0:7];
    genvar lane;
    wire bck,ws,din;
    integer cycles=0,bits=0,last_frame=-1,frames=0,nonzero=0,peak=0;
    integer full_frames=0,requests=0,j,old_writes,writes=0;
    reg last_ws=1,have_left=0;
    reg [15:0] word=0,left_word=0;
    av_top dut(.sys_clk(clk),.key0_n(1'b1),.key1_n(1'b1),.key2_n(1'b1),.setting_key(1'b0),
        .hc05_rx(1'b1),.hc05_tx(),.status_led(),.audio_bck(bck),.audio_ws(ws),.audio_din(din),.audio_pa_en_n(),
        .lcd_pclk(),.lcd_hsync(),.lcd_vsync(),.lcd_de(),.lcd_bl(),.lcd_r(),.lcd_g(),.lcd_b());
    always #5 clk=~clk;
    generate for(lane=0;lane<8;lane=lane+1)begin: delay_checks
        always @(posedge clk) if(rst && dut.audio_sample_strobe && !settings &&
            dut.strings_enabled.u_physical_string_bank.strings[lane].voice.active &&
            !dut.strings_enabled.u_physical_string_bank.strings[lane].voice.pending)begin
            previous_delay[lane]=dut.strings_enabled.u_physical_string_bank.strings[lane].voice.delay_q12;
            #2;
            if(dut.strings_enabled.u_physical_string_bank.strings[lane].voice.delay_q12>previous_delay[lane]+dut.strings_enabled.u_physical_string_bank.strings[lane].voice.slew_step ||
               dut.strings_enabled.u_physical_string_bank.strings[lane].voice.delay_q12+dut.strings_enabled.u_physical_string_bank.strings[lane].voice.slew_step<previous_delay[lane])
                $fatal(1,"top delay jumped lane %0d",lane);
        end
    end endgenerate
    always @(posedge clk)begin
        cycles=cycles+1;
        if(rst)begin
            if(|dut.strings_enabled.u_physical_string_bank.busy)busy_clocks=busy_clocks+1;
            else begin
                if(busy_clocks>max_busy_clocks)max_busy_clocks=busy_clocks;
                busy_clocks=0;
            end
            if(dut.strings_enabled.u_physical_string_bank.strings[0].voice.state==21)fractional_updates=fractional_updates+1;
        end
        if(rst && dut.strings_enabled.u_physical_string_bank.enable && dut.strings_enabled.u_physical_string_bank.state==4)writes=writes+1;
        if(rst && dut.audio_sample_strobe && !settings)begin
            if(dut.string_voice_count==8)full_frames=full_frames+1;
            if(dut.status_payload_cdc_audio[33:28]!=={2'd0,dut.string_voice_count} ||
               !dut.status_payload_cdc_audio[34])$fatal(1,"display status disagrees with string bank");
            if(dut.string_deadline_misses!=0 || dut.spectrum_deadline_misses!=0)$fatal(1,"production deadline miss");
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
                    if(last_frame>=0 && cycles-last_frame!=1024)$fatal(1,"DAC cadence changed");
                    last_frame=cycles;frames=frames+1;
                    if(word!=0)nonzero=nonzero+1;
                    if(($signed(word)<0?-$signed(word):$signed(word))>peak)
                        peak=$signed(word)<0?-$signed(word):$signed(word);
                end
            end
        end
    end
    task stream;input integer n;integer t;begin
        for(t=0;t<n;t=t+1)begin @(posedge dut.audio_sample_strobe);repeat(350)@(negedge clk);end
    end endtask
    task strike;input [2:0] keys;begin
        old_writes=writes;
        @(negedge clk);trigger=keys;gate=keys;@(negedge clk);trigger=0;stream(96);
        if(writes-old_writes!=4)$fatal(1,"top chord lost/repeated");
        requests=requests+1;
    end endtask
    initial begin
        force dut.audio_internal_reset_n=rst;
        force dut.test_mode=1'b0;force dut.string_mode=1'b1;force dut.audition_mode=1'b0;
        force dut.setting_mode=settings;force dut.key_play_mute=settings;
        force dut.play_mode=1'b1;force dut.keymap_select=1'b1;force dut.force_value=7'd127;
        force dut.effect_select=2'd0;force dut.octave_select=octave;force dut.note_select=note;
        force dut.vibrato_select=vibrato;force dut.glide_select=2'd0;force dut.key_play_trigger=trigger;
        force dut.u_performance_controls.sensor_enable=sensor;
        force dut.u_performance_controls.frame_valid=frame_valid;
        force dut.u_performance_controls.x_raw=sensor_x;
        force dut.u_performance_controls.y_raw=sensor_y;
        force dut.u_performance_controls.force_raw=10'd1000;
        force dut.key0_pressed=gate[0];force dut.key1_pressed=gate[1];force dut.key2_pressed=gate[2];
        repeat(8)@(negedge clk);rst=1;stream(8);
        strike(1);strike(2);if(dut.string_voice_count!=8)$fatal(1,"top did not reach eight voices");
        stream(1500);
        for(j=0;j<36;j=j+1)begin
            if(j==8)begin sensor=1;frame_valid=1;sensor_x=1023;sensor_y=1023;end
            if(j==16)begin sensor_x=0;sensor_y=512;end
            if(j==24)frame_valid=0;
            note=j%12;octave=j/12;strike(1<<(j%3));
        end
        stream(5200);
        if(dut.u_performance_controls.sensor_ready || dut.performance_bend!=0)$fatal(1,"sensor timeout did not recover");
        if(dut.performance_vibrato!=128)$fatal(1,"manual vibrato fallback lost");
        sensor=0;vibrato=0;stream(512);
        if(dut.strings_enabled.u_physical_string_bank.delay_delta!=0)$fatal(1,"expression off not neutral");
        settings=1;stream(300);
        if(dut.string_voice_count!=0 || left_word!=0)$fatal(1,"settings mute failed");
        settings=0;gate=0;stream(8);
        if(dut.string_voice_count!=0 || left_word!=0)$fatal(1,"stale notes after menu");
        strike(4);if(dut.string_voice_count!=4)$fatal(1,"top restart failed");
        if(frames<10000 || nonzero<3000 || full_frames<3000 || peak==0 || fractional_updates<1000 || max_busy_clocks>512)$fatal(1,"insufficient top coverage or deadline");
        $display("METRICS stereo_frames=%0d nonzero_frames=%0d eight_voice_slots=%0d peak_pcm=%0d chord_requests=%0d writes=%0d fractional_updates=%0d max_busy_clocks=%0d",frames,nonzero,full_frames,peak,requests,writes,fractional_updates,max_busy_clocks);
        $display("PASS: production eight-string expression, virtual ADC bend/timeout/fallback, manual vibrato/off, bounded delay, PT8211 cadence/headroom, display payload, restart and deadlines");
        $finish;
    end
    initial begin #150000000;$fatal(1,"timeout");end
endmodule
