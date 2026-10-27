`timescale 1ns/1ps
module tb_poly_glide_top;
    reg clk=0,rst=0,run_bank=1,settings=0;
    reg [1:0] glide=3;
    reg [2:0] trigger=0,gate=7;
    wire bck,ws,din;
    integer cycles=0,bits=0,last_frame=-1,frames=0,nonzero=0,checks=0,k;
    reg last_ws=1,have_left=0;
    reg [15:0] word=0,left_word=0;
    reg [31:0] expected[0:31],checked;
    av_top dut(.sys_clk(clk),.key0_n(1'b1),.key1_n(1'b1),.key2_n(1'b1),.setting_key(1'b0),
        .hc05_rx(1'b1),.hc05_tx(),.status_led(),.audio_bck(bck),.audio_ws(ws),.audio_din(din),.audio_pa_en_n(),
        .lcd_pclk(),.lcd_hsync(),.lcd_vsync(),.lcd_de(),.lcd_bl(),.lcd_r(),.lcd_g(),.lcd_b());
    always #5 clk=~clk;
    always @(posedge clk)begin
        cycles=cycles+1;checked=0;
        if(rst && dut.poly_sample_strobe)begin
            for(k=0;k<32;k=k+1)begin
                checked[k]=dut.poly_enable && dut.u_polyphony_bank_32.voice_active[k] &&
                    !dut.u_polyphony_bank_32.voice_stealing[k] &&
                    !(dut.u_polyphony_bank_32.allocate_voice && dut.u_polyphony_bank_32.search_index==k);
                expected[k]=dut.u_polyphony_bank_32.phase_accumulator[k]+dut.u_polyphony_bank_32.expressed_increment[k];
            end
            #2;
            for(k=0;k<32;k=k+1)if(checked[k])begin
                if(dut.u_polyphony_bank_32.phase_accumulator[k]!==expected[k])$fatal(1,"top phase discontinuity");
                checks=checks+1;
            end
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
                    if(last_frame>=0 && cycles-last_frame!=1024)$fatal(1,"DAC cadence");
                    last_frame=cycles;frames=frames+1;
                    if(word!=0)nonzero=nonzero+1;
                end
            end
        end
    end
    task stream;input integer n;integer t;begin
        for(t=0;t<n;t=t+1)begin @(posedge dut.audio_sample_strobe);repeat(350)@(negedge clk);end
    end endtask
    // instrument_control emits a one-audio-clock pulse. A held test level
    // would be re-queued after the sample edge, creating duplicate notes.
    task strike;input [2:0] keys;begin
        @(negedge clk);trigger=keys;@(negedge clk);trigger=0;stream(1);
    end endtask
    initial begin
        force dut.audio_internal_reset_n=rst;
        force dut.test_mode=run_bank;force dut.test_polyphony=1'b1;
        force dut.string_mode=1'b0;force dut.song_active=1'b0;force dut.audition_active=1'b0;
        force dut.setting_mode=settings;force dut.key_play_mute=settings;
        force dut.play_mode=1'b0;force dut.keymap_select=1'b0;force dut.force_value=7'd96;
        force dut.tone_select=2'd3;force dut.octave_select=2'd1;force dut.note_select=4'd0;
        force dut.vibrato_select=2'd0;force dut.glide_select=glide;force dut.key_play_trigger=trigger;
        force dut.key0_pressed=gate[0];force dut.key1_pressed=gate[1];force dut.key2_pressed=gate[2];
        repeat(8)@(negedge clk);rst=1;stream(4);
        strike(1);stream(400);strike(4);
        if(dut.poly_glide!=3 || dut.u_polyphony_bank_32.u_voice_bank[1].glide_left==0)
            $fatal(1,"menu glide not routed: mode=%0d count=%0d next=%0d pending=%b state=%0d history=%b left=%0d",dut.poly_glide,dut.polyphony_active_voice_count,dut.u_polyphony_bank_32.next_voice_index,dut.u_polyphony_bank_32.trigger_pending,dut.u_polyphony_bank_32.allocator_state,dut.u_polyphony_bank_32.last_melody_valid,dut.u_polyphony_bank_32.u_voice_bank[1].glide_left);
        if(dut.u_polyphony_bank_32.expressed_increment[1]>=dut.u_polyphony_bank_32.phase_increment_reg[1])
            $fatal(1,"E did not start below destination");
        stream(17000);
        if(dut.u_polyphony_bank_32.u_voice_bank[1].glide_left!=0 ||
           dut.u_polyphony_bank_32.expressed_increment[1]!==dut.u_polyphony_bank_32.phase_increment_reg[1])
            $fatal(1,"top glide did not settle");
        strike(2);stream(1000);
        if(dut.u_polyphony_bank_32.expressed_increment[2]<=dut.u_polyphony_bank_32.phase_increment_reg[2])
            $fatal(1,"D did not slide down from E");
        glide=0;stream(4);
        if(dut.u_polyphony_bank_32.expressed_increment[2]!==dut.u_polyphony_bank_32.phase_increment_reg[2])
            $fatal(1,"top bypass failed");
        gate=0;stream(30000);
        if(dut.polyphony_active_voice_count!=0 || left_word!=0)$fatal(1,"top release not silent");
        run_bank=0;settings=1;stream(4);run_bank=1;settings=0;glide=3;gate=7;stream(4);strike(4);
        if(dut.u_polyphony_bank_32.u_voice_bank[0].glide_left!=0)$fatal(1,"mode restart retained history");
        if(dut.spectrum_deadline_misses!=0)$fatal(1,"DFT overrun");
        if(frames<45000 || nonzero<5000 || checks<30000)$fatal(1,"insufficient top coverage");
        $display("PASS: production poly glide routing/up/down/off/release/mode restart; phase_checks=%0d stereo_frames=%0d nonzero=%0d; no DFT overrun",checks,frames,nonzero);
        $finish;
    end
    initial begin #650000000;$fatal(1,"timeout");end
    // Stage 30b harness: this bench forces av_top's mode wires directly, which
    // bypasses instrument_control. The three mode decodes are now registered
    // inside that module, so follow the forced wires with the same decode the
    // top level used to build. tb_song_page_mirror proves the registered
    // copies equal this decode on every clock for unforced operation.
    initial begin
        force dut.audition_active = dut.audition_mode && !dut.setting_mode && !dut.test_mode;
        force dut.song_active = dut.audition_mode && !dut.setting_mode && !dut.test_mode && dut.audition_target == 3'd7;
        force dut.self_test_active = dut.test_mode && !dut.setting_mode;
    end
endmodule
