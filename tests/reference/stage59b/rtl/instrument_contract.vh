// Include inside each consumer module (module-local parameters/functions).
// Protocol v2: fixed 28-bit controls / 68-bit display snapshot, audio_clk ->
// pixel_clk through status_bundle_cdc, committed only at LCD frame_start.
localparam integer CONTROL_STATUS_WIDTH = 28, DISPLAY_STATUS_WIDTH = 68;
localparam integer ST_HELD_NOTES = 56;
// Active song: bits 36..43 position, bit 50 done.
// Song context: bit 44 selection, bits 46..47 tempo. Settings keep deadlines.
// Other contexts retain their original meaning; the bundle commits atomically.
localparam integer ST_SONG_SELECT = 44, ST_SONG_TEMPO = 46;
localparam integer ST_SONG_ACCOMPANIMENT = 45;
// Active song only: keymap + force replaced by actual melody step count.
localparam integer ST_SONG_LENGTH = 5;
function [7:0] song_bpm;
    input [1:0] tempo;
    begin
        case(tempo)
            0:song_bpm=8'd80; 1:song_bpm=8'd100;
            2:song_bpm=8'd120; default:song_bpm=8'd150;
        endcase
    end
endfunction
localparam integer ST_KEYS = 0, ST_OCTAVE = 3, ST_KEYMAP = 5,
    ST_FORCE = 6, ST_NOTE = 13, ST_TONE = 17, ST_PLAY_MODE = 19,
    ST_FIELD = 20, ST_SETTING = 23, ST_EFFECT = 24, ST_TEST = 26,
    ST_POLYPHONY = 27, ST_VOICES = 28, ST_STRING = 34, ST_PAGE = 35,
    ST_DEADLINES = 36, ST_GLIDE = 44, ST_VIBRATO = 46,
    ST_AUDITION_ARMED = 48, ST_AUDITION_ACTIVE = 49,
    ST_AUDITION_WET = 50, ST_AUDITION_TARGET = 51, ST_STRENGTH = 54;

localparam [3:0] FIELD_MODE = 4'd0, FIELD_TONE = 4'd1,
    FIELD_NOTE = 4'd2, FIELD_FORCE = 4'd3, FIELD_KEYMAP = 4'd4,
    FIELD_OCTAVE = 4'd5, FIELD_EFFECT = 4'd6, FIELD_ADDITIVE = 4'd7,
    FIELD_POLYPHONY = 4'd8, FIELD_STRING = 4'd9,
    FIELD_EXPRESSION = 4'd10, FIELD_AUDITION = 4'd11,
    FIELD_STRENGTH = 4'd12, FIELD_KEYBOARD = 4'd13, FIELD_INVALID = 4'd15;
// Settings silence live keys, so their unused held-key slot carries the mode.
// Deadline/song metadata remains intact; the atomic CDC width stays 68 bits.
localparam integer ST_KEYBOARD_PIANO = ST_HELD_NOTES + 11;
localparam [2:0] FIELD_TABS = 3'd7, BASIC_LAST_ROW = 3'd5,
    EXTENSION_LAST_ROW = 3'd6;

// Page-local focus and global parameter ID must use the same map in the
// controller and renderer. Tabs/unused rows never alias an editable field.
function [3:0] settings_field_id;
    input page;
    input [2:0] row;
    begin
        settings_field_id = FIELD_INVALID;
        if (!page) begin
            if (row <= BASIC_LAST_ROW) settings_field_id = {1'b0, row};
        end else case (row)
            3'd0: settings_field_id = FIELD_EFFECT;
            3'd1: settings_field_id = FIELD_STRENGTH;
            3'd2: settings_field_id = FIELD_ADDITIVE;
            3'd3: settings_field_id = FIELD_POLYPHONY;
            3'd4: settings_field_id = FIELD_STRING;
            3'd5: settings_field_id = FIELD_EXPRESSION;
            3'd6: settings_field_id = FIELD_AUDITION;
            default: settings_field_id = FIELD_INVALID;
        endcase
    end
endfunction

// Configuration-aware row map shared by the controller and LCD. Disabled
// engines have no menu row; existing configurations retain the original map.
function [3:0] configured_settings_field_id;
    input page;
    input [2:0] row;
    input additive_enable, string_enable;
    integer old_row, visible_row;
    reg [3:0] field_id;
    begin
        configured_settings_field_id=FIELD_INVALID;
        visible_row=0;
        if(!page) configured_settings_field_id=settings_field_id(page,row);
        else for(old_row=0;old_row<7;old_row=old_row+1) begin
            field_id=settings_field_id(1'b1,old_row[2:0]);
            if((field_id!=FIELD_ADDITIVE || additive_enable) &&
               (field_id!=FIELD_STRING || string_enable)) begin
                if(row==visible_row) configured_settings_field_id=field_id;
                visible_row=visible_row+1;
            end
        end
    end
endfunction

function [3:0] keyboard_settings_field_id;
    input page;
    input [2:0] row;
    input additive_enable, string_enable, keyboard_enable;
    reg [2:0] keyboard_row;
    begin
        keyboard_row=3'd7-(additive_enable?3'd0:3'd1)-(string_enable?3'd0:3'd1);
        keyboard_settings_field_id=configured_settings_field_id(page,row,additive_enable,string_enable);
        // Row 7 remains the tabs. Full legacy configurations keep their layout.
        if(page && keyboard_enable && keyboard_row<3'd7 && row==keyboard_row)
            keyboard_settings_field_id=FIELD_KEYBOARD;
    end
endfunction

localparam DEFAULT_PLAY_MODE = 1'b1, DEFAULT_STRING = 1'b0,
    DEFAULT_KEYMAP = 1'b1;
localparam [1:0] DEFAULT_TONE = 2'd3, DEFAULT_OCTAVE = 2'd1,
    DEFAULT_EFFECT = 2'd0, DEFAULT_STRENGTH = 2'd1;
localparam [3:0] DEFAULT_NOTE = 4'd0;
localparam [6:0] DEFAULT_FORCE = 7'd96;
localparam [CONTROL_STATUS_WIDTH-1:0] DEFAULT_CONTROL_STATUS = {
    2'b00, DEFAULT_EFFECT, 1'b0, FIELD_TABS, DEFAULT_PLAY_MODE,
    DEFAULT_TONE, DEFAULT_NOTE, DEFAULT_FORCE, DEFAULT_KEYMAP,
    DEFAULT_OCTAVE, 3'b000
};
localparam [DISPLAY_STATUS_WIDTH-1:0] DEFAULT_DISPLAY_STATUS = {
    12'd0, DEFAULT_STRENGTH, 6'd0, 4'd0, 8'd0, 1'b0, DEFAULT_STRING,
    6'd0, DEFAULT_CONTROL_STATUS
};
