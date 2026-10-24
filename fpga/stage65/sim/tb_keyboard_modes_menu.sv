`timescale 1ns/1ps
module tb_keyboard_modes_menu;
    `include "instrument_contract.vh"
    reg clk=0,rst=0,setting=0,frame=0,update=0;
    reg [2:0] keys=0;
    reg [67:0] payload=0;
    reg [9:0] y=0;
    wire [27:0] controls;
    wire piano,page,settings;
    wire [2:0] field;
    reg [63:0] saved;
    integer i,r,pixels;
    always #5 clk=~clk;
    instrument_control #(.LEGACY_VOICE_ENABLE(0),.ADDITIVE_BANK_ENABLE(0),
        .STRING_BANK_ENABLE(1),.KEYBOARD_MODE_ENABLE(1)) ctrl(
        .clk(clk),.reset_n(rst),.clock_enable(1'b1),.key_pressed(keys),
        .setting_pressed(setting),.remote_song_start(1'b0),.status_payload(controls),
        .keyboard_piano(piano),.selected_field(field),.settings_page(page),.setting_mode(settings));
    lcd_test_pattern #(.ADDITIVE_BANK_ENABLE(0),.STRING_BANK_ENABLE(1),.KEYBOARD_MODE_ENABLE(1)) lcd(
        .pixel_clk(clk),.reset_n(rst),.active_x(11'd120),.active_y(y),
        .data_enable(1'b1),.hsync_in(1'b1),.vsync_in(1'b1),.frame_start(frame),
        .audio_sample(16'd0),.audio_sample_valid(1'b0),.status_payload(payload),
        .status_update(update),.upload_status(4'd0));
    function [63:0] configuration;
        configuration={ctrl.play_mode,ctrl.tone_select,ctrl.string_mode,ctrl.note_select,
            ctrl.force_value,ctrl.keymap_select,ctrl.octave_select,ctrl.effect_select,
            ctrl.effect_strength,ctrl.glide_select,ctrl.vibrato_select,ctrl.song_select,
            ctrl.song_accompaniment,ctrl.song_tempo,ctrl.audition_target};
    endfunction
    task ticks;repeat(3)@(negedge clk);endtask
    task press(input [2:0] mask);begin keys=mask;ticks();keys=0;ticks();end endtask
    task commit;begin
        payload=0;payload[27:0]=controls;payload[ST_PAGE]=page;
        payload[ST_STRING]=ctrl.string_mode;payload[ST_DEADLINES+:8]=8'ha5;
        payload[ST_KEYBOARD_PIANO]=piano;
        payload[ST_GLIDE+:2]=ctrl.glide_select;payload[ST_VIBRATO+:2]=ctrl.vibrato_select;
        payload[ST_AUDITION_TARGET+:3]=ctrl.audition_target;
        update=1;ticks();update=0;ticks();frame=1;ticks();frame=0;ticks();
        y=359;ticks();y=360;ticks();
    end endtask
    initial begin
        ticks();rst=1;ticks();if(piano)$fatal(1,"Default mode changed");
        setting=1;ticks();setting=0;ticks();press(1);press(4);press(1);press(4);
        // Change real settings before testing the overlay's preservation.
        repeat(5)press(1);press(4);press(1);press(4);press(1);press(4);
        press(1);press(1);press(4);press(1);press(4);press(1);press(1);
        if(ctrl.edit_field!=FIELD_KEYBOARD || field!=6)$fatal(1,"New row is not last");
        saved=configuration();commit();
        if(lcd.settings_field_index!=FIELD_KEYBOARD || !lcd.settings_row_region ||
           lcd.settings_glyph(FIELD_KEYBOARD,10)!=134)$fatal(1,"Last row missing field=%0d region=%b glyph=%0d page=%b",lcd.settings_field_index,lcd.settings_row_region,lcd.settings_glyph(FIELD_KEYBOARD,10),lcd.settings_page_active);
        for(i=0;i<4;i++)begin
            press(i[0]?2:4);commit();
            if(piano!=(~i[0]) || configuration()!==saved)$fatal(1,"Mode toggle overwrote settings");
            if(lcd.settings_glyph(FIELD_KEYBOARD,10)!=(piano?135:134))$fatal(1,"Mode glyph stale");
            if(lcd.string_deadline_misses!=8'ha5)$fatal(1,"Mode corrupts deadlines");
            if(lcd.settings_hint_glyph(1,0)!=72)$fatal(1,"New row shows audition help");
        end
        press(4);press(1);commit();
        if(field!=FIELD_TABS || lcd.settings_glyph(FIELD_KEYBOARD,10)!=135)
            $fatal(1,"Mode label disappears away from focus or tabs unreachable");
        for(i=0;i<7;i++)begin
            press(1);
            if(field!=i)$fatal(1,"Row cycle skipped a field");
        end
        for(i=134;i<=136;i++)begin
            pixels=0;for(r=0;r<24;r++)pixels+= $countones(lcd.chinese_font_row(i,r));
            if(pixels<30)$fatal(1,"New glyph blank");
        end
        $display("PASS: seventh extension row, both toggle directions, persistent off-focus label, original settings/deadlines preserved, tabs and three new glyphs");
        $finish;
    end
    initial begin #200000;$fatal(1,"Keyboard menu timeout");end
endmodule
