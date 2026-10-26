`timescale 1ns/1ps
`default_nettype none
module tb_settings_pages;
    reg clk = 0, pixel_clk = 0, reset_n = 0;
    reg [2:0] keys = 0;
    reg s2 = 0, frame_start = 0;
    reg [10:0] x = 0;
    reg [9:0] y = 0;
    wire [2:0] trigger, field;
    wire mute, settings, page, mode, strings, keymap, test_mode, polyphony;
    wire [1:0] tone, octave, effect, glide, vibrato;
    wire [1:0] strength;
    wire [3:0] note;
    wire [6:0] force_value;
    wire [27:0] payload;
    wire [67:0] pixel_payload;
    wire [2:0] audition_target;
    wire audition;
    wire song_select;
    wire [1:0] song_tempo;
    wire [1:0] display_glide=(audition_target==7 && (settings || audition))?{1'b0,song_select}:glide;
    wire [1:0] display_vibrato=(audition_target==7 && (settings || audition))?song_tempo:vibrato;
    reg preview_wet=0;
    wire display_wet = (settings && audition_target==7) ? song_select : preview_wet;
    wire pixel_update;
    wire [5:0] red, green, blue;
    integer errors = 0;
    integer row, i;
    reg [19:0] saved_parameters;

    always #5 clk = ~clk;
    always #7 pixel_clk = ~pixel_clk;
    instrument_control #(.PLAY_GUARD_CYCLES(3), .PLAY_GUARD_COUNTER_WIDTH(2)) control (
        .clk(clk), .reset_n(reset_n), .key_pressed(keys), .setting_pressed(s2),
        .remote_song_start(1'b0),
        .song_select(song_select), .song_tempo(song_tempo), .song_change(), .song_accompaniment(),
        .play_trigger(trigger), .play_mute(mute), .setting_mode(settings),
        .settings_page(page), .selected_field(field), .play_mode(mode),
        .tone_select(tone), .string_mode(strings), .note_select(note),
        .force_value(force_value), .keymap_select(keymap), .octave_select(octave),
        .effect_select(effect), .test_mode(test_mode), .test_polyphony(polyphony),
        .effect_strength(strength),
        .glide_select(glide), .vibrato_select(vibrato),
        .audition_mode(audition),
        .audition_target(audition_target),
        .status_payload(payload)
    );
    status_bundle_cdc #(.WIDTH(68)) cdc (
        .src_clk(clk), .src_reset_n(reset_n), .src_payload({12'd0,strength,audition_target,display_wet,audition && !settings,audition,display_vibrato, display_glide, 8'd0, page, strings, 6'd0, payload}),
        .dst_clk(pixel_clk), .dst_reset_n(reset_n), .dst_payload(pixel_payload),
        .dst_update(pixel_update)
    );
    lcd_test_pattern lcd (
        .pixel_clk(pixel_clk), .reset_n(reset_n), .active_x(x), .active_y(y),
        .data_enable(1'b1), .hsync_in(1'b1), .vsync_in(1'b1),
        .hsync_out(), .vsync_out(), .de_out(),
        .frame_start(frame_start), .audio_sample(16'sd0),
        .audio_sample_valid(1'b0), .status_payload(pixel_payload), .status_update(pixel_update),
        .red(red), .green(green), .blue(blue)
    );
    task check;
        input condition;
        input [8*110-1:0] message;
        begin
            if (condition !== 1'b1) begin
                $display("ERROR: %0s", message);
                errors = errors + 1;
            end
        end
    endtask
    task press;
        input [2:0] value;
        begin
            @(negedge clk); keys = value;
            repeat (2) @(negedge clk);
            keys = 0;
            repeat (6) @(negedge clk);
        end
    endtask
    task press_s2;
        begin
            @(negedge clk); s2 = 1;
            repeat (2) @(negedge clk);
            s2 = 0;
            repeat (6) @(negedge clk);
        end
    endtask
    task commit_frame;
        begin
            repeat (50) @(negedge pixel_clk);
            frame_start = 1;
            @(negedge pixel_clk); frame_start = 0;
        end
    endtask
    task snapshot;
        input [8*120-1:0] filename;
        integer fd, px, py;
        begin
            fd = $fopen(filename, "w");
            if (!fd) $fatal(1, "Cannot write settings preview");
            $fwrite(fd, "P3\n800 480\n63\n");
            for (py=0; py<480; py=py+1)
                for (px=0; px<800; px=px+1) begin
                    @(negedge pixel_clk); x=px; y=py;
                    @(posedge pixel_clk); #1;
                    $fwrite(fd, "%0d %0d %0d\n", red, green, blue);
                    check((^{red,green,blue}) !== 1'bx, "unknown menu pixel");
                end
            $fclose(fd);
        end
    endtask
    // No settings key may appear as a musical trigger, including S2 transitions.
    always @(negedge clk)
        if (reset_n && (settings || s2))
            check(trigger == 0, "settings leaked a musical trigger");

    initial begin
        #1; reset_n = 0;
        repeat (5) @(negedge clk);
        reset_n = 1;
        press_s2();
        check(settings && !page && field == 7, "S2 did not enter basic tabs");
        commit_frame();
        check(lcd.setting_mode_active && !lcd.settings_page_active, "basic CDC state wrong");
        for (row=0; row<6; row=row+1) begin
            press(1);
            check(field == row, "basic navigation skipped a field");
        end
        press(1);
        check(field == 7, "basic fields did not wrap to tabs");
        press(1); press(1); // tone
        press(4);
        check(strings && tone == 3, "basic tone cannot select physical strings");
        commit_frame();
        snapshot("sim/settings_basic.ppm");
        repeat (5) press(1);
        check(field == 7, "tone to tabs navigation wrong");
        saved_parameters = {mode,tone,strings,note,force_value,keymap,octave,effect};
        press(4);
        check(page && field == 7, "KEY2 did not choose extension tabs");
        repeat (50) @(negedge pixel_clk);
        check(!lcd.settings_page_active, "page changed before frame boundary");
        commit_frame();
        check(lcd.settings_page_active, "page did not cross handshake CDC");
        for (row=0; row<7; row=row+1) begin
            press(1);
            check(field == row, "extension navigation skipped a field");
        end
        press(1);
        check(field == 7, "extension navigation did not wrap to tabs");
        check({mode,tone,strings,note,force_value,keymap,octave,effect} == saved_parameters,
              "page navigation changed live parameters");
        press(1); // effect
        press(4); check(effect == 1, "extension effect increment failed");
        press(2); check(effect == 0, "extension effect decrement failed");
        press(1); // strength: default medium, both wrap directions, no mode edits
        check(strength==1 && effect==0,"strength default changed working baseline");
        press(4);check(strength==2,"strength increment failed");
        commit_frame();check(lcd.settings_glyph(12,10)==104,"strong label incorrect");
        check(lcd.settings_hint_glyph(1,0)==103,"strength row retained demo start/stop hint");
        snapshot("sim/settings_strength.ppm");
        press(4);check(strength==0,"strength wrap failed");
        press(2);check(strength==2,"strength decrement wrap failed");
        press(2);check(strength==1 && effect==0,"strength changed effect type");
        press(1); // additive
        press(4);
        check(test_mode && !polyphony && strings, "arming additive lost live string selection");
        commit_frame();
        check(lcd.settings_glyph(7,10) == 76 && lcd.settings_glyph(8,10) == 63,
              "only selected demo should show ready");
        snapshot("sim/settings_extension.ppm");
        press(4);
        check(test_mode && !polyphony, "repeated prepare should not stop demo");
        press_s2();
        check(!settings && test_mode, "S2 did not run prepared additive demo");
        commit_frame();
        check(lcd.status_glyph(0,6) == 36 && lcd.status_glyph(0,8) == 62 &&
              lcd.status_glyph(0,9) == 8 && lcd.status_glyph(0,12) == 92,
              "main page must identify additive source instead of stored string timbre");
        press(7); check(trigger == 0, "additive demo allowed live trigger");
        press_s2();
        check(settings && !test_mode && strings && field == 7,
              "S2 did not stop additive and retain live timbre");
        repeat (4) press(1); // polyphony
        press(4);
        check(test_mode && polyphony, "polyphony row did not arm polyphony");
        press_s2();
        commit_frame();
        check(lcd.status_glyph(0,8) == 23 && lcd.status_glyph(0,12) == 90 &&
              lcd.status_glyph(0,13) == 91, "polyphony must label real voice count");
        @(negedge clk); keys=7;
        repeat (4) @(negedge clk);
        check(trigger == 7, "polyphony must accept simultaneous playable keys");
        keys=0;
        press_s2();
        check(!test_mode && strings, "S2 failed to stop polyphony and preserve strings");
        repeat (5) press(1); // physical shortcut
        press(2); check(!strings && tone == 3, "physical shortcut did not return to piano");
        commit_frame();
        check(lcd.settings_glyph(9,10) == 63 && lcd.settings_glyph(9,11) == 24,
              "inactive physical model must show stopped, not a different active timbre");
        press(4); check(strings && tone == 3 && !test_mode, "physical shortcut failed");
        press(1); // expression preset
        check(field==5 && glide==0 && vibrato==0,"expression reset defaults/navigation wrong");
        press(4); check(glide==3 && vibrato==0,"glide preset failed");
        check(!strings && !mode && !keymap && tone==0 && effect==0 && octave==1 && note==0,
              "preset retained incompatible sound settings");
        press(4); check(glide==0 && vibrato==3,"vibrato preset failed");
        press(4); check(glide==0 && vibrato==0,"preset cannot return to original");
        press(2); check(vibrato==3,"preset decrement wrong");
        press(1); press(4);
        check(field==6 && audition && !test_mode,"audition did not prepare independently");
        commit_frame();
        check(lcd.settings_glyph(10,10)==99 && lcd.settings_glyph(11,14)==76,
              "LCD preset/preview values wrong");
        check(lcd.settings_hint_glyph(1,4)==78,"audition hint not updated to new row");
        snapshot("sim/settings_expression.ppm");
        press_s2(); commit_frame();
        check(audition && !settings && lcd.status_glyph(0,8)==60,"audition dry label wrong");
        snapshot("sim/audition_dry.ppm");
        preview_wet=1; commit_frame();
        check(lcd.status_glyph(0,8)==99,"audition wet label wrong");
        snapshot("sim/audition_wet.ppm");
        press_s2(); check(!audition && vibrato==3,"S2 did not stop preview and retain expression");
        commit_frame();
        check(lcd.status_glyph(0,17)==111 && lcd.status_glyph(0,19)==99 &&
              lcd.status_glyph(1,17)==59,"live expression hid effect or retained 32-stop label");
        press_s2(); commit_frame(); snapshot("sim/live_expression.ppm"); press_s2();
        repeat(7)press(1); press(4); press(2);
        check(!audition,"KEY1 did not stop prepared audition");
        // Existing seven comparisons plus the new complete song.
        for(i=0;i<8;i=i+1) begin
            press(4); check(audition && !strings && !test_mode,"audition preparation left another source active");
            commit_frame();
            check(lcd.settings_glyph(11,10)==((audition_target==7)?(song_select?8'd126:8'd124): lcd.audition_label(audition_target,0)),"audition/song target LCD mismatch");
            if(audition_target==4)begin
                check(effect==3 && lcd.settings_glyph(6,10)==120 && lcd.settings_glyph(6,11)==121,
                      "reverb effect not rendered in Chinese");
                snapshot("sim/settings_reverb.ppm");
            end
            press(2); check(!audition,"changing target must disarm audition");
        end
        press(1); press(2); // tabs -> basic
        check(!page && field == 7, "KEY1 did not return to basic tabs");
        press(4); repeat (3) press(1); press(4); // arm additive again
        repeat (5) press(1); press(2); // return tabs and switch to basic
        check(!page && !test_mode, "page switch left hidden demo armed");
        press(1); // mode field
        saved_parameters = {mode,tone,strings,note,force_value,keymap,octave,effect};
        @(negedge clk); s2=1; keys=4;
        repeat (2) @(negedge clk); s2=0;
        repeat (8) @(negedge clk);
        check(!settings && trigger == 0, "S2/held key leaked trigger after exit");
        check({mode,tone,strings,note,force_value,keymap,octave,effect} == saved_parameters,
              "simultaneous S2 and KEY2 edited parameter");
        keys=0;
        press_s2(); commit_frame();
        check(!lcd.settings_page_active, "LCD failed to return to basic page");
        // Every active settings row is inside the panel, separate from hints.
        for (i=0;i<480;i=i+1) begin
            x=100; y=i; #1;
            if (lcd.settings_row_region)
                check(lcd.settings_row_index < 6 && i>=80 && i<392,
                      "basic row bounds overlap header or help");
        end
        press(4); commit_frame();
        for (i=0;i<480;i=i+1) begin
            x=100; y=i; #1;
            if (lcd.settings_row_region)
                check(lcd.settings_row_index < 7 && i>=80 && i<388,
                      "extension shows hidden basic rows");
        end
        if (errors) $fatal(1, "FAIL: %0d settings checks", errors);
        $display("PASS: basic/extension navigation, demo lifecycle, parameter retention, S2 priority, CDC frame commit and RTL previews");
        $finish;
    end
    initial begin
        #65000000;
        $fatal(1, "settings test timed out");
    end
endmodule
`default_nettype wire
