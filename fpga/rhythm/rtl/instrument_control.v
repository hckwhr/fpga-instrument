`default_nettype none

module instrument_control #(parameter integer CE_ENABLE=0,
    parameter integer ADDITIVE_BANK_ENABLE=1,
    parameter integer STRING_BANK_ENABLE=1,
    parameter integer LEGACY_VOICE_ENABLE=1,
    parameter integer REMOTE_SELECT_ENABLE=0,
    parameter integer KEYBOARD_MODE_ENABLE=0,
    parameter integer MULTI_TIMBRE_ENABLE=0,
    
    parameter integer PLAY_GUARD_CYCLES = 98_304,
    parameter integer PLAY_GUARD_COUNTER_WIDTH = 17
) (
    input wire clock_enable,
    
    input  wire        clk,
    input  wire        reset_n,
    input  wire [2:0]  key_pressed,
    input  wire        setting_pressed,
    input  wire        remote_song_start,
    input wire remote_select_request, remote_select_id,
    output reg remote_select_done, remote_select_ok,
    output reg  [2:0]  play_trigger,
    output wire        play_mute,
    // Measured 2026-10-09: syn_maxfan=8 on this net was tried and REVERTED.
    // It did reduce the fanout, but the replicas scattered across the die and
    // setup violations went from 22 (TNS -1.083 ns) to 750 (TNS -862.722 ns).
    // The worst path here is wire-dominated; forcing replication makes the
    // placement worse, not better. Do not re-apply without new measurements.
    output reg          setting_mode,
    output reg          settings_page,
    output reg  [2:0]  selected_field,
    output reg          play_mode,
    output reg  [1:0]  tone_select,
    output reg  [1:0]  instrument_select,
    output reg         string_mode,
    output reg         keyboard_piano,
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
    output reg         song_select,
    output reg         song_accompaniment,
    output reg [1:0]   song_tempo,
    output wire        song_change,
    output reg          test_mode,
    // Stage 30b: registered copies of the three mode decodes av_top used to
    // build combinationally. Written from next-state values, so each equals
    // its decode of audition_mode/audition_target/setting_mode/test_mode on
    // every clock (checked by tb_song_page_mirror).
    output reg          audition_active,
    output reg          song_active,
    output reg          self_test_active,
    output reg          test_polyphony,
    // Second press on the 32-voice field: all three engines sound together so
    // a spectrum capture can count every independent unit.
    output reg          test_concurrent,
    output wire [27:0] status_payload
);

    `include "instrument_contract.vh"
    wire [1:0] expression_preset = (glide_select!=0) ? 2'd1 :
        (vibrato_select!=0) ? 2'd2 : 2'd0;
    // selected_field is a page-local row; 7 always means the tabs.
    wire [3:0] mapped_field = keyboard_settings_field_id(settings_page, selected_field,
        ADDITIVE_BANK_ENABLE!=0,STRING_BANK_ENABLE!=0,KEYBOARD_MODE_ENABLE!=0);
    wire [3:0] edit_field = MULTI_TIMBRE_ENABLE && mapped_field==FIELD_KEYBOARD
        ? FIELD_WAVEFORM : mapped_field;
    localparam [2:0] ENABLED_EXTENSION_LAST_ROW = 3'd6 -
        (ADDITIVE_BANK_ENABLE ? 3'd0 : 3'd1) - (STRING_BANK_ENABLE ? 3'd0 : 3'd1) +
        ((KEYBOARD_MODE_ENABLE && (!ADDITIVE_BANK_ENABLE || !STRING_BANK_ENABLE)) ? 3'd1 : 3'd0);
    localparam [PLAY_GUARD_COUNTER_WIDTH-1:0] PLAY_GUARD_LAST =
        (CE_ENABLE ? (PLAY_GUARD_CYCLES+1)/2 : PLAY_GUARD_CYCLES) - 1;

    reg [2:0] key_pressed_d;
    reg setting_pressed_d;
    reg [PLAY_GUARD_COUNTER_WIDTH-1:0] play_guard_count;
    reg [2:0] play_pending;

    wire [2:0] key_press_pulse;
    wire setting_press_pulse;

    assign key_press_pulse = key_pressed & ~key_pressed_d;
    assign setting_press_pulse = setting_pressed & ~setting_pressed_d;
    // Only the song performance page owns KEY0 selection. No held-key repeats.
    // Combinational request lets the scheduler flush on the selection edge.
    // Stage 30 timing: the routed stage-29 worst cluster (20 of 25 paths,
    // -0.092 ns) started at setting_mode, crossed a 3.0 ns net into this
    // decode and then ran through the score flush and event handshake into the
    // 32 polyphony lanes. song_page holds the key-independent part of that
    // decode. It is written from the same next-state values as the three
    // registers it summarises, on the same edge, so on every clock it equals
    //   audition_mode && audition_target==3'd7 && !setting_mode
    // and song_change is unchanged cycle for cycle.
    reg song_page;
    reg setting_mode_n, audition_mode_n, test_mode_n;
    reg [2:0] audition_target_n;
    assign song_change = song_page &&
        !setting_pressed && key_press_pulse[0] && !key_pressed[1];
    assign play_mute = setting_mode | test_mode;
    assign status_payload[ST_POLYPHONY] = test_polyphony;
    assign status_payload[ST_TEST] = test_mode;
    assign status_payload[ST_EFFECT +: 2] = effect_select;
    assign status_payload[ST_SETTING] = setting_mode;
    assign status_payload[ST_FIELD +: 3] = selected_field;
    assign status_payload[ST_PLAY_MODE] = play_mode;
    assign status_payload[ST_TONE +: 2] = tone_select;
    assign status_payload[ST_NOTE +: 4] = note_select;
    assign status_payload[ST_FORCE +: 7] = force_value;
    assign status_payload[ST_KEYMAP] = keymap_select;
    assign status_payload[ST_OCTAVE +: 2] = octave_select;
    assign status_payload[ST_KEYS +: 3] = key_pressed;

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
            play_mode        <= DEFAULT_PLAY_MODE;
            tone_select      <= DEFAULT_TONE;
            instrument_select <= 2'd0;
            string_mode      <= DEFAULT_STRING;
            keyboard_piano   <= MULTI_TIMBRE_ENABLE!=0;
            note_select      <= DEFAULT_NOTE;
            force_value      <= DEFAULT_FORCE;
            keymap_select    <= DEFAULT_KEYMAP;
            octave_select    <= DEFAULT_OCTAVE;
            effect_select    <= DEFAULT_EFFECT;
            effect_strength  <= DEFAULT_STRENGTH;
            glide_select     <= 2'd0;
            vibrato_select   <= 2'd0;
            audition_mode    <= 1'b0;
            audition_target  <= LEGACY_VOICE_ENABLE ? 3'd0 : 3'd7;
            song_select      <= 1'b0;
            remote_select_done<=0; remote_select_ok<=0;
            song_accompaniment <= 1'b0;
            song_tempo       <= 2'd1;
            test_mode        <= 1'b0;
            test_polyphony   <= 1'b0;
            test_concurrent  <= 1'b0;
            song_page        <= 1'b0;
            audition_active  <= 1'b0;
            song_active      <= 1'b0;
            self_test_active <= 1'b0;
        end else if ((!CE_ENABLE || clock_enable)) begin
            // Blocking next-state copies: every later write to these three
            // registers goes through them so song_page can mirror the result.
            // Reads below still see the registers themselves, i.e. the old value.
            setting_mode_n    = setting_mode;
            audition_mode_n   = audition_mode;
            audition_target_n = audition_target;
            test_mode_n       = test_mode;
            key_pressed_d <= key_pressed;
            setting_pressed_d <= setting_pressed;
            play_trigger <= 3'b000;
            remote_select_done<=0; remote_select_ok<=0;
            if(REMOTE_SELECT_ENABLE && remote_select_request) begin
                remote_select_done<=1;
                if(!setting_mode && !setting_pressed && !key_pressed[1]) begin
                    song_select<=remote_select_id; song_accompaniment<=0;
                    remote_select_ok<=1;
                end
            end
            // KEY0 cycles Twinkle solo -> Ode solo -> Ode ensemble -> Twinkle.
            if (song_change && !(REMOTE_SELECT_ENABLE && remote_select_request)) begin
                if(!song_select && !song_accompaniment) song_select<=1'b1;
                else if(!song_accompaniment) song_accompaniment<=1'b1;
                else if(song_select) song_select<=1'b0;
                else song_accompaniment<=1'b0;
            end

            if (setting_press_pulse) begin
                setting_mode_n = ~setting_mode;
                if (!setting_mode) begin
                    selected_field <= FIELD_TABS;
                    test_mode_n = 1'b0;
                    audition_mode_n = 1'b0;
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
                    audition_mode_n = 1'b0;
                // A complete, audible preset avoids incompatible hidden settings.
                if (!key_press_pulse[0] &&
                    (((key_press_pulse[1] || key_press_pulse[2]) && edit_field==FIELD_EXPRESSION) ||
                     (key_press_pulse[2] && edit_field==FIELD_AUDITION))) begin
                    string_mode<=0; tone_select<=0; play_mode<=0;
                    instrument_select<=0;
                    note_select<=0; octave_select<=1; force_value<=96;
                    keymap_select<=0; test_mode_n = 0;
                    if(edit_field==FIELD_EXPRESSION) effect_select<=0;
                end
                if (key_press_pulse[0]) begin
                    if (selected_field == FIELD_TABS)
                        selected_field <= 3'd0;
                    else if (selected_field >= (settings_page ? ENABLED_EXTENSION_LAST_ROW : BASIC_LAST_ROW))
                        selected_field <= FIELD_TABS;
                    else
                        selected_field <= selected_field + 3'd1;
                end else if ((selected_field == FIELD_TABS) &&
                             (key_press_pulse[1] || key_press_pulse[2])) begin
                    settings_page <= !key_press_pulse[1];
                    test_mode_n = 1'b0;
                end else if (key_press_pulse[1]) begin
                    case (edit_field)
                        FIELD_KEYBOARD: keyboard_piano <= ~keyboard_piano;
                        FIELD_WAVEFORM: begin
                            tone_select <= tone_select==0 ? 2'd2 : tone_select-2'd1;
                            string_mode<=0; instrument_select<=0; test_mode_n=0;
                        end
                        FIELD_MODE: play_mode <= ~play_mode;
                        FIELD_TONE: begin
                            if (MULTI_TIMBRE_ENABLE) begin
                                // Piano -> strings -> flute -> clarinet -> organ.
                                // Pitch layout is independent and stays diatonic.
                                tone_select<=2'd3; test_mode_n=0;
                                if(string_mode) begin string_mode<=0; instrument_select<=0; end
                                else if(instrument_select!=0) begin
                                    instrument_select<=instrument_select-2'd1;
                                    if(instrument_select==1) string_mode<=STRING_BANK_ENABLE!=0;
                                end else instrument_select<=2'd3;
                            end else if (string_mode) begin
                                string_mode <= 1'b0;
                                tone_select <= 2'd3;
                            end else if (tone_select == 2'd0) begin
                                string_mode <= STRING_BANK_ENABLE!=0;
                                tone_select <= 2'd3;
                                test_mode_n = 1'b0;
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
                            audition_target_n = (effect_select==0)?3'd4:
                                (effect_select==3)?3'd3:3'd2;
                        end
                        FIELD_STRENGTH: effect_strength <= (effect_strength==0)?2'd2:effect_strength-2'd1;
                        FIELD_EXPRESSION: begin
                            glide_select <= (expression_preset==2) ? 2'd3 : 2'd0;
                            vibrato_select <= (expression_preset==0) ? 2'd3 : 2'd0;
                            audition_target_n = (expression_preset==0)?3'd1:3'd0;
                        end
                        FIELD_AUDITION: begin
                            audition_mode_n = 1'b0;
                            audition_target_n = (!STRING_BANK_ENABLE && audition_target==3'd5)
                                ? 3'd7 : audition_target+3'd1;
                        end
                        FIELD_ADDITIVE, FIELD_POLYPHONY: test_mode_n = 1'b0;
                        FIELD_STRING: begin
                            instrument_select <= 0;
                            string_mode <= 1'b0;
                            tone_select <= 2'd3;
                            test_mode_n = 1'b0;
                        end
                        default: begin end
                    endcase
                end else if (key_press_pulse[2]) begin
                    case (edit_field)
                        FIELD_KEYBOARD: keyboard_piano <= ~keyboard_piano;
                        FIELD_WAVEFORM: begin
                            tone_select <= tone_select>=2 ? 2'd0 : tone_select+2'd1;
                            string_mode<=0; instrument_select<=0; test_mode_n=0;
                        end
                        FIELD_MODE: play_mode <= ~play_mode;
                        FIELD_TONE: begin
                            if (MULTI_TIMBRE_ENABLE) begin
                                tone_select<=2'd3; test_mode_n=0;
                                if(tone_select!=3) begin string_mode<=0; instrument_select<=0; end
                                else if(string_mode) begin string_mode<=0; instrument_select<=1; end
                                else if(instrument_select!=0) instrument_select<=instrument_select+2'd1;
                                else if(STRING_BANK_ENABLE) string_mode<=1;
                                else instrument_select<=1;
                            end else if (string_mode) begin
                                string_mode <= 1'b0;
                                tone_select <= 2'd0;
                            end else if (tone_select == 2'd3) begin
                                string_mode <= STRING_BANK_ENABLE!=0;
                                if(!STRING_BANK_ENABLE) tone_select <= 2'd0;
                                test_mode_n = 1'b0;
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
                            audition_target_n = (effect_select==0)?3'd2:
                                (effect_select==1)?3'd3:3'd4;
                        end
                        FIELD_STRENGTH: effect_strength <= (effect_strength==2)?2'd0:effect_strength+2'd1;
                        FIELD_ADDITIVE, FIELD_POLYPHONY: begin
                            test_mode_n = 1'b1;
                            test_polyphony <= (edit_field == FIELD_POLYPHONY);
                            // off -> 32 voices -> all 72 units -> off. Reads
                            // the registers, i.e. the state before this press.
                            // The contest configuration starts the same 32-note
                            // event self-test immediately; no absent-engine mode.
                            test_concurrent <= (!ADDITIVE_BANK_ENABLE) ||
                                (test_mode && test_polyphony && !test_concurrent &&
                                 (edit_field == FIELD_POLYPHONY));
                        end
                        FIELD_EXPRESSION: begin
                            glide_select <= (expression_preset==0) ? 2'd3 : 2'd0;
                            vibrato_select <= (expression_preset==1) ? 2'd3 : 2'd0;
                            audition_target_n = (expression_preset==1)?3'd1:3'd0;
                        end
                        FIELD_AUDITION: begin
                            audition_mode_n = 1'b1;
                            if (audition_target==3'd7 && audition_mode)
                                song_tempo <= song_tempo + 2'd1;
                            glide_select<=(audition_target==0)?2'd3:2'd0;
                            vibrato_select<=(audition_target==1)?2'd3:2'd0;
                            effect_select<=(audition_target==2)?2'd1:
                                (audition_target==3)?2'd2:(audition_target==4)?2'd3:2'd0;
                            tone_select<=(audition_target>=2)?2'd3:2'd0;
                        end
                        FIELD_STRING: begin
                            instrument_select <= 0;
                            string_mode <= STRING_BANK_ENABLE!=0;
                            tone_select <= 2'd3;
                            test_mode_n = 1'b0;
                        end
                        default: begin end
                    endcase
                end
            end
            // The local settings/stop keys own safety. Remote PLAY selects the
            // same complete preset as the existing song menu, not another mixer.
            if (remote_song_start && !setting_mode && !setting_pressed && !key_pressed[1]) begin
                audition_mode_n = 1; audition_target_n = 7; test_mode_n = 0;
                string_mode<=0; tone_select<=3; play_mode<=0;
                instrument_select<=0;
                note_select<=0; octave_select<=1; force_value<=96;
                keymap_select<=0; glide_select<=0; vibrato_select<=0; effect_select<=0;
                play_pending<=0; play_trigger<=0;
            end
            setting_mode    <= setting_mode_n;
            audition_mode   <= audition_mode_n;
            // av_top routes non-score auditions through the existing 32-voice
            // bank when the legacy DDS is disabled. Never clamp the selection:
            // that used to trap KEY1 on the score target on every clock.
            audition_target <= audition_target_n;
            song_page       <= audition_mode_n && audition_target_n==3'd7 && !setting_mode_n;
            test_mode        <= test_mode_n;
            // Leaving the self-test always drops the concurrent sub-mode.
            if (!test_mode_n) test_concurrent <= 1'b0;
            audition_active  <= audition_mode_n && !setting_mode_n && !test_mode_n;
            song_active      <= audition_mode_n && !setting_mode_n && !test_mode_n && audition_target_n==3'd7;
            self_test_active <= test_mode_n && !setting_mode_n;
        end
    end

endmodule

`default_nettype wire
