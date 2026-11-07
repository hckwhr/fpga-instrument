`timescale 1ns/1ps
`default_nettype none
module tb_lcd_polyphony_count;
    reg pixel_clk;
    reg reset_n;
    reg data_enable;
    reg frame_start;
    reg audio_sample_valid;
    reg status_update;
    reg [10:0] active_x;
    reg [9:0] active_y;
    reg signed [15:0] audio_sample;
    reg [67:0] status_payload;
    wire [5:0] red;
    wire [5:0] green;
    wire [5:0] blue;
    integer error_count;
    integer count;
    integer root, keys, note, relative_note;
    reg expected_pressed;

    lcd_test_pattern dut (
        .pixel_clk(pixel_clk), .reset_n(reset_n),
        .active_x(active_x), .active_y(active_y),
        .data_enable(data_enable), .frame_start(frame_start),
        .hsync_in(1'b1), .vsync_in(1'b1), .hsync_out(), .vsync_out(), .de_out(),
        .audio_sample(audio_sample), .audio_sample_valid(audio_sample_valid),
        .status_payload(status_payload), .status_update(status_update),
        .red(red), .green(green), .blue(blue)
    );

    always #5 pixel_clk = ~pixel_clk;

    task clock_once;
        begin
            @(posedge pixel_clk);
            #1;
        end
    endtask

    task expect;
        input condition;
        input [8*100-1:0] message;
        begin
            if (!condition) begin
                $display("ERROR: %0s", message);
                error_count = error_count + 1;
            end
        end
    endtask

    initial begin
        pixel_clk = 1'b0;
        reset_n = 1'b0;
        data_enable = 1'b1;
        frame_start = 1'b0;
        audio_sample = 16'sd0;
        audio_sample_valid = 1'b0;
        status_update = 1'b0;
        active_x = 11'd0;
        active_y = 10'd0;
        error_count = 0;
        status_payload = {
            6'd27, 1'b1, 1'b1, 2'd0, 1'b0, 3'd7, 1'b1,
            2'd0, 4'd0, 7'd96, 1'b1, 2'd1, 3'b000
        };

        repeat (3) clock_once();
        reset_n = 1'b1;
        status_update = 1'b1;
        clock_once();
        frame_start = 1'b1;
        clock_once();
        frame_start = 1'b0;
        status_update = 1'b0;
        clock_once();

        expect(dut.polyphony_voice_count_active == 6'd27,
               "LCD did not latch active count");
        active_x = 11'd636; active_y = 10'd14; #1;
        expect(dut.status_glyph_index == 6'd35, "tens glyph was not 2");
        active_x = 11'd662; #1;
        expect(dut.status_glyph_index == 6'd40, "ones glyph was not 7");
        active_x = 11'd700; active_y = 10'd25; #1;
        expect(dut.status_count_slash_pixel, "slash pixel was not drawn");
        active_x = 11'd714; active_y = 10'd14; #1;
        expect(dut.status_glyph_index == 6'd36, "maximum tens glyph was not 3");
        active_x = 11'd740; #1;
        expect(dut.status_glyph_index == 6'd35, "maximum ones glyph was not 2");

        for (count=0; count<=32; count=count+1) begin
            status_payload[33:28] = count;
            status_update = 1;
            clock_once();
            status_update = 0;
            // The visible count must not change until a frame boundary.
            if (count == 0)
                expect(dut.polyphony_voice_count_active == 27,
                       "count changed in the middle of a frame");
            frame_start = 1;
            clock_once();
            frame_start = 0;
            active_y = 14; active_x = 636; #1;
            expect(dut.status_glyph_index == 33 + count/10,
                   "00..32 tens digit incorrect");
            active_x = 662; #1;
            expect(dut.status_glyph_index == 33 + count%10,
                   "00..32 ones digit incorrect");
        end

        // Exercise every root and key combination using actual pixel positions.
        status_payload[5] = 1;
        for (root=0; root<12; root=root+1) begin
            status_payload[16:13] = root;
            for (keys=0; keys<8; keys=keys+1) begin
                status_payload[2:0] = keys;
                status_update = 1; clock_once(); status_update = 0;
                frame_start = 1; clock_once(); frame_start = 0;
                for (note=0; note<12; note=note+1) begin
                    active_x = dut.piano_label_x(note) + 2;
                    active_y = ((note==1)||(note==3)||(note==6)||(note==8)||(note==10)) ? 150 : 210;
                    relative_note = (note + 12 - root) % 12;
                    expected_pressed =
                        (keys[0] && ((relative_note==0)||(relative_note==4)||(relative_note==7))) ||
                        (keys[1] && ((relative_note==5)||(relative_note==9)||(relative_note==0))) ||
                        (keys[2] && ((relative_note==7)||(relative_note==11)||(relative_note==2)));
                    #1;
                    expect(dut.piano_note_index == note, "piano pixel mapping incorrect");
                    expect(dut.piano_note_pressed == expected_pressed, "simultaneous chord highlight incorrect");
                end
            end
        end

        status_payload[26] = 1'b0;
        status_payload[18:17] = 2'd3;
        status_update = 1; clock_once(); status_update = 0;
        frame_start = 1; clock_once(); frame_start = 0;
        expect(dut.status_glyph(0,9) == 7'd64, "main page lost piano glyph bit 6");
        expect(dut.status_glyph(0,10) == 7'd8, "main page piano label suffix wrong");
        expect(dut.settings_glyph(1,10) == 7'd64, "settings page lost piano glyph bit 6");
        expect(dut.chinese_font_row(7'd64,5'd8) != 0, "piano glyph was not generated");
        status_payload[34]=1;
        status_update=1; clock_once(); status_update=0;
        expect(!dut.string_mode_active,"physical label changed before frame boundary");
        frame_start=1; clock_once(); frame_start=0;
        expect(dut.status_glyph(0,9)==64 && dut.status_glyph(0,10)==44,
               "main page does not show physical string label");
        expect(dut.settings_glyph(1,10)==64 && dut.settings_glyph(1,11)==44,
               "settings page does not show physical string label");
        expect(dut.settings_glyph(9,0)==95,"physical shortcut is not eight strings");
        for(count=0;count<=8;count=count+1) begin
            status_payload[33:28]=count;
            status_payload[43:36]=255;
            status_update=1; clock_once(); status_update=0;
            frame_start=1; clock_once(); frame_start=0;
            expect(dut.status_glyph(0,15)==33 && dut.status_glyph(0,16)==33+count,
                   "physical active count incorrect");
            expect(dut.status_glyph(0,18)==33 && dut.status_glyph(0,19)==41,
                   "physical capacity is not 08");
            expect(dut.settings_glyph(9,16)==35 && dut.settings_glyph(9,17)==38 &&
                   dut.settings_glyph(9,18)==38,"deadline counter not displayed as 255");
        end

        if (error_count == 0) begin
            $display("PASS: LCD 00/32..32/32 frame updates and all roots/simultaneous chord highlights");
            $finish;
        end else begin
            $fatal(1, "FAIL: %0d LCD count checks failed", error_count);
        end
    end
endmodule
`default_nettype wire
