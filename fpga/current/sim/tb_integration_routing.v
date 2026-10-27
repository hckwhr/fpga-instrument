`timescale 1ns/1ps
// Independent frozen top-level expressions prove routing/packing equivalence.
// Clock primitives are the mocks compiled with tb_effects_audition.
module tb_integration_routing;
    reg clk=0,menu=0,testing=0,poly=0,strings=0,armed=0,wet=0,gap=0;
    reg play=0,keymap=0,page=0;
    reg [2:0] target=0,keys=0,preview_keys=0,row=0;
    reg [1:0] strength=1,tone=3,octave=1,glide=0,vibrato=0,effect=0;
    reg [3:0] note=0,manual_note=0;
    reg [6:0] force_level=96,preview_force=32;
    reg [5:0] voices=0;
    reg [7:0] deadlines=0;
    reg signed [15:0] pcm=0;
    integer combination,t,s,k,checks=0;
    always #5 clk=~clk;
    av_top dut(.sys_clk(clk),.key0_n(1'b1),.key1_n(1'b1),.key2_n(1'b1),.setting_key(1'b0),
        .hc05_rx(1'b1),.hc05_tx(),
            .status_led(),.audio_bck(),.audio_ws(),.audio_din(),.audio_pa_en_n(),.lcd_pclk(),.lcd_hsync(),.lcd_vsync(),.lcd_de(),.lcd_bl(),.lcd_r(),.lcd_g(),.lcd_b());
    baseline_integration_top prior(.sys_clk(clk),.key0_n(1'b1),.key1_n(1'b1),.key2_n(1'b1),.setting_key(1'b0),
            .status_led(),.audio_bck(),.audio_ws(),.audio_din(),.audio_pa_en_n(),.lcd_pclk(),.lcd_hsync(),.lcd_vsync(),.lcd_de(),.lcd_bl(),.lcd_r(),.lcd_g(),.lcd_b());
    initial begin
        #100;
        if(dut.u_lcd_test_pattern.DEFAULT_STATUS!==prior.u_lcd_test_pattern.DEFAULT_STATUS)
            $fatal(1,"LCD reset snapshot changed");
        force dut.setting_mode=menu;
        force prior.setting_mode=menu;
        force dut.test_mode=testing;
        force prior.test_mode=testing;
        force dut.test_polyphony=poly;
        force prior.test_polyphony=poly;
        force dut.string_mode=strings;
        force prior.string_mode=strings;
        force dut.audition_mode=armed;
        force prior.audition_mode=armed;
        force dut.audition_target=target;
        force prior.audition_target=target;
        force dut.audition_wet=wet;
        force prior.audition_wet=wet;
        force dut.effect_strength=strength;
        force prior.effect_strength=strength;
        force dut.audition_mute=gap;
        force prior.audition_mute=gap;
        force dut.key0_pressed=keys[0];
        force prior.key0_pressed=keys[0];
        force dut.key1_pressed=keys[1];
        force prior.key1_pressed=keys[1];
        force dut.key2_pressed=keys[2];
        force prior.key2_pressed=keys[2];
        force dut.key_play_trigger=keys;
        force prior.key_play_trigger=keys;
        force dut.audition_trigger=preview_keys;
        force prior.audition_trigger=preview_keys;
        force dut.audition_gates=preview_keys;
        force prior.audition_gates=preview_keys;
        force dut.audition_note=note;
        force prior.audition_note=note;
        force dut.note_select=manual_note;
        force prior.note_select=manual_note;
        force dut.force_value=force_level;
        force prior.force_value=force_level;
        force dut.audition_force=preview_force;
        force prior.audition_force=preview_force;
        force dut.tone_select=tone;
        force prior.tone_select=tone;
        force dut.play_mode=play;
        force prior.play_mode=play;
        force dut.keymap_select=keymap;
        force prior.keymap_select=keymap;
        force dut.octave_select=octave;
        force prior.octave_select=octave;
        force dut.glide_select=glide;
        force prior.glide_select=glide;
        force dut.vibrato_select=vibrato;
        force prior.vibrato_select=vibrato;
        force dut.effect_select=effect;
        force prior.effect_select=effect;
        force dut.selected_field=row;
        force prior.selected_field=row;
        force dut.settings_page=page;
        force prior.settings_page=page;
        force dut.string_voice_count=voices[3:0];
        force prior.string_voice_count=voices[3:0];
        force dut.polyphony_active_voice_count=voices;
        force prior.polyphony_active_voice_count=voices;
        force dut.string_deadline_misses=deadlines;
        force prior.string_deadline_misses=deadlines;
        force dut.raw_audio_sample=pcm;
        force prior.raw_audio_sample=pcm;
        force dut.string_sample=16'sd1234;
        force prior.string_sample=16'sd1234;
        force dut.additive_test_sample=-16'sd2301;
        force prior.additive_test_sample=-16'sd2301;
        force dut.polyphony_test_sample=16'sd3102;
        force prior.polyphony_test_sample=16'sd3102;
        for(combination=0;combination<64;combination=combination+1)
        for(t=0;t<7;t=t+1)for(s=0;s<3;s=s+1)for(k=0;k<8;k=k+1)begin
            {menu,testing,poly,strings,armed,wet}=combination;
            target=t;strength=s;keys=k;preview_keys=~keys;
            gap=k[0];play=k[1];keymap=k[2];page=t[0];row=k;
            note=(k+t)%12;manual_note=(k+2*t)%12;
            octave=t%3;tone=k%4;effect=t%4;glide=k%4;vibrato=t%4;
            force_level=16+k*15;preview_force=32+t*15;
            voices=combination%33;deadlines=combination;
            pcm=-16000+combination*500+k*3;
            // DDS control inputs now cross one coherent register stage.
            // Compare settled ownership against the frozen combinational map.
            @(posedge clk); #2;
            if(dut.self_test_active!==prior.self_test_active) $fatal(1,"routing differs: self_test_active, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.audition_active!==prior.audition_active) $fatal(1,"routing differs: audition_active, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.displayed_voice_count!==prior.displayed_voice_count) $fatal(1,"routing differs: displayed_voice_count, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.displayed_status_payload!==prior.displayed_status_payload) $fatal(1,"routing differs: displayed_status_payload, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.status_payload_cdc_audio!==prior.status_payload_cdc_audio) $fatal(1,"routing differs: status_payload_cdc_audio, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.active_effect_select!==prior.active_effect_select) $fatal(1,"routing differs: active_effect_select, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.pre_effect_audio_sample!==prior.pre_effect_audio_sample) $fatal(1,"routing differs: pre_effect_audio_sample, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.effects_input!==prior.effects_input) $fatal(1,"routing differs: effects_input, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.legacy_voice.u_audio_voice_mixer.voice_trigger!==prior.u_audio_voice_mixer.voice_trigger) $fatal(1,"routing differs: u_audio_voice_mixer.voice_trigger, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.legacy_voice.u_audio_voice_mixer.voice_gate!==prior.u_audio_voice_mixer.voice_gate) $fatal(1,"routing differs: u_audio_voice_mixer.voice_gate, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.legacy_voice.u_audio_voice_mixer.mute!==prior.u_audio_voice_mixer.mute) $fatal(1,"routing differs: u_audio_voice_mixer.mute, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.legacy_voice.u_audio_voice_mixer.play_mode!==prior.u_audio_voice_mixer.play_mode) $fatal(1,"routing differs: u_audio_voice_mixer.play_mode, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.legacy_voice.u_audio_voice_mixer.tone_select!==prior.u_audio_voice_mixer.tone_select) $fatal(1,"routing differs: u_audio_voice_mixer.tone_select, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.legacy_voice.u_audio_voice_mixer.note_select!==prior.u_audio_voice_mixer.note_select) $fatal(1,"routing differs: u_audio_voice_mixer.note_select, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.legacy_voice.u_audio_voice_mixer.keymap_select!==prior.u_audio_voice_mixer.keymap_select) $fatal(1,"routing differs: u_audio_voice_mixer.keymap_select, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.legacy_voice.u_audio_voice_mixer.octave_select!==prior.u_audio_voice_mixer.octave_select) $fatal(1,"routing differs: u_audio_voice_mixer.octave_select, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.legacy_voice.u_audio_voice_mixer.force_value!==prior.u_audio_voice_mixer.force_value) $fatal(1,"routing differs: u_audio_voice_mixer.force_value, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.legacy_voice.u_audio_voice_mixer.bend!==prior.u_audio_voice_mixer.bend) $fatal(1,"routing differs: u_audio_voice_mixer.bend, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.legacy_voice.u_audio_voice_mixer.glide_select!==prior.u_audio_voice_mixer.glide_select) $fatal(1,"routing differs: u_audio_voice_mixer.glide_select, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.legacy_voice.u_audio_voice_mixer.vibrato_depth!==prior.u_audio_voice_mixer.vibrato_depth) $fatal(1,"routing differs: u_audio_voice_mixer.vibrato_depth, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.strings_enabled.u_physical_string_bank.enable!==prior.u_physical_string_bank.enable) $fatal(1,"routing differs: u_physical_string_bank.enable, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.strings_enabled.u_physical_string_bank.voice_trigger!==prior.u_physical_string_bank.voice_trigger) $fatal(1,"routing differs: u_physical_string_bank.voice_trigger, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.strings_enabled.u_physical_string_bank.voice_gate!==prior.u_physical_string_bank.voice_gate) $fatal(1,"routing differs: u_physical_string_bank.voice_gate, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.strings_enabled.u_physical_string_bank.play_mode!==prior.u_physical_string_bank.play_mode) $fatal(1,"routing differs: u_physical_string_bank.play_mode, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.strings_enabled.u_physical_string_bank.keymap_select!==prior.u_physical_string_bank.keymap_select) $fatal(1,"routing differs: u_physical_string_bank.keymap_select, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.strings_enabled.u_physical_string_bank.note_select!==prior.u_physical_string_bank.note_select) $fatal(1,"routing differs: u_physical_string_bank.note_select, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.strings_enabled.u_physical_string_bank.octave_select!==prior.u_physical_string_bank.octave_select) $fatal(1,"routing differs: u_physical_string_bank.octave_select, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.strings_enabled.u_physical_string_bank.force_value!==prior.u_physical_string_bank.force_value) $fatal(1,"routing differs: u_physical_string_bank.force_value, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.u_polyphony_bank_32.enable!==prior.u_polyphony_bank_32.enable) $fatal(1,"routing differs: u_polyphony_bank_32.enable, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.u_polyphony_bank_32.voice_trigger!==prior.u_polyphony_bank_32.voice_trigger) $fatal(1,"routing differs: u_polyphony_bank_32.voice_trigger, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.u_polyphony_bank_32.voice_gate!==prior.u_polyphony_bank_32.voice_gate) $fatal(1,"routing differs: u_polyphony_bank_32.voice_gate, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.u_polyphony_bank_32.play_mode!==prior.u_polyphony_bank_32.play_mode) $fatal(1,"routing differs: u_polyphony_bank_32.play_mode, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.u_polyphony_bank_32.tone_select!==prior.u_polyphony_bank_32.tone_select) $fatal(1,"routing differs: u_polyphony_bank_32.tone_select, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.u_polyphony_bank_32.note_select!==prior.u_polyphony_bank_32.note_select) $fatal(1,"routing differs: u_polyphony_bank_32.note_select, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.u_polyphony_bank_32.keymap_select!==prior.u_polyphony_bank_32.keymap_select) $fatal(1,"routing differs: u_polyphony_bank_32.keymap_select, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.u_polyphony_bank_32.octave_select!==prior.u_polyphony_bank_32.octave_select) $fatal(1,"routing differs: u_polyphony_bank_32.octave_select, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.u_polyphony_bank_32.force_value!==prior.u_polyphony_bank_32.force_value) $fatal(1,"routing differs: u_polyphony_bank_32.force_value, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.additive_enabled.u_additive_bank_32.enable!==prior.u_additive_bank_32.enable) $fatal(1,"routing differs: u_additive_bank_32.enable, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            if(dut.u_audio_effects.mute!==prior.u_audio_effects.mute) $fatal(1,"routing differs: u_audio_effects.mute, flags=%0d target=%0d strength=%0d keys=%0d",combination,t,s,k);
            checks=checks+1;
        end
        $display("PASS: %0d source/mode/target/strength/key combinations match frozen top routing, renderer inputs and LCD snapshots",checks);
        $finish;
    end
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
