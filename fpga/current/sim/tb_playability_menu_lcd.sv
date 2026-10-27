`timescale 1ns/1ps
module tb_playability_menu_lcd;
    `include "instrument_contract.vh"
    reg clk=0,rst=0,setting=0;
    reg [2:0] keys=0;
    wire [27:0] controls;
    wire [1:0] glide,vibrato;
    wire [2:0] target,field;
    wire page,settings;
    reg [67:0] payload;
    reg update=0,frame=0;
    integer n;
    always #5 clk=~clk;
    instrument_control #(.LEGACY_VOICE_ENABLE(0),.ADDITIVE_BANK_ENABLE(0),.STRING_BANK_ENABLE(1)) ctrl(
        .clk(clk),.reset_n(rst),.clock_enable(1'b1),.key_pressed(keys),
        .setting_pressed(setting),.remote_song_start(1'b0),.status_payload(controls),
        .glide_select(glide),.vibrato_select(vibrato),.audition_target(target),
        .selected_field(field),.settings_page(page),.setting_mode(settings));
    lcd_test_pattern #(.ADDITIVE_BANK_ENABLE(0),.STRING_BANK_ENABLE(1)) lcd(
        .pixel_clk(clk),.reset_n(rst),.active_x(11'd0),.active_y(10'd0),
        .data_enable(1'b1),.hsync_in(1'b1),.vsync_in(1'b1),.frame_start(frame),
        .audio_sample(16'd0),.audio_sample_valid(1'b0),.status_payload(payload),
        .status_update(update),.upload_status(4'd0));
    task ticks;repeat(3)@(negedge clk);endtask
    task press(input [2:0] m);begin keys=m;ticks();keys=0;ticks();end endtask
    task commit;begin
        payload=0;payload[27:0]=controls;payload[ST_PAGE]=page;
        payload[ST_GLIDE+:2]=glide;payload[ST_VIBRATO+:2]=vibrato;
        payload[ST_AUDITION_TARGET+:3]=target;
        update=1;ticks();update=0;ticks();frame=1;ticks();frame=0;ticks();
    end endtask
    initial begin
        ticks();rst=1;ticks();setting=1;ticks();setting=0;ticks();press(4);
        repeat(5)press(1);
        if(ctrl.edit_field!=FIELD_EXPRESSION || target!=7)$fatal(1,"Wrong expression row");
        commit();if(lcd.song_context)$fatal(1,"Score target aliases expression row");
        // Reproduce the original display defect without relying on target
        // changes: a remembered score target must not mask actual expressions.
        payload[ST_GLIDE+:2]=3;update=1;ticks();update=0;ticks();frame=1;ticks();frame=0;ticks();
        if(lcd.glide_active!=3 || lcd.settings_glyph(FIELD_EXPRESSION,10)!=98)
            $fatal(1,"LCD hides a glide preset behind score state");
        if(lcd.settings_glyph(FIELD_AUDITION,10)!=122 ||
            lcd.settings_glyph(FIELD_AUDITION,16)!=0)
            $fatal(1,"LCD decodes expression bits as score details");
        for(n=0;n<6;n++)begin
            press(4);commit();
            case(n%3)
                0:if(glide!=3 || vibrato!=0 || lcd.settings_glyph(FIELD_EXPRESSION,10)!=98)$fatal(1,"Glide preset mismatch");
                1:if(glide!=0 || vibrato!=3 || lcd.settings_glyph(FIELD_EXPRESSION,10)!=99)$fatal(1,"Vibrato preset mismatch");
                2:if(glide!=0 || vibrato!=0 || lcd.settings_glyph(FIELD_EXPRESSION,10)!=60)$fatal(1,"Acoustic preset mismatch");
            endcase
        end
        press(1);if(ctrl.edit_field!=FIELD_AUDITION)$fatal(1,"Last row inaccessible");
        // Existing expression changes leave target=0. Visit all eight entries.
        for(n=0;n<8;n++)begin
            press(2);commit();
            if(target!=((n+1)%8))$fatal(1,"Last-row selection trapped");
            if(lcd.song_context!=(target==7))$fatal(1,"LCD song context disagrees with focus");
            if(target==7 && lcd.settings_glyph(FIELD_EXPRESSION,10)!=0)
                $fatal(1,"LCD labels score metadata as an acoustic preset");
        end
        $display("PASS: production row mapping, original/glide/vibrato glyphs, remembered score target, all eight audition choices and wraparound");
        $finish;
    end
    initial begin #200000;$fatal(1,"Playability menu timeout");end
endmodule
