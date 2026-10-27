`timescale 1ns/1ps
// Compare every audio clock against the original unregistered DDS boundary,
// including controls/events that change immediately before a sample edge.
module tb_dds_control_pipeline;
    reg clk=0, strobe=0, mute=1, mode=0, keymap=0;
    reg [2:0] trigger=0, gate=0;
    reg [1:0] tone=3, octave=1, glide=0;
    reg [3:0] note=0;
    reg [6:0] force_level=96;
    reg signed [7:0] bend=0;
    reg [7:0] vibrato=0;
    reg [31:0] random_state=32'h13456789;
    wire signed [15:0] reference_sample;
    reg signed [15:0] expected;
    integer cycle, checks=0, nonzero=0;
    always #5 clk=~clk;
    av_top dut(.sys_clk(clk),.key0_n(1'b1),.key1_n(1'b1),.key2_n(1'b1),.setting_key(1'b0),
        .hc05_rx(1'b1),.hc05_tx(),
        .status_led(),.audio_bck(),.audio_ws(),.audio_din(),.audio_pa_en_n(),
        .lcd_pclk(),.lcd_hsync(),.lcd_vsync(),.lcd_de(),.lcd_bl(),.lcd_r(),.lcd_g(),.lcd_b());
    audio_voice_mixer reference(.song_release(1'b0),.clk(clk),.reset_n(dut.audio_internal_reset_n),
        .sample_strobe(strobe),.voice_trigger(trigger),.voice_gate(gate),.mute(mute),
        .play_mode(mode),.tone_select(tone),.note_select(note),.keymap_select(keymap),
        .octave_select(octave),.force_value(force_level),.glide_select(glide),
        .vibrato_depth(vibrato),.bend(bend),.sample(reference_sample));
    initial begin
        force dut.audio_sample_strobe=strobe;
        force dut.key_play_mute=mute;
        force dut.string_mode=0;
        force dut.audition_mode=0;
        force dut.routed_voice_trigger=trigger; force dut.routed_voice_gate=gate;
        force dut.routed_play_mode=mode; force dut.routed_tone=tone;
        force dut.routed_note=note; force dut.routed_keymap=keymap;
        force dut.routed_octave=octave; force dut.routed_force=force_level;
        force dut.routed_bend=bend; force dut.routed_glide=glide;
        force dut.routed_vibrato=vibrato;
        repeat(32) @(negedge clk);
        for(cycle=0;cycle<160000;cycle=cycle+1) begin
            @(negedge clk);
            strobe=(cycle%16==0);
            trigger=0;
            // Long enough phrases to exercise nonzero ADSR output; updates
            // deliberately straddle sample edges as well as idle clocks.
            if(cycle%257==0) begin
                random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
                {mode,keymap,tone,octave}=random_state[5:0];
                note=random_state[9:6]%12;
                force_level=32+random_state[15:10];
                gate=random_state[18:16]; trigger=random_state[21:19];
                bend=random_state[29:22]; vibrato=random_state[23:16]&8'h7f;
                glide=random_state[31:30]; mute=(random_state[14:10]==0);
            end
            @(posedge clk);
            expected=reference_sample;
            #1;
            if(dut.raw_audio_sample!==expected)
                $fatal(1,"DDS coherent pipeline differs at cycle %0d: actual=%0d expected=%0d",cycle,dut.raw_audio_sample,expected);
            if(dut.raw_audio_sample!=0)nonzero=nonzero+1;
            checks=checks+1;
        end
        if(nonzero<10000)$fatal(1,"insufficient nonzero pipeline coverage");
        $display("PASS: %0d clock-by-clock DDS pipeline equivalence checks across trigger, gate, mute, pitch, force and expression changes",checks);
        $finish;
    end
endmodule
