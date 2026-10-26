`timescale 1ns/1ps
// Virtual control values; production waveguides, effect input, divider and DAC.
// The reference never switches: its live rendered signal is the fade oracle.
module tb_effect_transition_top;
    reg clk=0,rst=0,settings=0;
    reg [2:0] trigger=0,gate=0;
    reg [1:0] mode=0,strength=1,old_mode=0,old_strength=1;
    reg signed [7:0] bend=32;
    wire bck,ws,din;
    wire signed [15:0] reference_pcm;
    integer m,i,j,phase,expected,checks=0,full_slots=0,changed_samples=0;
    integer cycles=0,frames=0,nonzero=0,bits=0,last_frame=-1,peak=0;
    reg last_ws=1,have_left=0;
    reg [15:0] word=0,left_word=0;
    reg signed [15:0] last_rendered=0;

    av_top #(.SCORE_PLAYBACK_ENABLE(1)) dut(.sys_clk(clk),.key0_n(1'b1),.key1_n(1'b1),.key2_n(1'b1),.setting_key(1'b0),
        .hc05_rx(1'b1),.hc05_tx(),.status_led(),.audio_bck(bck),.audio_ws(ws),.audio_din(din),.audio_pa_en_n(),
        .lcd_pclk(),.lcd_hsync(),.lcd_vsync(),.lcd_de(),.lcd_bl(),.lcd_r(),.lcd_g(),.lcd_b());
    stage22_audio_effects reference(.clk(clk),.reset_n(rst),
        .sample_strobe(dut.audio_sample_strobe),.mute(settings),
        .effect_select(old_mode),.effect_strength(old_strength),
        .sample_in(dut.effects_input),.sample_out(reference_pcm));
    always #5 clk=~clk;
    always @(posedge clk) begin
        cycles=cycles+1;
        if(rst && dut.audio_sample_strobe && !settings) begin
            if(dut.string_voice_count==8)full_slots=full_slots+1;
            if(dut.string_deadline_misses!=0 || dut.spectrum_deadline_misses!=0)
                $fatal(1,"production sample deadline missed");
        end
    end
    always @(negedge bck or negedge rst) begin
        if(!rst)begin bits=0;last_ws=1;have_left=0;last_frame=-1;end
        else begin
            if(ws!=last_ws)begin bits=1;word={15'd0,din};last_ws=ws;end
            else begin bits=bits+1;word={word[14:0],din};end
            if(bits==16)begin
                if((^word)===1'bx || word==16'h7fff || word==16'h8000)
                    $fatal(1,"invalid/clipped DAC output");
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
    task slot;begin
        @(posedge dut.audio_sample_strobe);repeat(32)@(negedge clk);
        if((^dut.audio_sample)===1'bx)$fatal(1,"unknown effect output");
    end endtask
    task strike;input [2:0] keys;begin
        @(negedge clk);trigger=keys;gate=keys;
        @(negedge clk);trigger=0;repeat(96)slot();
    end endtask
    task scaled_check;input integer gain;begin
        // Reference dry bypass is live, while transition output is sampled.
        // rendered is the old effect's correctly sampled value for every mode.
        expected=($signed(reference.rendered)*gain)>>>7;
        if(dut.audio_sample!==expected || dut.u_audio_effects.level!==gain)
            $fatal(1,"top fade mismatch mode=%0d gain=%0d actual=%0d expected=%0d",
                old_mode,gain,dut.audio_sample,expected);
        if(reference.rendered!=last_rendered)changed_samples=changed_samples+1;
        last_rendered=reference.rendered;checks=checks+1;
    end endtask
    initial begin
        force dut.audio_internal_reset_n=rst;
        force dut.test_mode=1'b0;force dut.string_mode=1'b1;force dut.audition_mode=1'b0;
        force dut.setting_mode=settings;force dut.key_play_mute=settings;
        force dut.play_mode=1'b1;force dut.keymap_select=1'b1;force dut.force_value=7'd110;
        force dut.effect_select=mode;force dut.effect_strength=strength;
        force dut.octave_select=2'd1;force dut.note_select=4'd0;
        force dut.vibrato_select=2'd3;force dut.glide_select=2'd0;
        force dut.performance_bend=bend;force dut.key_play_trigger=trigger;
        force dut.key0_pressed=gate[0];force dut.key1_pressed=gate[1];force dut.key2_pressed=gate[2];
        // Upload playback must ignore a previously selected manual delay/reverb;
        // leaving upload must restore the user's selection, not overwrite it.
        force dut.uploaded_selected=1'b0;
        force dut.audition_active=1'b0;force dut.self_test_active=1'b0;
        for(m=0;m<4;m=m+1)begin
            mode=m;#1;
            if(dut.active_effect_select!==mode)$fatal(1,"manual effect selection lost");
            force dut.uploaded_selected=1'b1;#1;
            if(dut.u_audio_effects.effect_select!==2'd0)$fatal(1,"uploaded score inherited manual effect");
            force dut.uploaded_selected=1'b0;#1;
            if(dut.active_effect_select!==mode)$fatal(1,"manual effect was not restored");
        end
        release dut.uploaded_selected;release dut.audition_active;release dut.self_test_active;
        for(m=0;m<4;m=m+1)begin
            rst=0;settings=0;gate=0;mode=m;old_mode=m;strength=m%3;old_strength=m%3;
            repeat(8)@(negedge clk);rst=1;repeat(300)slot();
            strike(1);strike(2);
            // Warm the real delay/reverb history while keeping eight strings live.
            for(j=0;j<7;j=j+1)begin
                repeat(904)slot();strike(1<<(j%3));
            end
            if(dut.string_voice_count!=8 || dut.u_audio_effects.level!=128 ||
               dut.u_audio_effects.rendered!==reference.rendered)
                $fatal(1,"initial source/effect state not covered");
            phase=m==0?0:m==1?7:m==2?511:1000;
            @(negedge dut.audio_sample_strobe);@(negedge clk);
            repeat(phase)@(negedge clk);
            mode=(m+1)%4;
            for(i=0;i<128;i=i+1)begin
                slot();scaled_check(127-i);
                if(dut.u_audio_effects.active_mode!==old_mode)
                    $fatal(1,"early mode commit");
            end
            slot();
            if(dut.audio_sample!=0 || dut.u_audio_effects.level!=0 ||
               dut.u_audio_effects.active_mode!==mode || dut.u_audio_effects.filled!=0)
                $fatal(1,"zero-gain commit failed");
            repeat(300)slot();
            if(dut.u_audio_effects.level!=128)$fatal(1,"new effect did not fade in");
            // Menu stop overrides a second transition and removes all old notes.
            strength=(strength+1)%3;repeat(31)slot();settings=1;gate=0;
            repeat(300)slot();
            if(dut.string_voice_count!=0 || dut.audio_sample!=0 || left_word!=0)
                $fatal(1,"menu mute failed");
            settings=0;repeat(300)slot();
            if(dut.audio_sample!=0 || left_word!=0 || dut.string_voice_count!=0)
                $fatal(1,"old notes/history leaked after menu");
            strike(4);
            if(dut.string_voice_count!=4)$fatal(1,"fresh restart failed");
        end
        if(checks!=512 || changed_samples<400 || full_slots<10000 || nonzero<10000 || peak==0)
            $fatal(1,"insufficient integration coverage");
        $display("METRICS exact_fade_samples=%0d changing_reference_samples=%0d full_slots=%0d stereo_frames=%0d nonzero=%0d peak=%0d",
            checks,changed_samples,full_slots,frames,nonzero,peak);
        $display("PASS: real eight-string bend/vibrato plus four effect fades at phases 0/7/511/1000; exact live PCM fade, zero commit, menu interruption/restart, DAC cadence and deadlines");
        $finish;
    end
    initial begin #500000000;$fatal(1,"integration timeout");end
endmodule
