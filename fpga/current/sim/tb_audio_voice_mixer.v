`timescale 1ns/1ps
`default_nettype none

module tb_audio_voice_mixer;

    reg clk;
    reg reset_n;
    reg sample_strobe;
    reg [2:0] key_pressed;
    reg setting_pressed;

    wire [2:0] play_trigger;
    wire play_mute;
    wire setting_mode;
    wire settings_page;
    wire [2:0] selected_field;
    wire play_mode;
    wire [1:0] tone_select;
    wire string_mode;
    wire [3:0] note_select;
    wire [6:0] force_value;
    wire keymap_select;
    wire [1:0] octave_select;
    wire [1:0] effect_select;
    wire test_mode;
    wire test_polyphony;
    wire [27:0] status_payload;
    wire signed [15:0] sample;

    integer error_count;
    integer sample_index;
    integer peak_sample;
    integer sample_abs;
    integer combo_trigger_count;

    instrument_control #(
        .PLAY_GUARD_CYCLES(3),
        .PLAY_GUARD_COUNTER_WIDTH(2)
    ) u_instrument_control (
        .clk           (clk),
        .reset_n       (reset_n),
        .key_pressed   (key_pressed),
        .setting_pressed(setting_pressed),
        .remote_song_start(1'b0), .song_select(), .song_change(), .song_tempo(), .song_accompaniment(),
        .play_trigger  (play_trigger),
        .play_mute     (play_mute),
        .setting_mode  (setting_mode),
        .settings_page (settings_page),
        .selected_field(selected_field),
        .play_mode     (play_mode),
        .tone_select   (tone_select),
        .string_mode   (string_mode),
        .note_select   (note_select),
        .force_value   (force_value),
        .keymap_select (keymap_select),
        .octave_select (octave_select),
        .effect_select (effect_select),
        .glide_select(), .vibrato_select(), .effect_strength(), .audition_mode(), .audition_target(),
        .test_mode     (test_mode),
        .test_polyphony(test_polyphony),
        .status_payload(status_payload)
    );

    audio_voice_mixer #(
        .ATTACK_STEP(8'd64),
        .DECAY_INTERVAL_LAST(8'd3),
        .ADSR_DECAY_INTERVAL_LAST(8'd0),
        .TOUCH_RELEASE_INTERVAL_LAST(8'd0)
    ) u_audio_voice_mixer (.song_release(1'b0),
        .glide_select(2'd0), .vibrato_depth(8'd0), .bend(8'sd0),
        .clk          (clk),
        .reset_n      (reset_n),
        .sample_strobe(sample_strobe),
        .voice_trigger(play_trigger),
        .voice_gate   (key_pressed),
        .mute         (play_mute),
        .play_mode    (play_mode),
        .tone_select  (tone_select),
        .note_select  (note_select),
        .keymap_select(keymap_select),
        .octave_select(octave_select),
        .force_value  (force_value),
        .sample       (sample)
    );

    always #5 clk = ~clk;

    task clock_once;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task pulse_sample;
        begin
            sample_strobe = 1'b1;
            clock_once();
            sample_strobe = 1'b0;
        end
    endtask

    task apply_reset;
        begin
            reset_n = 1'b0;
            sample_strobe = 1'b0;
            key_pressed = 3'b000;
            setting_pressed = 1'b0;
            repeat (3) clock_once();
            reset_n = 1'b1;
            clock_once();
        end
    endtask

    task expect;
        input condition;
        input [8*80-1:0] message;
        begin
            if (!condition) begin
                $display("ERROR: %0s", message);
                error_count = error_count + 1;
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        reset_n = 1'b0;
        sample_strobe = 1'b0;
        key_pressed = 3'b000;
        setting_pressed = 1'b0;
        error_count = 0;

        apply_reset();
        expect(sample == 16'sd0, "idle output must be zero");
        expect(tone_select == 2'd3, "default tone is not the new soft keyboard");

        key_pressed = 3'b001;
        repeat (4) clock_once();
        expect(play_trigger == 3'b001, "KEY0 did not trigger the I chord");
        pulse_sample();
        expect(u_audio_voice_mixer.active_voice_count == 3'd4,
               "one KEY0 press did not start four chord voices");
        expect(u_audio_voice_mixer.voice0_phase_increment == 32'd23_409_859,
               "I chord root is not C4");
        expect(u_audio_voice_mixer.voice1_phase_increment == 32'd29_494_575,
               "I chord third is not E4");
        expect(u_audio_voice_mixer.voice2_phase_increment == 32'd35_075_158,
               "I chord fifth is not G4");
        expect(u_audio_voice_mixer.voice3_phase_increment == 32'd46_819_718,
               "I chord octave is not C5");
        key_pressed = 3'b000;
        clock_once();

        apply_reset();
        key_pressed = 3'b010;
        repeat (4) clock_once();
        expect(play_trigger == 3'b010, "KEY1 did not trigger the IV chord");
        pulse_sample();
        expect(u_audio_voice_mixer.active_voice_count == 3'd4,
               "one KEY1 press did not start four chord voices");
        expect(u_audio_voice_mixer.voice0_phase_increment == 32'd31_248_413,
               "IV chord root is not F4");
        expect(u_audio_voice_mixer.voice1_phase_increment == 32'd39_370_534,
               "IV chord third is not A4");
        expect(u_audio_voice_mixer.voice2_phase_increment == 32'd46_819_718,
               "IV chord fifth is not C5");
        expect(u_audio_voice_mixer.voice3_phase_increment == 32'd62_496_826,
               "IV chord octave is not F5");
        key_pressed = 3'b000;
        clock_once();

        apply_reset();
        key_pressed = 3'b100;
        repeat (4) clock_once();
        expect(play_trigger == 3'b100, "KEY2 did not trigger the V chord");
        pulse_sample();
        expect(u_audio_voice_mixer.active_voice_count == 3'd4,
               "one KEY2 press did not start four chord voices");
        expect(u_audio_voice_mixer.voice0_phase_increment == 32'd35_075_158,
               "V chord root is not G4");
        expect(u_audio_voice_mixer.voice1_phase_increment == 32'd44_191_930,
               "V chord third is not B4");
        expect(u_audio_voice_mixer.voice2_phase_increment == 32'd52_553_358,
               "V chord fifth is not D5");
        expect(u_audio_voice_mixer.voice3_phase_increment == 32'd70_150_316,
               "V chord octave is not G5");
        key_pressed = 3'b000;
        clock_once();

        key_pressed = 3'b010;
        clock_once();
        expect(play_trigger == 3'b000, "KEY1 bypassed the chord collection window");
        key_pressed = 3'b011;
        clock_once();
        expect(play_trigger == 3'b000, "staggered chord triggered too early");
        key_pressed = 3'b000;
        clock_once();
        expect(play_trigger == 3'b000, "chord collection window ended early");
        clock_once();
        expect(play_trigger == 3'b011, "near-simultaneous keys were not triggered together");

        apply_reset();
        key_pressed = 3'b111;
        clock_once();
        expect(play_mute == 1'b0, "short full chord was muted by settings gesture");
        expect(play_trigger == 3'b000, "full chord bypassed the collection window");
        repeat (2) clock_once();
        expect(play_trigger == 3'b000, "full chord collection window ended early");
        clock_once();
        expect(play_trigger == 3'b111, "full three-key chord did not trigger together");
        pulse_sample();
        expect(u_audio_voice_mixer.voice3_gain != 8'd0,
               "full chord did not keep the fourth independent voice");
        expect(u_audio_voice_mixer.active_voice_count == 3'd4,
               "full chord did not produce four concurrent voices");
        expect(u_audio_voice_mixer.voice3_requested_gain == 8'd96,
               "octave-root voice was not reduced to half gain");
        key_pressed = 3'b000;
        clock_once();

        apply_reset();
        combo_trigger_count = 0;
        key_pressed = 3'b101;
        repeat (5) begin
            clock_once();
            if (play_trigger == 3'b101)
                combo_trigger_count = combo_trigger_count + 1;
        end
        expect(combo_trigger_count == 1,
               "root-fifth chord did not remain available after adding setting key");
        expect(setting_mode == 1'b0, "root-fifth chord incorrectly entered settings mode");
        key_pressed = 3'b000;
        clock_once();
        setting_pressed = 1'b1;
        clock_once();
        setting_pressed = 1'b0;
        clock_once();
        expect(setting_mode == 1'b1, "S2 did not enter settings mode");
        expect(play_mute == 1'b1, "settings mode did not mute audio");
        expect(play_trigger == 3'b000, "S2 emitted a play trigger");
        expect(selected_field == 3'd7 && !settings_page, "settings did not start on basic tabs");
        key_pressed = 3'b001; clock_once();
        key_pressed = 0; clock_once();
        expect(play_mode == 1'b1, "reset mode must default to pluck");
        expect(keymap_select == 1'b1, "reset keymap must default to chord");
        expect(octave_select == 2'd1, "reset octave must default to middle");
        expect(u_audio_voice_mixer.voice0_phase_increment == 32'd23_409_859,
               "middle-octave root frequency is incorrect");
        expect(u_audio_voice_mixer.voice1_phase_increment == 32'd29_494_575,
               "chord third frequency is incorrect");
        expect(u_audio_voice_mixer.voice2_phase_increment == 32'd35_075_158,
               "chord fifth frequency is incorrect");
        expect(u_audio_voice_mixer.voice3_phase_increment == 32'd46_819_718,
               "fourth voice is not the independent octave root");

        key_pressed = 3'b010;
        clock_once();
        expect(play_trigger == 3'b000, "settings key emitted a play trigger");
        expect(play_mode == 1'b0, "settings key did not select touch mode");
        key_pressed = 3'b000;
        clock_once();

        key_pressed = 3'b001;
        clock_once();
        expect(selected_field == 3'd1, "KEY0 did not advance to tone field");
        key_pressed = 3'b000;
        clock_once();

        key_pressed = 3'b010;
        clock_once();
        expect(tone_select == 2'd2, "settings KEY1 did not decrement tone with wrap");
        key_pressed = 3'b000;
        clock_once();

        repeat (5) begin
            key_pressed = 3'b100; clock_once();
            key_pressed = 0; clock_once();
        end
        expect(tone_select == 2'd2 && !string_mode, "five timbres did not wrap through the menu");
        key_pressed=3'b100; clock_once(); key_pressed=0; clock_once();
        key_pressed=3'b100; clock_once(); key_pressed=0; clock_once();
        expect(string_mode && !test_mode,"physical string timbre was not selected");
        key_pressed=3'b010; clock_once(); key_pressed=0; clock_once();
        expect(!string_mode && tone_select==3,"string decrement did not restore piano");
        key_pressed=3'b010; clock_once(); key_pressed=0; clock_once();

        repeat (3) begin
            key_pressed = 3'b001;
            clock_once();
            key_pressed = 3'b000;
            clock_once();
        end
        expect(selected_field == 3'd4, "KEY0 did not advance to keymap field");

        key_pressed = 3'b010;
        clock_once();
        key_pressed = 3'b000;
        clock_once();
        expect(keymap_select == 1'b0, "keymap did not switch to melody");
        expect(u_audio_voice_mixer.voice1_phase_increment == 32'd26_276_679,
               "melody KEY1 frequency is not the major second");
        expect(u_audio_voice_mixer.voice2_phase_increment == 32'd29_494_575,
               "melody KEY2 frequency is not the major third");

        key_pressed = 3'b001;
        clock_once();
        key_pressed = 3'b000;
        clock_once();
        expect(selected_field == 3'd5, "KEY0 did not advance to octave field");

        key_pressed = 3'b100;
        clock_once();
        key_pressed = 3'b000;
        clock_once();
        expect(octave_select == 2'd2, "octave did not switch to high");
        expect(u_audio_voice_mixer.voice0_phase_increment == 32'd46_819_718,
               "high-octave root frequency is incorrect");

        key_pressed = 3'b001;
        clock_once();
        key_pressed = 3'b000;
        clock_once();
        expect(selected_field == 3'd7, "basic navigation did not wrap to tabs");
        key_pressed = 3'b100; clock_once(); key_pressed = 0; clock_once();
        key_pressed = 3'b001; clock_once(); key_pressed = 0; clock_once();
        expect(settings_page && selected_field == 0, "extension effect row was not selected");
        expect(effect_select == 2'd0, "effect did not default to dry bypass");

        key_pressed = 3'b100;
        clock_once();
        key_pressed = 3'b000;
        clock_once();
        expect(effect_select == 2'd1, "effect did not advance to delay");

        key_pressed = 3'b001;
        clock_once();
        key_pressed = 3'b000;
        clock_once();
        expect(selected_field == 3'd1, "KEY0 did not advance to strength row");
        key_pressed = 3'b001; clock_once(); key_pressed = 0; clock_once();
        expect(selected_field == 3'd2, "KEY0 did not advance to additive row");
        expect(test_mode == 1'b0, "32-partial test did not default to stopped");
        expect(test_polyphony == 1'b0, "test source did not default to 32-partial mode");

        key_pressed = 3'b100;
        clock_once();
        key_pressed = 3'b000;
        clock_once();
        expect(test_mode == 1'b1, "KEY2 did not start a test");
        expect(test_polyphony == 1'b0, "additive row selected wrong source");

        key_pressed = 3'b010;
        clock_once();
        key_pressed = 3'b000;
        clock_once();
        expect(test_mode == 1'b0, "KEY1 did not stop additive test");

        key_pressed = 3'b010;
        clock_once();
        key_pressed = 3'b000;
        clock_once();
        expect(test_mode == 1'b0, "second KEY1 press did not stop the 32-partial test");

        setting_pressed = 1'b1;
        clock_once();
        setting_pressed = 1'b0;
        clock_once();
        expect(setting_mode == 1'b0, "S2 did not leave settings mode");
        expect(play_mute == 1'b0, "audio stayed muted after leaving settings");
        expect(play_mute == 1'b0, "S2 release did not unmute play mode");
        expect(play_mode == 1'b0, "touch mode did not persist after leaving settings");

        key_pressed = 3'b010;
        peak_sample = 0;
        for (sample_index = 0; sample_index < 16; sample_index = sample_index + 1) begin
            pulse_sample();
            sample_abs = (sample < 0) ? -sample : sample;
            if (sample_abs > peak_sample)
                peak_sample = sample_abs;
        end
        expect(peak_sample > 1000, "touch mode did not start while key was held");

        peak_sample = 0;
        for (sample_index = 0; sample_index < 100; sample_index = sample_index + 1) begin
            pulse_sample();
            sample_abs = (sample < 0) ? -sample : sample;
            if (sample_abs > peak_sample)
                peak_sample = sample_abs;
        end
        expect(peak_sample > 1000, "touch mode did not sustain while key was held");
        expect(u_audio_voice_mixer.voice1_gain == 8'd144,
               "touch mode did not settle at the ADSR sustain level");
        expect(u_audio_voice_mixer.voice1_decaying == 1'b0,
               "touch mode did not leave the ADSR decay stage");

        key_pressed = 3'b000;
        clock_once();
        for (sample_index = 0; sample_index < 512; sample_index = sample_index + 1)
            pulse_sample();
        expect(sample == 16'sd0, "touch mode did not release after key lift");

        apply_reset();
        key_pressed = 3'b010;
        clock_once();
        key_pressed = 3'b000;
        clock_once();
        repeat (2) clock_once();
        peak_sample = 0;
        for (sample_index = 0; sample_index < 12; sample_index = sample_index + 1) begin
            pulse_sample();
            sample_abs = (sample < 0) ? -sample : sample;
            if (sample_abs > peak_sample)
                peak_sample = sample_abs;
        end
        expect(peak_sample > 1000, "pluck attack did not produce audible output");

        for (sample_index = 0; sample_index < 1200; sample_index = sample_index + 1)
            pulse_sample();
        expect(sample == 16'sd0, "pluck envelope did not decay to zero");

        key_pressed = 3'b010;
        clock_once();
        key_pressed = 3'b000;
        clock_once();
        repeat (2) clock_once();
        repeat (4) pulse_sample();
        // Drain the documented three-clock PCM pipeline without advancing
        // the envelope by another sample (the board has 1024 clocks/slot).
        repeat (3) clock_once();
        expect(sample != 16'sd0, "retrigger did not restart voice");
        setting_pressed = 1'b1;
        clock_once();
        setting_pressed = 1'b0;
        clock_once();
        expect(setting_mode == 1'b1, "S2 did not re-enter settings");
        expect(sample == 16'sd0, "settings mute did not clear active envelope");

        // The dynamic 32-voice mode must accept playable triggers after S2
        // exits settings; the automatic additive test must still suppress them.
        apply_reset();
        setting_pressed = 1; clock_once();
        setting_pressed = 0; clock_once();
        key_pressed = 3'b100; clock_once(); key_pressed = 0; clock_once();
        repeat (4) begin
            key_pressed = 3'b001; clock_once();
            key_pressed = 0; clock_once();
        end
        key_pressed = 3'b100; clock_once();
        key_pressed = 0; clock_once();
        expect(test_mode && test_polyphony, "dynamic mode was not selected");
        expect(play_trigger == 0, "settings key leaked into audio trigger");
        setting_pressed = 1; clock_once();
        setting_pressed = 0; clock_once();
        key_pressed = 3'b111;
        repeat (4) clock_once();
        expect(play_trigger == 3'b111, "dynamic mode blocked simultaneous playable keys");
        key_pressed = 0; clock_once();
        setting_pressed = 1; clock_once();
        setting_pressed = 0; clock_once();
        expect(!test_mode, "S2 did not stop running test");
        repeat (3) begin
            key_pressed = 3'b001; clock_once(); key_pressed = 0; clock_once();
        end
        key_pressed = 3'b100; clock_once();
        key_pressed = 0; clock_once();
        expect(test_mode && !test_polyphony, "additive mode was not selected");
        setting_pressed = 1; clock_once();
        setting_pressed = 0; clock_once();
        key_pressed = 3'b111;
        repeat (6) begin
            clock_once();
            expect(play_trigger == 0, "automatic additive mode leaked playable keys");
        end

        if (error_count == 0) begin
            $display("PASS: one-key I/IV/V chords, melody map, smooth four-voice mix, touch ADSR, pluck envelope, and settings checks passed");
            $finish;
        end else begin
            $fatal(1, "FAIL: %0d regression checks failed", error_count);
        end
    end

endmodule

`default_nettype wire
