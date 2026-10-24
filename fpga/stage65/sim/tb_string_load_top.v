`timescale 1ns/1ps
// Virtual menu/key controls only; real sample divider, production mixer and DAC.
module tb_string_load_top;
    reg clk=0,rst=0,settings=0;
    reg [2:0] trigger=0,gate=0;
    reg [3:0] note=0;
    reg [1:0] octave=1;
    wire bck,ws,din;
    integer cycles=0,bits=0,last_frame=-1,frames=0,nonzero=0,peak=0;
    integer full_frames=0,requests=0,j,old_writes,writes=0;
    reg last_ws=1,have_left=0;
    reg [15:0] word=0,left_word=0;
    av_top dut(.sys_clk(clk),.key0_n(1'b1),.key1_n(1'b1),.key2_n(1'b1),.setting_key(1'b0),
        .hc05_rx(1'b1),.hc05_tx(),.status_led(),.audio_bck(bck),.audio_ws(ws),.audio_din(din),.audio_pa_en_n(),
        .lcd_pclk(),.lcd_hsync(),.lcd_vsync(),.lcd_de(),.lcd_bl(),.lcd_r(),.lcd_g(),.lcd_b());
    always #5 clk=~clk;
    always @(posedge clk)begin
        cycles=cycles+1;
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
        force dut.vibrato_select=2'd0;force dut.glide_select=2'd0;force dut.key_play_trigger=trigger;
        force dut.key0_pressed=gate[0];force dut.key1_pressed=gate[1];force dut.key2_pressed=gate[2];
        repeat(8)@(negedge clk);rst=1;stream(8);
        strike(1);strike(2);if(dut.string_voice_count!=8)$fatal(1,"top did not reach eight voices");
        stream(1500);
        for(j=0;j<36;j=j+1)begin note=j%12;octave=j/12;strike(1<<(j%3));end
        stream(1500);
        settings=1;stream(300);
        if(dut.string_voice_count!=0 || left_word!=0)$fatal(1,"settings mute failed");
        settings=0;gate=0;stream(8);
        if(dut.string_voice_count!=0 || left_word!=0)$fatal(1,"stale notes after menu");
        strike(4);if(dut.string_voice_count!=4)$fatal(1,"top restart failed");
        if(frames<6000 || nonzero<3000 || full_frames<3000 || peak==0)$fatal(1,"insufficient top coverage");
        $display("METRICS stereo_frames=%0d nonzero_frames=%0d eight_voice_slots=%0d peak_pcm=%0d chord_requests=%0d writes=%0d",frames,nonzero,full_frames,peak,requests,writes);
        $display("PASS: production eight-string load, PT8211 stereo/cadence/headroom, display count payload, menu cancel/restart, no string or DFT deadline miss");
        $finish;
    end
    initial begin #110000000;$fatal(1,"timeout");end
endmodule
