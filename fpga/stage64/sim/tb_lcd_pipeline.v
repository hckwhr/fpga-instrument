`timescale 1ns/1ps
`default_nettype none

module tb_lcd_pipeline;

    localparam integer H_TOTAL = 800 + 210 + 1 + 46;
    localparam integer V_TOTAL = 480 + 22 + 1 + 23;
    localparam integer FRAME_PIXELS = H_TOTAL * V_TOTAL;

    reg pixel_clk;
    reg reset_n;
    reg signed [15:0] audio_sample;
    reg audio_sample_valid;
    reg [2:0] key_pressed;

    wire hsync;
    wire vsync;
    wire data_enable;
    reg frame_start;
    reg [10:0] active_x;
    reg [9:0] active_y;
    wire timing_hsync, timing_vsync, timing_de, timing_frame_start;
    wire [10:0] timing_x;
    wire [9:0] timing_y;
    wire [5:0] red;
    wire [5:0] green;
    wire [5:0] blue;
    wire [5:0] pressed_red;
    wire [5:0] pressed_green;
    wire [5:0] pressed_blue;
    wire [5:0] settings_red;
    wire [5:0] settings_green;
    wire [5:0] settings_blue;
    wire [67:0] released_status;
    wire [67:0] pressed_status;
    wire [67:0] settings_status;

    integer error_count;
    integer total_pixels;
    integer active_pixels;
    integer hsync_pixels;
    integer vsync_pixels;
    integer active_line_starts;
    integer sample_feed_count;
    reg frame_started;
    reg initial_frame_seen = 1'b0;
    reg saw_piano_strip;
    reg saw_key_blocks;
    reg saw_yellow_trace;
    reg saw_interpolated_trace;
    reg saw_volume_bar;
    reg saw_scope_trigger_armed;
    reg saw_scope_trigger_capture;
    reg saw_scope_half_scale;
    reg saw_scope_decimation;
    reg saw_settings_title;
    reg saw_settings_selected_row;
    reg saw_settings_unselected_row;

    assign released_status = {
        6'd0,
        1'b0, 1'b1, 2'd0, 1'b0, 3'd0, 1'b1, 2'd0, 4'd0, 7'd96, 1'b1, 2'd1,
        key_pressed
    };
    assign pressed_status = {
        6'd0,
        1'b0, 1'b0, 2'd0, 1'b0, 3'd0, 1'b1, 2'd0, 4'd0, 7'd96, 1'b1, 2'd1,
        3'b001
    };
    assign settings_status = {
        6'd0,
        1'b1, 1'b0, 2'd2, 1'b1, 3'd3, 1'b1, 2'd1, 4'd4, 7'd96, 1'b1, 2'd1,
        3'b000
    };

    lcd_timing_800x480 u_timing (
        .pixel_clk  (pixel_clk),
        .reset_n    (reset_n),
        .hsync      (timing_hsync),
        .vsync      (timing_vsync),
        .data_enable(timing_de),
        .frame_start(timing_frame_start),
        .active_x   (timing_x),
        .active_y   (timing_y)
    );

    lcd_test_pattern u_pattern (
        .hsync_in(timing_hsync), .vsync_in(timing_vsync),
        .hsync_out(hsync), .vsync_out(vsync), .de_out(data_enable),
        .pixel_clk         (pixel_clk),
        .reset_n           (reset_n),
        .active_x          (timing_x),
        .active_y          (timing_y),
        .data_enable       (timing_de),
        .frame_start       (timing_frame_start),
        .audio_sample      (audio_sample),
        .audio_sample_valid(audio_sample_valid),
        .status_payload    (released_status),
        .status_update     (1'b1),
        .red               (red),
        .green             (green),
        .blue              (blue)
    );

    // A second instance keeps the regression deterministic while checking
    // both the released (bright) and pressed (dim) color states.
    lcd_test_pattern u_pressed_pattern (
        .hsync_in(timing_hsync), .vsync_in(timing_vsync),
        .hsync_out(), .vsync_out(), .de_out(),
        .pixel_clk         (pixel_clk),
        .reset_n           (reset_n),
        .active_x          (timing_x),
        .active_y          (timing_y),
        .data_enable       (timing_de),
        .frame_start       (timing_frame_start),
        .audio_sample      (audio_sample),
        .audio_sample_valid(audio_sample_valid),
        .status_payload    (pressed_status),
        .status_update     (1'b1),
        .red               (pressed_red),
        .green             (pressed_green),
        .blue              (pressed_blue)
    );

    lcd_test_pattern u_settings_pattern (
        .hsync_in(timing_hsync), .vsync_in(timing_vsync),
        .hsync_out(), .vsync_out(), .de_out(),
        .pixel_clk         (pixel_clk),
        .reset_n           (reset_n),
        .active_x          (timing_x),
        .active_y          (timing_y),
        .data_enable       (timing_de),
        .frame_start       (timing_frame_start),
        .audio_sample      (audio_sample),
        .audio_sample_valid(audio_sample_valid),
        .status_payload    (settings_status),
        .status_update     (1'b1),
        .red               (settings_red),
        .green             (settings_green),
        .blue              (settings_blue)
    );

    always #5 pixel_clk = ~pixel_clk;

    // Scoreboard coordinates follow the specified one-pixel renderer latency.
    always @(posedge pixel_clk) begin
        active_x <= timing_x;
        active_y <= timing_y;
        frame_start <= timing_frame_start;
    end

    always @(posedge pixel_clk) begin
        if (!reset_n) begin
            audio_sample_valid <= 1'b0;
            sample_feed_count <= 0;
        end else begin
            audio_sample_valid <= 1'b1;
            audio_sample <= $signed({sample_feed_count[7:0], 8'h00});
            sample_feed_count <= sample_feed_count + 1;
        end
    end

    always @(posedge pixel_clk) begin
        if (reset_n) begin
            #1;

            if (frame_started) begin
                if (!data_enable && {red,green,blue} !== 18'd0) begin
                    $display("ERROR: RGB escaped delayed DE during blanking");
                    error_count = error_count + 1;
                end
                if (u_pattern.test_mode_active &&
                    u_pattern.capture_trigger_armed)
                    saw_scope_trigger_armed = 1'b1;
                if (saw_scope_trigger_armed && u_pattern.capture_active)
                    saw_scope_trigger_capture = 1'b1;
                if (u_pattern.test_mode_active && u_pattern.capture_active &&
                    (u_pattern.capture_sample_divider == 2'd3))
                    saw_scope_decimation = 1'b1;
                if (u_pattern.test_mode_active &&
                    (audio_sample == 16'sh4000)) begin
                    saw_scope_half_scale = 1'b1;
                    if (u_pattern.capture_sample !== 8'sd32) begin
                        $display("ERROR: additive scope sample was not scaled by one half");
                        error_count = error_count + 1;
                    end
                end

                total_pixels = total_pixels + 1;
                if (data_enable)
                    active_pixels = active_pixels + 1;
                if (!hsync)
                    hsync_pixels = hsync_pixels + 1;
                if (!vsync)
                    vsync_pixels = vsync_pixels + 1;
                if (data_enable && (active_x == 11'd0))
                    active_line_starts = active_line_starts + 1;

                if (data_enable && (active_x == 11'd50) && (active_y == 10'd120)) begin
                    saw_piano_strip = 1'b1;
                    if ({red, green, blue} !== {6'd13, 6'd49, 6'd56}) begin
                        $display("ERROR: selected root piano key color is incorrect");
                        error_count = error_count + 1;
                    end
                    if ({pressed_red, pressed_green, pressed_blue} !==
                        {6'd63, 6'd47, 6'd7}) begin
                        $display("ERROR: pressed root piano key color is incorrect");
                        error_count = error_count + 1;
                    end
                end

                if (data_enable && (active_y == 10'd40)) begin
                    if (active_x == 11'd50) begin
                        saw_key_blocks = 1'b1;
                        if ({red, green, blue} !== {6'd63, 6'd10, 6'd13}) begin
                            $display("ERROR: released KEY0 block is not bright red");
                            error_count = error_count + 1;
                        end
                        if ({pressed_red, pressed_green, pressed_blue} !== {6'd24, 6'd4, 6'd5}) begin
                            $display("ERROR: pressed KEY0 block is not dim red");
                            error_count = error_count + 1;
                        end
                    end else if (active_x == 11'd130) begin
                        if ({red, green, blue} !== {6'd5, 6'd63, 6'd14}) begin
                            $display("ERROR: released KEY1 block is not bright green");
                            error_count = error_count + 1;
                        end
                        if ({pressed_red, pressed_green, pressed_blue} !== {6'd5, 6'd63, 6'd14}) begin
                            $display("ERROR: released KEY1 block changed during KEY0 chord press");
                            error_count = error_count + 1;
                        end
                    end else if (active_x == 11'd210) begin
                        if ({red, green, blue} !== {6'd8, 6'd29, 6'd63}) begin
                            $display("ERROR: released KEY2 block is not bright blue");
                            error_count = error_count + 1;
                        end
                        if ({pressed_red, pressed_green, pressed_blue} !== {6'd8, 6'd29, 6'd63}) begin
                            $display("ERROR: released KEY2 block changed during KEY0 chord press");
                            error_count = error_count + 1;
                        end
                    end
                end

                if (data_enable && (active_x == 11'd720) &&
                    (active_y == 10'd55)) begin
                    saw_volume_bar = 1'b1;
                    if ({red, green, blue} !== {6'd6, 6'd58, 6'd19}) begin
                        $display("ERROR: digital output level bar is not active");
                        error_count = error_count + 1;
                    end
                end

                if (u_settings_pattern.settings_title_glyph_on)
                    saw_settings_title = 1'b1;

                if (data_enable && (active_x == 11'd100) &&
                    (active_y == 10'd250)) begin
                    saw_settings_selected_row = 1'b1;
                    if ({settings_red, settings_green, settings_blue} !==
                        {6'd4, 6'd18, 6'd30}) begin
                        $display("ERROR: selected settings row color is incorrect");
                        error_count = error_count + 1;
                    end
                end

                if (data_enable && (active_x == 11'd100) &&
                    (active_y == 10'd92)) begin
                    saw_settings_unselected_row = 1'b1;
                    if ({settings_red, settings_green, settings_blue} !==
                        {6'd2, 6'd8, 6'd14}) begin
                        $display("ERROR: unselected settings row color is incorrect");
                        error_count = error_count + 1;
                    end
                end

                if (data_enable && (active_x >= 11'd16) &&
                    (active_x < 11'd784) && (active_y >= 10'd250) &&
                    (active_y < 10'd468) &&
                    ({red, green, blue} == {6'd63, 6'd56, 6'd4})) begin
                    saw_yellow_trace = 1'b1;
                    if (active_x[1:0] != 2'd0)
                        saw_interpolated_trace = 1'b1;
                end
            end

            if (frame_start) begin
                if (!initial_frame_seen) begin
                    initial_frame_seen = 1'b1;
                end else if (!frame_started) begin
                    frame_started = 1'b1;
                end else begin
                    if (total_pixels != FRAME_PIXELS) begin
                        $display("ERROR: frame pixels %0d, expected %0d", total_pixels, FRAME_PIXELS);
                        error_count = error_count + 1;
                    end
                    if (active_pixels != 800 * 480) begin
                        $display("ERROR: active pixels %0d, expected 384000", active_pixels);
                        error_count = error_count + 1;
                    end
                    if (hsync_pixels != V_TOTAL) begin
                        $display("ERROR: HSYNC-low pixels %0d, expected %0d", hsync_pixels, V_TOTAL);
                        error_count = error_count + 1;
                    end
                    if (vsync_pixels != H_TOTAL) begin
                        $display("ERROR: VSYNC-low pixels %0d, expected %0d", vsync_pixels, H_TOTAL);
                        error_count = error_count + 1;
                    end
                    if (active_line_starts != 480) begin
                        $display("ERROR: active line count %0d, expected 480", active_line_starts);
                        error_count = error_count + 1;
                    end
                    if (!saw_piano_strip || !saw_key_blocks || !saw_yellow_trace ||
                        !saw_interpolated_trace || !saw_volume_bar ||
                        !saw_scope_trigger_armed || !saw_scope_trigger_capture ||
                        !saw_scope_half_scale || !saw_scope_decimation ||
                        !saw_settings_title || !saw_settings_selected_row ||
                        !saw_settings_unselected_row) begin
                        $display("ERROR: expected piano, key-block, waveform, or level-meter points were not observed");
                        error_count = error_count + 1;
                    end

                    if (error_count == 0)
                        $display("PASS: 800x480 UI, triggered 4:1 additive trace, and level-meter checks passed");
                    else
                        $display("FAIL: LCD pipeline found %0d errors", error_count);

                    $finish;
                end
            end
        end
    end

    initial begin
        pixel_clk = 1'b0;
        reset_n = 1'b0;
        audio_sample = 16'sd0;
        audio_sample_valid = 1'b0;
        key_pressed = 3'b000;
        error_count = 0;
        total_pixels = 0;
        active_pixels = 0;
        hsync_pixels = 0;
        vsync_pixels = 0;
        active_line_starts = 0;
        sample_feed_count = 0;
        frame_started = 1'b0;
        saw_piano_strip = 1'b0;
        saw_yellow_trace = 1'b0;
        saw_interpolated_trace = 1'b0;
        saw_volume_bar = 1'b0;
        saw_scope_trigger_armed = 1'b0;
        saw_scope_trigger_capture = 1'b0;
        saw_scope_half_scale = 1'b0;
        saw_scope_decimation = 1'b0;
        saw_settings_title = 1'b0;
        saw_settings_selected_row = 1'b0;
        saw_settings_unselected_row = 1'b0;

        repeat (5) @(posedge pixel_clk);
        reset_n = 1'b1;
    end

endmodule

`default_nettype wire
