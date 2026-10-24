`default_nettype none

// Frozen observed effects_expression_20261002 controller, simulation only.
module baseline_integration_control #(
    parameter integer PLAY_GUARD_CYCLES = 98_304,
    parameter integer PLAY_GUARD_COUNTER_WIDTH = 17
) (
    input  wire        clk,
    input  wire        reset_n,
    input  wire [2:0]  key_pressed,
    input  wire        setting_pressed,
    output reg  [2:0]  play_trigger,
    output wire        play_mute,
    output reg          setting_mode,
    output reg          settings_page,
    output reg  [2:0]  selected_field,
    output reg          play_mode,
    output reg  [1:0]  tone_select,
    output reg         string_mode,
    output reg  [3:0]  note_select,
    output reg  [6:0]  force_value,
    output reg          keymap_select,
    output reg  [1:0]  octave_select,
    output reg  [1:0]  effect_select,
    output reg  [1:0]  effect_strength,
    output reg  [1:0]  glide_select,
    output reg  [1:0]  vibrato_select,
    output reg         audition_mode,
    output reg [2:0]   audition_target,
    output reg          test_mode,
    output reg          test_polyphony,
    output wire [27:0] status_payload
);

    localparam [3:0] FIELD_MODE = 4'd0, FIELD_TONE = 4'd1,
        FIELD_NOTE = 4'd2, FIELD_FORCE = 4'd3, FIELD_KEYMAP = 4'd4,
        FIELD_OCTAVE = 4'd5, FIELD_EFFECT = 4'd6, FIELD_ADDITIVE = 4'd7,
        FIELD_POLYPHONY = 4'd8, FIELD_STRING = 4'd9,
        FIELD_EXPRESSION = 4'd10, FIELD_AUDITION = 4'd11, FIELD_STRENGTH = 4'd12;
    wire [1:0] expression_preset = (glide_select!=0) ? 2'd1 :
        (vibrato_select!=0) ? 2'd2 : 2'd0;
    localparam [2:0] FIELD_TABS = 3'd7;
    // selected_field is a page-local row; 7 always means the tabs.
    wire [3:0] edit_field = settings_page
        ? ((selected_field==0)?FIELD_EFFECT:(selected_field==1)?FIELD_STRENGTH:
           {1'b0, selected_field}+4'd5) : {1'b0, selected_field};
    localparam [PLAY_GUARD_COUNTER_WIDTH-1:0] PLAY_GUARD_LAST =
        PLAY_GUARD_CYCLES - 1;

    reg [2:0] key_pressed_d;
    reg setting_pressed_d;
    reg [PLAY_GUARD_COUNTER_WIDTH-1:0] play_guard_count;
    reg [2:0] play_pending;

    wire [2:0] key_press_pulse;
    wire setting_press_pulse;

    assign key_press_pulse = key_pressed & ~key_pressed_d;
    assign setting_press_pulse = setting_pressed & ~setting_pressed_d;
    assign play_mute = setting_mode | test_mode;
    assign status_payload = {
        test_polyphony,
        test_mode,
        effect_select,
        setting_mode,
        selected_field,
        play_mode,
        tone_select,
        note_select,
        force_value,
        keymap_select,
        octave_select,
        key_pressed
    };

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            key_pressed_d   <= 3'b000;
            setting_pressed_d <= 1'b0;
            play_guard_count <= {PLAY_GUARD_COUNTER_WIDTH{1'b0}};
            play_pending     <= 3'b000;
            play_trigger     <= 3'b000;
            setting_mode     <= 1'b0;
            settings_page    <= 1'b0;
            selected_field   <= FIELD_TABS;
            play_mode        <= 1'b1;
            tone_select      <= 2'd3;
            string_mode      <= 1'b0;
            note_select      <= 4'd0;
            force_value      <= 7'd96;
            keymap_select    <= 1'b1;
            octave_select    <= 2'd1;
            effect_select    <= 2'd0;
            effect_strength  <= 2'd1;
            glide_select     <= 2'd0;
            vibrato_select   <= 2'd0;
            audition_mode    <= 1'b0;
            audition_target  <= 3'd0;
            test_mode        <= 1'b0;
            test_polyphony   <= 1'b0;
        end else begin
            key_pressed_d <= key_pressed;
            setting_pressed_d <= setting_pressed;
            play_trigger <= 3'b000;

            if (setting_press_pulse) begin
                setting_mode <= ~setting_mode;
                if (!setting_mode) begin
                    selected_field <= FIELD_TABS;
                    test_mode <= 1'b0;
                    audition_mode <= 1'b0;
                end
            end

            if (setting_mode || setting_press_pulse ||
                (test_mode && !test_polyphony)) begin
                play_pending <= 3'b000;
                play_guard_count <= {PLAY_GUARD_COUNTER_WIDTH{1'b0}};
            end else if (|play_pending) begin
                if (play_guard_count == PLAY_GUARD_LAST) begin
                    play_trigger <= play_pending | key_press_pulse;
                    play_pending <= 3'b000;
                    play_guard_count <= {PLAY_GUARD_COUNTER_WIDTH{1'b0}};
                end else begin
                    play_pending <= play_pending | key_press_pulse;
                    play_guard_count <= play_guard_count
                                      + {{(PLAY_GUARD_COUNTER_WIDTH-1){1'b0}}, 1'b1};
                end
            end else if (|key_press_pulse) begin
                play_pending <= key_press_pulse;
                play_guard_count <= {PLAY_GUARD_COUNTER_WIDTH{1'b0}};
            end

            if (setting_mode && !setting_press_pulse) begin
                if ((|key_press_pulse) && edit_field!=FIELD_AUDITION)
                    audition_mode <= 1'b0;
                // A complete, audible preset avoids incompatible hidden settings.
                if (!key_press_pulse[0] &&
                    (((key_press_pulse[1] || key_press_pulse[2]) && edit_field==FIELD_EXPRESSION) ||
                     (key_press_pulse[2] && edit_field==FIELD_AUDITION))) begin
                    string_mode<=0; tone_select<=0; play_mode<=0;
                    note_select<=0; octave_select<=1; force_value<=96;
                    keymap_select<=0; test_mode<=0;
                    if(edit_field==FIELD_EXPRESSION) effect_select<=0;
                end
                if (key_press_pulse[0]) begin
                    if (selected_field == FIELD_TABS)
                        selected_field <= 3'd0;
                    else if (selected_field >= (settings_page?3'd6:3'd5))
                        selected_field <= FIELD_TABS;
                    else
                        selected_field <= selected_field + 3'd1;
                end else if ((selected_field == FIELD_TABS) &&
                             (key_press_pulse[1] || key_press_pulse[2])) begin
                    settings_page <= !key_press_pulse[1];
                    test_mode <= 1'b0;
                end else if (key_press_pulse[1]) begin
                    case (edit_field)
                        FIELD_MODE: play_mode <= ~play_mode;
                        FIELD_TONE: begin
                            if (string_mode) begin
                                string_mode <= 1'b0;
                                tone_select <= 2'd3;
                            end else if (tone_select == 2'd0) begin
                                string_mode <= 1'b1;
                                tone_select <= 2'd3;
                                test_mode <= 1'b0;
                            end else
                                tone_select <= tone_select - 2'd1;
                        end
                        FIELD_NOTE: begin
                            if (note_select == 4'd0)
                                note_select <= 4'd11;
                            else
                                note_select <= note_select - 4'd1;
                        end
                        FIELD_FORCE: begin
                            if (force_value <= 7'd16)
                                force_value <= 7'd127;
                            else
                                force_value <= force_value - 7'd16;
                        end
                        FIELD_KEYMAP: keymap_select <= ~keymap_select;
                        FIELD_OCTAVE: begin
                            if (octave_select == 2'd0)
                                octave_select <= 2'd2;
                            else
                                octave_select <= octave_select - 2'd1;
                        end
                        FIELD_EFFECT: begin
                            effect_select <= effect_select - 2'd1;
                            audition_target <= (effect_select==0)?3'd4:
                                (effect_select==3)?3'd3:3'd2;
                        end
                        FIELD_STRENGTH: effect_strength <= (effect_strength==0)?2'd2:effect_strength-2'd1;
                        FIELD_EXPRESSION: begin
                            glide_select <= (expression_preset==2) ? 2'd3 : 2'd0;
                            vibrato_select <= (expression_preset==0) ? 2'd3 : 2'd0;
                            audition_target <= (expression_preset==0)?3'd1:3'd0;
                        end
                        FIELD_AUDITION: begin
                            audition_mode <= 1'b0;
                            audition_target <= (audition_target==6)?3'd0:audition_target+3'd1;
                        end
                        FIELD_ADDITIVE, FIELD_POLYPHONY: test_mode <= 1'b0;
                        FIELD_STRING: begin
                            string_mode <= 1'b0;
                            tone_select <= 2'd3;
                            test_mode <= 1'b0;
                        end
                        default: begin end
                    endcase
                end else if (key_press_pulse[2]) begin
                    case (edit_field)
                        FIELD_MODE: play_mode <= ~play_mode;
                        FIELD_TONE: begin
                            if (string_mode) begin
                                string_mode <= 1'b0;
                                tone_select <= 2'd0;
                            end else if (tone_select == 2'd3) begin
                                string_mode <= 1'b1;
                                test_mode <= 1'b0;
                            end else
                                tone_select <= tone_select + 2'd1;
                        end
                        FIELD_NOTE: begin
                            if (note_select == 4'd11)
                                note_select <= 4'd0;
                            else
                                note_select <= note_select + 4'd1;
                        end
                        FIELD_FORCE: begin
                            if (force_value >= 7'd112)
                                force_value <= 7'd16;
                            else
                                force_value <= force_value + 7'd16;
                        end
                        FIELD_KEYMAP: keymap_select <= ~keymap_select;
                        FIELD_OCTAVE: begin
                            if (octave_select == 2'd2)
                                octave_select <= 2'd0;
                            else
                                octave_select <= octave_select + 2'd1;
                        end
                        FIELD_EFFECT: begin
                            effect_select <= effect_select + 2'd1;
                            audition_target <= (effect_select==0)?3'd2:
                                (effect_select==1)?3'd3:3'd4;
                        end
                        FIELD_STRENGTH: effect_strength <= (effect_strength==2)?2'd0:effect_strength+2'd1;
                        FIELD_ADDITIVE, FIELD_POLYPHONY: begin
                            test_mode <= 1'b1;
                            test_polyphony <= (edit_field == FIELD_POLYPHONY);
                        end
                        FIELD_EXPRESSION: begin
                            glide_select <= (expression_preset==0) ? 2'd3 : 2'd0;
                            vibrato_select <= (expression_preset==1) ? 2'd3 : 2'd0;
                            audition_target <= (expression_preset==1)?3'd1:3'd0;
                        end
                        FIELD_AUDITION: begin
                            audition_mode <= 1'b1;
                            glide_select<=(audition_target==0)?2'd3:2'd0;
                            vibrato_select<=(audition_target==1)?2'd3:2'd0;
                            effect_select<=(audition_target==2)?2'd1:
                                (audition_target==3)?2'd2:(audition_target==4)?2'd3:2'd0;
                            tone_select<=(audition_target>=2)?2'd3:2'd0;
                        end
                        FIELD_STRING: begin
                            string_mode <= 1'b1;
                            tone_select <= 2'd3;
                            test_mode <= 1'b0;
                        end
                        default: begin end
                    endcase
                end
            end
        end
    end

endmodule

`default_nettype wire
