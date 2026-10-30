`default_nettype none

// Frozen stage67 dashboard baseline. The LCD-era stage66d reference is archived
// instead: the product is the HDMI build, and this copy pins the layout that
// was accepted on hardware so later renderer changes are still caught pixel by
// pixel. Panel geometry is unchanged from stage67; only the scope amplitude and
// the XY phase portrait differ from the version frozen before them.

// Portable instrument dashboard: frame-atomic status and synchronous waveform
// history retained from the accepted LCD renderer; no LCD controller or pins.
module stage67_panel_reference #(parameter integer COMPACT_SCOPE=0, parameter integer UPLOAD_UI=0,
    parameter integer LIVE_KEYBOARD=0, parameter integer ADDITIVE_BANK_ENABLE=1,
    parameter integer STRING_BANK_ENABLE=1, parameter integer KEYBOARD_MODE_ENABLE=0) (
    input  wire               pixel_clk,
    input  wire               reset_n,
    input  wire [10:0]        active_x,
    input  wire [10:0]        next_active_x,
    input  wire [9:0]         active_y,
    input  wire [9:0]         predecode_y,
    input  wire               data_enable,
    input  wire               hsync_in,
    input  wire               vsync_in,
    input  wire               frame_start,
    input  wire signed [15:0] audio_sample,
    input  wire               audio_sample_valid,
    input  wire [67:0]        status_payload,
    input  wire               status_update,
    input  wire [11:0]        upload_status,
    output reg [5:0]          red,
    output reg [5:0]          green,
    output reg [5:0]          blue,
    output reg               hsync_out,
    output reg               vsync_out,
    output reg               de_out
);

    `include "instrument_contract.vh"
    localparam [DISPLAY_STATUS_WIDTH-1:0] DEFAULT_STATUS = DEFAULT_DISPLAY_STATUS;

    reg signed [7:0] sample_history [0:511];
    reg [7:0]        capture_write_ptr;
    reg              capture_bank;
    reg              capture_ready;
    reg              capture_active;
    reg              capture_trigger_armed;
    reg              capture_test_mode_d;
    reg [1:0]        capture_sample_divider;
    reg [9:0]        trigger_wait_samples;
    reg              display_bank;
    reg              display_valid;
    reg [DISPLAY_STATUS_WIDTH-1:0]       status_shadow;
    reg [DISPLAY_STATUS_WIDTH-1:0]       status_active;
    // The extension travels in the same CDC transaction and frame commit.
    reg [11:0] upload_shadow,upload_active;
    wire uploaded_song=UPLOAD_UI!=0 && upload_active[3];
    wire [1:0] effect_strength_active = status_active[ST_STRENGTH +: 2];
    wire [2:0] audition_target = status_active[ST_AUDITION_TARGET +: 3];
    wire audition_wet = status_active[ST_AUDITION_WET];
    wire audition_active = status_active[ST_AUDITION_ACTIVE];
    wire audition_armed = status_active[ST_AUDITION_ARMED];
    wire [11:0] song_position = {uploaded_song ? upload_active[11:8] : 4'd0,status_active[ST_DEADLINES +: 8]} + 12'd1;
    wire song_select = status_active[ST_SONG_SELECT];
    wire song_accompaniment = status_active[ST_SONG_ACCOMPANIMENT];
    wire [11:0] song_length = {uploaded_song ? upload_active[7:4] : 4'd0,status_active[ST_SONG_LENGTH +: 8]};
    wire [7:0] tempo_bpm = song_bpm(status_active[ST_SONG_TEMPO +: 2]);
    wire song_context = audition_target==7 && (audition_active ||
        (status_active[ST_SETTING] && configured_settings_field_id(
            status_active[ST_PAGE],status_active[ST_FIELD +: 3],
            ADDITIVE_BANK_ENABLE!=0,STRING_BANK_ENABLE!=0)==FIELD_AUDITION));
    wire [1:0] glide_active = song_context ? 2'd0 : status_active[ST_GLIDE +: 2];
    wire [1:0] vibrato_active = song_context ? 2'd0 : status_active[ST_VIBRATO +: 2];
    wire [7:0] string_deadline_misses = status_active[ST_DEADLINES +: 8];
    wire string_count_visible = status_active[ST_STRING] && !status_active[ST_TEST];
    wire string_mode_active = status_active[ST_STRING];
    wire settings_page_active = status_active[ST_PAGE];
    reg [7:0]        audio_level_peak;
    reg [7:0]        audio_level_active;

    wire [10:0] scope_x;
    wire [10:0] scope_x_next;
    wire [7:0]  scope_index_next;
    wire [8:0]  history_read_addr;
    wire [8:0]  history_next_read_addr;
    reg  signed [7:0]  history_sample;
    reg  signed [7:0]  history_next_sample;
    wire signed [8:0]  history_delta;
    wire signed [10:0] history_sample_ext;
    wire signed [10:0] history_sample_scaled;
    wire signed [10:0] history_next_sample_ext;
    wire signed [10:0] history_next_sample_scaled;
    wire signed [10:0] history_delta_ext;
    reg  signed [10:0] wave_sample_scaled;
    wire signed [10:0] wave_y;
    wire signed [10:0] wave_next_y;
    wire signed [10:0] square_edge_min_y;
    wire signed [10:0] square_edge_max_y;
    wire               square_edge_pixel;
    wire signed [10:0] active_y_signed;

    wire       setting_mode_active;
    wire [2:0] selected_field_active;
    wire       play_mode_active;
    wire [1:0] tone_select_active;
    wire [3:0] note_select_active;
    wire [6:0] force_value_active;
    wire       keymap_select_active;
    wire [1:0] octave_select_active;
    wire [2:0] key_pressed_active;
    wire [1:0] effect_select_active;
    wire       test_mode_active;
    wire       test_polyphony_active;
    wire [5:0] polyphony_voice_count_active;
    wire [11:0] song_notes_active = status_active[ST_HELD_NOTES +: 12];
    wire [3:0] polyphony_count_tens;
    wire [3:0] polyphony_count_ones;
    wire [3:0] force_hundreds;
    wire [3:0] force_tens;
    wire [3:0] force_ones;

    wire status_panel_region;
    wire status_panel_border;
    wire status_text_region;
    wire [10:0] status_text_x;
    wire [4:0]  status_character_index;
    wire [4:0]  status_cell_x;
    wire [4:0]  status_glyph_column;
    wire [7:0]  status_glyph_index;
    wire [23:0] status_glyph_bits;
    wire        status_glyph_on;
    wire        status_count_slash_pixel;
    wire        status_line_selected;
    wire        settings_title_bar_region;
    wire        settings_title_bar_border;
    wire [10:0] settings_title_character_index;
    wire        settings_title_right;
    wire        settings_title_selected;
    wire [10:0] settings_title_text_x;
    wire [10:0] settings_title_glyph_column;
    wire [7:0]  settings_title_glyph_index;
    wire [23:0] settings_title_glyph_bits;
    wire        settings_title_glyph_on;
    wire        settings_panel_region;
    wire        settings_panel_border;
    wire        settings_row_region;
    wire [3:0]  settings_field_index;
    wire        settings_row_border;
    wire        settings_row_selected;
    wire [10:0] settings_text_x;
    wire [10:0] settings_character_index;
    wire [10:0] settings_cell_x;
    wire [10:0] settings_glyph_column;
    wire [7:0]  settings_glyph_index;
    wire [23:0] settings_glyph_bits;
    wire        settings_glyph_on;
    wire        settings_hint_region;
    wire [10:0] settings_hint_x;
    wire [10:0] settings_hint_character;
    wire [10:0] settings_hint_column;
    wire [7:0]  settings_hint_index;
    wire [23:0] settings_hint_bits;
    wire        settings_hint_on;
    wire [15:0] audio_sample_abs;
    wire [7:0]  audio_level_sample;
    wire signed [7:0] capture_sample;
    wire scope_trigger_low;
    wire scope_trigger_high;
    wire [10:0] status_level_fill_end;
    wire        status_level_border;
    wire        status_level_fill;
    wire [3:0]  piano_note_index;
    wire        piano_note_valid;
    wire        piano_note_is_black;
    wire        piano_note_selected;
    wire        piano_note_pressed;
    wire [4:0]  piano_relative_note;
    wire        piano_polyphony_pressed;
    wire [3:0]  piano_chord_root_offset;
    wire [4:0]  piano_root_sum;
    wire [4:0]  piano_third_sum;
    wire [4:0]  piano_fifth_sum;
    wire [3:0]  piano_root_note;
    wire [3:0]  piano_third_note;
    wire [3:0]  piano_fifth_note;
    wire        piano_key_border;
    wire [10:0] piano_label_x_origin;
    wire [9:0]  piano_label_y_origin;
    wire [1:0]  piano_label_character_index;
    wire [4:0]  piano_label_column;
    wire [4:0]  piano_label_row;
    wire [5:0]  piano_label_glyph_index;
    wire [23:0] piano_label_glyph_bits;
    wire        piano_label_region;
    wire        piano_label_on;
    reg [7:0]  font_lookup_index;
    reg [4:0]  font_lookup_row;
    reg [23:0] shared_font_bits;
    reg [23:0] font_memory [0:8191];
    reg [4:0] font_lookup_column;
    reg [5:0] base_red, base_green, base_blue;
    reg [5:0] text_red, text_green, text_blue;
    reg text_enable, text_force;
    reg [17:0] background_q, foreground_q;
    reg [4:0] font_column_q;
    reg text_enable_q, text_force_q;


    // Row metadata is captured alongside the EXISTING top-level raster stage.
    // predecode_y is that stage's input; active_y is its output. No pixel or
    // HS/VS/DE latency is added. Re-evaluate on row/window boundary or frame
    // commit only. Production raster has 1100 render clocks/line (repeat=2).
    // Horizontal blanking uses y=1023; decode it too so the first/last active
    // pixel and sentinel transitions retain the original cycle semantics.
    // No timing exception is implied: the predecode input path remains STA'd
    // at one render clock. Sample-dependent waveform comparisons stay per-pixel.
    wire decode_page = frame_start ? (status_update ? status_payload[ST_PAGE]
        : status_shadow[ST_PAGE]) : settings_page_active;
    reg [9:0] decoded_y;
    reg decoded_page;
    reg [122:0] line_metadata;
    wire [9:0] status_text_y;
    wire [2:0] status_line_index;
    wire [4:0] status_glyph_row;
    wire [9:0] settings_title_glyph_row;
    wire [2:0] settings_row_index;
    wire [9:0] settings_row_origin_y;
    wire [9:0] settings_row_y;
    wire [9:0] settings_glyph_row;
    wire [9:0] settings_hint_row;
    wire line_settings_rows;
    wire line_settings_border;
    wire line_settings_text;
    wire line_scope;
    wire line_scope_border;
    wire line_scope_grid;
    wire line_y_ge_45;
    wire line_y_lt_72;
    wire line_y_eq_45;
    wire line_y_eq_71;
    wire line_y_ge_51;
    wire line_y_lt_66;
    wire line_y_ge_8;
    wire line_y_lt_88;
    wire line_y_eq_8;
    wire line_y_eq_87;
    wire line_y_ge_14;
    wire line_y_lt_70;
    wire line_y_ge_12;
    wire line_y_lt_60;
    wire line_y_eq_12;
    wire line_y_eq_59;
    wire line_y_ge_24;
    wire line_y_lt_48;
    wire line_y_ge_68;
    wire line_y_lt_400;
    wire line_y_eq_68;
    wire line_y_eq_399;
    wire line_y_ge_412;
    wire line_y_lt_472;
    wire line_y_lt_82;
    wire line_y_eq_81;
    wire line_hint_second;
    wire line_status_glyph_valid;
    wire line_status_index_valid;
    wire line_hint_valid;
    wire line_black_key;
    wire line_white_key;
    wire line_black_border;
    wire line_white_border;
    wire line_black_label;
    wire line_white_label;
    wire [4:0] line_black_label_row;
    wire [4:0] line_white_label_row;
    assign {status_text_y, status_line_index, status_glyph_row, settings_title_glyph_row, settings_row_index, settings_row_origin_y, settings_row_y, settings_glyph_row, settings_hint_row, line_settings_rows, line_settings_border, line_settings_text, line_scope, line_scope_border, line_scope_grid, line_y_ge_45, line_y_lt_72, line_y_eq_45, line_y_eq_71, line_y_ge_51, line_y_lt_66, line_y_ge_8, line_y_lt_88, line_y_eq_8, line_y_eq_87, line_y_ge_14, line_y_lt_70, line_y_ge_12, line_y_lt_60, line_y_eq_12, line_y_eq_59, line_y_ge_24, line_y_lt_48, line_y_ge_68, line_y_lt_400, line_y_eq_68, line_y_eq_399, line_y_ge_412, line_y_lt_472, line_y_lt_82, line_y_eq_81, line_hint_second, line_status_glyph_valid, line_status_index_valid, line_hint_valid, line_black_key, line_white_key, line_black_border, line_white_border, line_black_label, line_white_label, line_black_label_row, line_white_label_row} = line_metadata;
    function [122:0] decode_line;
        input [9:0] y;
        input page;
        reg [9:0] status_text_y;
        reg [2:0] status_line_index;
        reg [4:0] status_glyph_row;
        reg [9:0] settings_title_glyph_row;
        reg [2:0] settings_row_index;
        reg [9:0] settings_row_origin_y;
        reg [9:0] settings_row_y;
        reg [9:0] settings_glyph_row;
        reg [9:0] settings_hint_row;
        reg [0:0] line_settings_rows;
        reg [0:0] line_settings_border;
        reg [0:0] line_settings_text;
        reg [0:0] line_scope;
        reg [0:0] line_scope_border;
        reg [0:0] line_scope_grid;
        reg [0:0] line_y_ge_45;
        reg [0:0] line_y_lt_72;
        reg [0:0] line_y_eq_45;
        reg [0:0] line_y_eq_71;
        reg [0:0] line_y_ge_51;
        reg [0:0] line_y_lt_66;
        reg [0:0] line_y_ge_8;
        reg [0:0] line_y_lt_88;
        reg [0:0] line_y_eq_8;
        reg [0:0] line_y_eq_87;
        reg [0:0] line_y_ge_14;
        reg [0:0] line_y_lt_70;
        reg [0:0] line_y_ge_12;
        reg [0:0] line_y_lt_60;
        reg [0:0] line_y_eq_12;
        reg [0:0] line_y_eq_59;
        reg [0:0] line_y_ge_24;
        reg [0:0] line_y_lt_48;
        reg [0:0] line_y_ge_68;
        reg [0:0] line_y_lt_400;
        reg [0:0] line_y_eq_68;
        reg [0:0] line_y_eq_399;
        reg [0:0] line_y_ge_412;
        reg [0:0] line_y_lt_472;
        reg [0:0] line_y_lt_82;
        reg [0:0] line_y_eq_81;
        reg [0:0] line_hint_second;
        reg [0:0] line_status_glyph_valid;
        reg [0:0] line_status_index_valid;
        reg [0:0] line_hint_valid;
        reg [0:0] line_black_key;
        reg [0:0] line_white_key;
        reg [0:0] line_black_border;
        reg [0:0] line_white_border;
        reg [0:0] line_black_label;
        reg [0:0] line_white_label;
        reg [4:0] line_black_label_row;
        reg [4:0] line_white_label_row;
        begin
            status_text_y = y - 10'd14;
            status_line_index = status_text_y / 10'd30;
            status_glyph_row = status_text_y
                            - (status_line_index * 6'd30);
            settings_title_glyph_row = y - 10'd24;
            settings_row_index = settings_row_at(y, page);
            settings_row_origin_y = settings_row_origin(settings_row_index, page);
            settings_row_y = y - settings_row_origin_y;
            settings_glyph_row = settings_row_y - (page?10'd10:10'd14);
            settings_hint_row = (y < 10'd442)
        ? y - 10'd412 : y - 10'd446;
            line_settings_rows = (y >= 10'd80) &&
        (y < (page ? (10'd388 -
            (ADDITIVE_BANK_ENABLE ? 10'd0 : 10'd44) -
            (STRING_BANK_ENABLE ? 10'd0 : 10'd44) +
            ((KEYBOARD_MODE_ENABLE && (!ADDITIVE_BANK_ENABLE || !STRING_BANK_ENABLE)) ? 10'd44 : 10'd0)) : 10'd392));
            line_settings_border = (settings_row_y == 10'd0) || (settings_row_y == (page?10'd43:10'd51));
            line_settings_text = (settings_row_y >= (page?10'd10:10'd14)) &&
        (settings_row_y < (page?10'd34:10'd38));
            line_scope = (y >= (COMPACT_SCOPE ? 10'd252 : 10'd250)) && (y < (COMPACT_SCOPE ? 10'd334 : 10'd468));
            line_scope_border = (y == (COMPACT_SCOPE ? 10'd252 : 10'd250)) || (y == (COMPACT_SCOPE ? 10'd333 : 10'd467));
            line_scope_grid = ((y - 10'd244) & 10'h01f) == 10'd0;
            line_y_ge_45 = (y >= 10'd45);
            line_y_lt_72 = (y < 10'd72);
            line_y_eq_45 = (y == 10'd45);
            line_y_eq_71 = (y == 10'd71);
            line_y_ge_51 = (y >= 10'd51);
            line_y_lt_66 = (y < 10'd66);
            line_y_ge_8 = (y >= 10'd8);
            line_y_lt_88 = (y < 10'd88);
            line_y_eq_8 = (y == 10'd8);
            line_y_eq_87 = (y == 10'd87);
            line_y_ge_14 = (y >= 10'd14);
            line_y_lt_70 = (y < 10'd70);
            line_y_ge_12 = (y >= 10'd12);
            line_y_lt_60 = (y < 10'd60);
            line_y_eq_12 = (y == 10'd12);
            line_y_eq_59 = (y == 10'd59);
            line_y_ge_24 = (y >= 10'd24);
            line_y_lt_48 = (y < 10'd48);
            line_y_ge_68 = (y >= 10'd68);
            line_y_lt_400 = (y < 10'd400);
            line_y_eq_68 = (y == 10'd68);
            line_y_eq_399 = (y == 10'd399);
            line_y_ge_412 = (y >= 10'd412);
            line_y_lt_472 = (y < 10'd472);
            line_y_lt_82 = (y < 10'd82);
            line_y_eq_81 = (y == 10'd81);
            line_hint_second = y >= 10'd442;
            line_status_glyph_valid = (status_glyph_row < 5'd24);
            line_status_index_valid = (status_line_index < 3'd2);
            line_hint_valid = (settings_hint_row < 10'd24);
            line_black_key = (y >= 10'd104) && (y < 10'd180);
            line_white_key = (y >= 10'd104) && (y < 10'd232);
            line_black_border = (y == 10'd104) || (y == 10'd179);
            line_white_border = (y == 10'd104) || (y == 10'd231);
            line_black_label = (y >= 10'd148) && (y < 10'd172);
            line_white_label = (y >= 10'd201) && (y < 10'd225);
            line_black_label_row = y - 10'd148;
            line_white_label_row = y - 10'd201;
            decode_line = {status_text_y, status_line_index, status_glyph_row, settings_title_glyph_row, settings_row_index, settings_row_origin_y, settings_row_y, settings_glyph_row, settings_hint_row, line_settings_rows, line_settings_border, line_settings_text, line_scope, line_scope_border, line_scope_grid, line_y_ge_45, line_y_lt_72, line_y_eq_45, line_y_eq_71, line_y_ge_51, line_y_lt_66, line_y_ge_8, line_y_lt_88, line_y_eq_8, line_y_eq_87, line_y_ge_14, line_y_lt_70, line_y_ge_12, line_y_lt_60, line_y_eq_12, line_y_eq_59, line_y_ge_24, line_y_lt_48, line_y_ge_68, line_y_lt_400, line_y_eq_68, line_y_eq_399, line_y_ge_412, line_y_lt_472, line_y_lt_82, line_y_eq_81, line_hint_second, line_status_glyph_valid, line_status_index_valid, line_hint_valid, line_black_key, line_white_key, line_black_border, line_white_border, line_black_label, line_white_label, line_black_label_row, line_white_label_row};
        end
    endfunction
    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            decoded_y <= 10'h3ff;
            decoded_page <= DEFAULT_STATUS[ST_PAGE];
            line_metadata <= decode_line(10'h3ff, DEFAULT_STATUS[ST_PAGE]);
        end else if ((predecode_y != decoded_y) || (decode_page != decoded_page) || frame_start) begin
            decoded_y <= predecode_y;
            decoded_page <= decode_page;
            line_metadata <= decode_line(predecode_y, decode_page);
        end
    end

    // Initialized synchronous ROM, SUG949 section 9.1. Pixel metadata and
    // HS/VS/DE take the same one-clock delay as the font row.
    `include "chinese_font_rom_init.vh"
    always @(posedge pixel_clk)
        shared_font_bits <= font_memory[{font_lookup_index, font_lookup_row}];

    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            background_q <= 18'd0;
            foreground_q <= 18'd0;
            font_column_q <= 5'd0;
            text_enable_q <= 1'b0;
            text_force_q <= 1'b0;
            hsync_out <= 1'b1;
            vsync_out <= 1'b1;
            de_out <= 1'b0;
        end else begin
            background_q <= {base_red, base_green, base_blue};
            foreground_q <= {text_red, text_green, text_blue};
            font_column_q <= font_lookup_column;
            text_enable_q <= text_enable;
            text_force_q <= text_force;
            hsync_out <= hsync_in;
            vsync_out <= vsync_in;
            de_out <= data_enable;
        end
    end
    always @* begin
        {red, green, blue} = background_q;
        if (text_enable_q && (text_force_q || glyph_pixel(shared_font_bits, font_column_q)))
            {red, green, blue} = foreground_q;
    end

    // Only one text region is visible at a pixel. Mux its address before
    // the font lookup rather than synthesizing five large copies of the ROM.
    always @* begin
        font_lookup_index = 7'd0;
        font_lookup_row = 5'd0;
        font_lookup_column = 5'd0;
        if (setting_mode_active) begin
            if (settings_title_bar_region) begin
                font_lookup_index = settings_title_glyph_index;
                font_lookup_row = settings_title_glyph_row[4:0];
                font_lookup_column = settings_title_glyph_column[4:0];
            end else if (settings_row_region) begin
                font_lookup_index = settings_glyph_index;
                font_lookup_row = settings_glyph_row[4:0];
                font_lookup_column = settings_glyph_column[4:0];
            end else if (settings_hint_region) begin
                font_lookup_index = settings_hint_index;
                font_lookup_row = settings_hint_row[4:0];
                font_lookup_column = settings_hint_column[4:0];
            end
        end else if (status_panel_region) begin
            font_lookup_index = status_glyph_index;
            font_lookup_row = status_glyph_row;
            font_lookup_column = status_glyph_column;
        end else if (piano_label_region) begin
            font_lookup_index = {2'b00, piano_label_glyph_index};
            font_lookup_row = piano_label_row;
            font_lookup_column = piano_label_column;
        end
    end

    assign setting_mode_active   = status_active[ST_SETTING];
    assign selected_field_active = status_active[ST_FIELD +: 3];
    assign play_mode_active       = status_active[ST_PLAY_MODE];
    assign tone_select_active     = status_active[ST_TONE +: 2];
    assign note_select_active     = status_active[ST_NOTE +: 4];
    assign force_value_active     = status_active[ST_FORCE +: 7];
    assign keymap_select_active   = status_active[ST_KEYMAP];
    assign octave_select_active   = status_active[ST_OCTAVE +: 2];
    assign key_pressed_active     = status_active[ST_KEYS +: 3];
    assign effect_select_active   = status_active[ST_EFFECT +: 2];
    assign test_mode_active       = status_active[ST_TEST];
    assign test_polyphony_active  = status_active[ST_POLYPHONY];
    assign polyphony_voice_count_active = status_active[ST_VOICES +: 6];
    assign polyphony_count_tens = polyphony_voice_count_active / 6'd10;
    assign polyphony_count_ones = polyphony_voice_count_active % 6'd10;

    assign force_hundreds = force_value_active / 7'd100;
    assign force_tens = (force_value_active / 7'd10) % 7'd10;
    assign force_ones = force_value_active % 7'd10;
    assign audio_sample_abs = audio_sample[15]
                            ? (~audio_sample + 16'd1) : audio_sample;
    assign audio_level_sample = (|audio_sample_abs[15:14])
                              ? 8'hff : audio_sample_abs[13:6];
    assign capture_sample = test_mode_active
                          ? $signed({audio_sample[15], audio_sample[15:9]})
                          : $signed(audio_sample[15:8]);
    assign scope_trigger_low = audio_sample <= -16'sd1024;
    assign scope_trigger_high = audio_sample >= 16'sd1024;
    assign status_level_fill_end = 11'd710
                                 + {5'd0, audio_level_active[7:2]};
    assign status_level_border = status_panel_region &&
        (active_x >= 11'd704) && (active_x < 11'd778) &&
        line_y_ge_45 && line_y_lt_72 &&
        ((active_x == 11'd704) || (active_x == 11'd777) ||
         line_y_eq_45 || line_y_eq_71);
    assign status_level_fill = status_panel_region &&
        (active_x >= 11'd710) && (active_x < status_level_fill_end) &&
        line_y_ge_51 && line_y_lt_66;

    assign scope_x                = active_x - 11'd16;
    // The raster address is known one pixel ahead, so both taps read
    // synchronously from the address the *next* pixel needs and still present
    // the current pixel's samples. The trace is unchanged; the 512x8 history
    // now maps to BSRAM instead of spilling into 128 distributed RAM16 blocks,
    // which the earlier asynchronous reads forced and then duplicated per port.
    // At 2x scaling a logical x repeats for two physical pixels. Read for the
    // actual next logical coordinate, not current_x+1 (which skips RAM taps).
    assign scope_x_next           = next_active_x - 11'd16;
    assign scope_index_next       = scope_x_next[9:2];
    assign history_read_addr      = {display_bank, scope_index_next};
    assign history_next_read_addr = {display_bank, scope_index_next + 8'd1};
    // No reset: a reset on these output registers would block BSRAM inference.
    // Both are only consumed inside the gated scope region.
    always @(posedge pixel_clk) begin
        history_sample      <= sample_history[history_read_addr];
        history_next_sample <= sample_history[history_next_read_addr];
    end
    assign history_delta          = $signed({history_next_sample[7], history_next_sample})
                                  - $signed({history_sample[7], history_sample});
    assign history_sample_ext     = {{3{history_sample[7]}}, history_sample};
    assign history_sample_scaled  = history_sample_ext <<< 2;
    assign history_next_sample_ext = {
        {3{history_next_sample[7]}}, history_next_sample
    };
    assign history_next_sample_scaled = history_next_sample_ext <<< 2;
    assign history_delta_ext      = {{2{history_delta[8]}}, history_delta};
    // Dividing the amplitude by eight flattened the trace into a line. Halving
    // instead and clamping to the frame keeps the shape visible in the same box.
    wire signed [11:0] wave_offset      = wave_sample_scaled >>> 1;
    wire signed [11:0] wave_next_offset = history_next_sample_scaled >>> 1;
    wire signed [11:0] wave_clamped      = wave_offset > 12'sd38 ? 12'sd38 :
                                           wave_offset < -12'sd38 ? -12'sd38 : wave_offset;
    wire signed [11:0] wave_next_clamped = wave_next_offset > 12'sd38 ? 12'sd38 :
                                           wave_next_offset < -12'sd38 ? -12'sd38 : wave_next_offset;
    assign wave_y                 = COMPACT_SCOPE ? 11'sd293-wave_clamped[10:0] : 11'sd360-wave_sample_scaled;
    assign wave_next_y            = COMPACT_SCOPE ? 11'sd293-wave_next_clamped[10:0] : 11'sd360-history_next_sample_scaled;
    assign square_edge_min_y      = (wave_y < wave_next_y)
                                  ? wave_y : wave_next_y;
    assign square_edge_max_y      = (wave_y > wave_next_y)
                                  ? wave_y : wave_next_y;
    assign active_y_signed        = $signed({1'b0, active_y});
    assign square_edge_pixel = (tone_select_active == 2'd1)
                             && (scope_x[1:0] == 2'd3)
                             && (history_sample != history_next_sample)
                             && (active_y_signed >= square_edge_min_y)
                             && (active_y_signed <= square_edge_max_y);

    assign status_panel_region =
        (active_x >= 11'd232) && (active_x < 11'd790) &&
        line_y_ge_8 && line_y_lt_88;
    assign status_panel_border = status_panel_region &&
        ((active_x == 11'd232) || (active_x == 11'd789) ||
         line_y_eq_8 || line_y_eq_87);
    assign status_text_region =
        (active_x >= 11'd246) && (active_x < 11'd774) &&
        line_y_ge_14 && line_y_lt_70;
    assign status_text_x = active_x - 11'd246;

    assign status_character_index = status_text_x / 11'd26;
    assign status_cell_x = status_text_x
                         - (status_character_index * 6'd26);

    assign status_glyph_column = status_cell_x;

    assign status_glyph_index = status_glyph(
        status_line_index, status_character_index
    );
    assign status_glyph_bits = shared_font_bits;
    assign status_count_slash_pixel = ((test_mode_active && test_polyphony_active) || string_count_visible) &&
        (status_line_index == 3'd0) && (status_character_index == 5'd17) &&
        line_status_glyph_valid && (status_glyph_column < 5'd24) &&
        ((status_glyph_row + status_glyph_column) >= 6'd22) &&
        ((status_glyph_row + status_glyph_column) <= 6'd24);
    assign status_glyph_on = status_text_region && line_status_index_valid &&
        line_status_glyph_valid && (status_glyph_column < 5'd24);
    assign status_line_selected = setting_mode_active &&
        (((status_line_index == 3'd0) &&
          (selected_field_active == 3'd0) &&
          (status_character_index <= 5'd4)) ||
         ((status_line_index == 3'd0) &&
          (selected_field_active == 3'd1) &&
          (status_character_index >= 5'd6) &&
          (status_character_index <= 5'd10)) ||
         ((status_line_index == 3'd0) &&
          (selected_field_active == 3'd2) &&
          (status_character_index >= 5'd12) &&
          (status_character_index <= 5'd16)) ||
         ((status_line_index == 3'd1) &&
          (selected_field_active == 3'd3) &&
          (status_character_index >= 5'd0) &&
          (status_character_index <= 5'd5)) ||
         ((status_line_index == 3'd1) &&
          (selected_field_active == 3'd4) &&
          (status_character_index >= 5'd7) &&
          (status_character_index <= 5'd11)) ||
         ((status_line_index == 3'd1) &&
          (selected_field_active == 3'd5) &&
          (status_character_index >= 5'd13) &&
          (status_character_index <= 5'd16)) ||
         ((status_line_index == 3'd1) &&
          (selected_field_active == 3'd6) &&
          (status_character_index >= 5'd17) &&
          (status_character_index <= 5'd19)) ||
         ((status_line_index == 3'd0) &&
           (selected_field_active == 3'd7) &&
           (status_character_index >= 5'd15) &&
           (status_character_index <= 5'd19)));

    assign settings_title_bar_region =
        (active_x >= 11'd64) && (active_x < 11'd736) &&
        line_y_ge_12 && line_y_lt_60;
    assign settings_title_bar_border = settings_title_bar_region &&
        ((active_x == 11'd64) || (active_x == 11'd735) ||
         (active_x == 11'd399) || (active_x == 11'd400) ||
         line_y_eq_12 || line_y_eq_59);
    assign settings_title_right = (active_x >= 11'd400);
    assign settings_title_selected = (settings_title_right == settings_page_active);
    assign settings_title_text_x = settings_title_right
        ? active_x - 11'd512 : active_x - 11'd176;
    assign settings_title_character_index = settings_title_text_x / 11'd28;
    assign settings_title_glyph_column = settings_title_text_x % 11'd28;

    assign settings_title_glyph_index = settings_title_character_index == 4'd0
        ? (settings_title_right ? 7'd69 : 7'd65)
        : settings_title_character_index == 4'd1
        ? (settings_title_right ? 7'd70 : 7'd66)
        : settings_title_character_index == 4'd2 ? 7'd67 : 7'd68;
    assign settings_title_glyph_bits = shared_font_bits;
    assign settings_title_glyph_on = settings_title_bar_region &&
        (settings_title_text_x < 11'd112) &&
        line_y_ge_24 && line_y_lt_48 &&
        (settings_title_glyph_column < 11'd24);

    assign settings_panel_region =
        (active_x >= 11'd64) && (active_x < 11'd736) &&
        line_y_ge_68 && line_y_lt_400;
    assign settings_panel_border = settings_panel_region &&
        ((active_x == 11'd64) || (active_x == 11'd735) ||
         line_y_eq_68 || line_y_eq_399);
    assign settings_row_region =
        (active_x >= 11'd80) && (active_x < 11'd720) &&
        line_settings_rows;

    assign settings_field_index = keyboard_settings_field_id(settings_page_active, settings_row_index,
        ADDITIVE_BANK_ENABLE!=0,STRING_BANK_ENABLE!=0,KEYBOARD_MODE_ENABLE!=0);


    assign settings_row_border = settings_row_region &&
        ((active_x == 11'd80) || (active_x == 11'd719) ||
         line_settings_border);
    assign settings_row_selected = settings_row_region &&
        (settings_row_index == selected_field_active);
    assign settings_text_x = active_x - 11'd112;
    assign settings_character_index = settings_text_x / 11'd26;
    assign settings_cell_x = settings_text_x -
        (settings_character_index * 6'd26);
    assign settings_glyph_column = settings_cell_x;

    assign settings_glyph_index = settings_glyph(
        settings_field_index, settings_character_index[4:0]
    );
    assign settings_glyph_bits = shared_font_bits;
    assign settings_glyph_on = settings_row_region &&
        (active_x >= 11'd112) && (active_x < 11'd684) &&
        line_settings_text &&
        (settings_glyph_column < 11'd24);

    assign settings_hint_region = (active_x >= 11'd64) && (active_x < 11'd736) &&
        line_y_ge_412 && line_y_lt_472;
    assign settings_hint_x = active_x - 11'd64;
    assign settings_hint_character = settings_hint_x / 11'd24;
    assign settings_hint_column = settings_hint_x % 11'd24;

    assign settings_hint_index = settings_hint_glyph(
        line_hint_second, settings_hint_character[4:0]);
    assign settings_hint_bits = shared_font_bits;
    assign settings_hint_on = settings_hint_region && line_hint_valid;

    assign piano_note_index = piano_note_at(active_x, line_black_key, line_white_key);
    assign piano_note_valid = (piano_note_index != 4'hf);
    assign piano_note_is_black =
        (piano_note_index == 4'd1) || (piano_note_index == 4'd3) ||
        (piano_note_index == 4'd6) || (piano_note_index == 4'd8) ||
        (piano_note_index == 4'd10);
    assign piano_note_selected = piano_note_valid
                               && (piano_note_index == note_select_active);
    assign piano_chord_root_offset = key_pressed_active[2] ? 4'd7 :
                                     key_pressed_active[1] ? 4'd5 : 4'd0;
    assign piano_root_sum = {1'b0, note_select_active}
                          + (keymap_select_active
                             ? {1'b0, piano_chord_root_offset} : 5'd0);
    assign piano_third_sum = piano_root_sum
                           + (keymap_select_active ? 5'd4 : 5'd2);
    assign piano_fifth_sum = piano_root_sum
                           + (keymap_select_active ? 5'd7 : 5'd4);
    assign piano_root_note = (piano_root_sum >= 5'd12)
                           ? piano_root_sum - 5'd12 : piano_root_sum[3:0];
    assign piano_third_note = (piano_third_sum >= 5'd24)
                            ? piano_third_sum - 5'd24
                            : (piano_third_sum >= 5'd12)
                            ? piano_third_sum - 5'd12 : piano_third_sum[3:0];
    assign piano_fifth_note = (piano_fifth_sum >= 5'd24)
                            ? piano_fifth_sum - 5'd24
                            : (piano_fifth_sum >= 5'd12)
                            ? piano_fifth_sum - 5'd12 : piano_fifth_sum[3:0];
    // Dynamic polyphony accepts all three chord keys at once. Highlight their
    // union, including pitch-class wrapping when the selected root changes.
    assign piano_relative_note = (piano_note_index >= note_select_active)
        ? {1'b0, piano_note_index} - {1'b0, note_select_active}
        : {1'b0, piano_note_index} + 5'd12 - {1'b0, note_select_active};
    assign piano_polyphony_pressed = piano_note_valid && (
        (key_pressed_active[0] && ((piano_relative_note == 0) ||
            (piano_relative_note == 4) || (piano_relative_note == 7))) ||
        (key_pressed_active[1] && ((piano_relative_note == 5) ||
            (piano_relative_note == 9) || (piano_relative_note == 0))) ||
        (key_pressed_active[2] && ((piano_relative_note == 7) ||
            (piano_relative_note == 11) || (piano_relative_note == 2))));
    // All held pitch classes share the same frame-committed status bundle.
    // The 12-key octave view folds equal pitch classes across three octaves.
    assign piano_note_pressed = ((audition_active && audition_target==3'd7) ||
        (LIVE_KEYBOARD && !status_active[ST_SETTING] && !audition_active &&
         !test_mode_active))
        ? (piano_note_valid && song_notes_active[piano_note_index])
        : (keymap_select_active && test_mode_active && test_polyphony_active)
        ? piano_polyphony_pressed : keymap_select_active
        ? ((|key_pressed_active) &&
           ((piano_note_index == piano_root_note) ||
            (piano_note_index == piano_third_note) ||
            (piano_note_index == piano_fifth_note)))
        : (((piano_note_index == note_select_active) && key_pressed_active[0]) ||
           ((piano_note_index == piano_third_note) && key_pressed_active[1]) ||
           ((piano_note_index == piano_fifth_note) && key_pressed_active[2]));
    assign piano_key_border = piano_border_at(
        piano_note_index, active_x, line_black_border, line_white_border
    );
    assign piano_label_x_origin = piano_label_x(piano_note_index);
    assign piano_label_y_origin = piano_note_is_black ? 10'd148 : 10'd201;
    assign piano_label_character_index =
        (active_x - piano_label_x_origin) / 11'd24;
    assign piano_label_column = active_x - piano_label_x_origin
                              - (piano_label_character_index * 6'd24);
    assign piano_label_row = piano_note_is_black ? line_black_label_row : line_white_label_row;
    assign piano_label_glyph_index = piano_label_glyph(
        piano_note_index, piano_label_character_index
    );
    assign piano_label_glyph_bits = shared_font_bits;
    assign piano_label_region = piano_note_valid
                              && (active_x >= piano_label_x_origin)
                              && (active_x < piano_label_x_origin
                                           + (piano_note_is_black ? 11'd48 : 11'd24))
                              && (piano_note_is_black ? line_black_label : line_white_label);
    assign piano_label_on = piano_label_region
                          && (piano_label_column < 5'd24)
                          && (piano_label_row < 5'd24);

    function [5:0] note_primary_glyph;
        input [3:0] note_value;
        begin
            case (note_value)
                4'd0, 4'd1:   note_primary_glyph = 6'd25;
                4'd2, 4'd3:   note_primary_glyph = 6'd26;
                4'd4:         note_primary_glyph = 6'd27;
                4'd5, 4'd6:   note_primary_glyph = 6'd28;
                4'd7, 4'd8:   note_primary_glyph = 6'd29;
                4'd9, 4'd10:  note_primary_glyph = 6'd30;
                default:      note_primary_glyph = 6'd31;
            endcase
        end
    endfunction

    function [5:0] note_accidental_glyph;
        input [3:0] note_value;
        begin
            case (note_value)
                4'd1, 4'd3, 4'd6, 4'd8, 4'd10:
                    note_accidental_glyph = 6'd32;
                default:
                    note_accidental_glyph = 6'd0;
            endcase
        end
    endfunction

    function [5:0] digit_glyph;
        input [3:0] digit_value;
        begin
            digit_glyph = 6'd33 + digit_value;
        end
    endfunction

    function [7:0] status_glyph;
        input [2:0] line_index;
        input [4:0] character_index;
        begin
            status_glyph = 6'd0;
            case (line_index)
                3'd0: begin
                    case (character_index)
                        5'd0:  status_glyph = 6'd1;
                        5'd1:  status_glyph = 6'd2;
                        5'd2:  status_glyph = 6'd3;
                        5'd3:  status_glyph = play_mode_active ? 7'd43 : 7'd72;
                        5'd4:  status_glyph = play_mode_active ? 7'd44 : 7'd73;
                        5'd6:  status_glyph = 6'd8;
                        5'd7:  status_glyph = 6'd9;
                        5'd8:  status_glyph = 6'd3;
                        5'd9: begin
                            case (tone_select_active)
                                2'd0: status_glyph = 6'd10;
                                2'd1: status_glyph = 6'd12;
                                2'd2: status_glyph = 6'd14;
                                default: status_glyph = 7'd64;
                            endcase
                        end
                        5'd10: begin
                            case (tone_select_active)
                                2'd0: status_glyph = 6'd11;
                                2'd1: status_glyph = 6'd13;
                                2'd2: status_glyph = 6'd15;
                                default: status_glyph = string_mode_active ? 6'd44 : 6'd8;
                            endcase
                        end
                        5'd12: status_glyph = 6'd8;
                        5'd13: status_glyph = 6'd16;
                        5'd14: status_glyph = 6'd3;
                        5'd15: status_glyph = (test_mode_active && test_polyphony_active) ? digit_glyph(polyphony_count_tens) : note_primary_glyph(note_select_active);
                        5'd16: status_glyph = (test_mode_active && test_polyphony_active) ? digit_glyph(polyphony_count_ones) : note_accidental_glyph(note_select_active);
                        5'd17: status_glyph = (test_mode_active && test_polyphony_active) ? 6'd0 : digit_glyph(4'd3);
                        5'd18: status_glyph = (test_mode_active && test_polyphony_active) ? digit_glyph(4'd3) : digit_glyph(4'd2);
                        5'd19: status_glyph = (test_mode_active && test_polyphony_active) ? digit_glyph(4'd2) : (test_mode_active ? 6'd21 : 6'd63);
                        default: status_glyph = 6'd0;
                    endcase
                end
                3'd1: begin
                    case (character_index)
                        5'd0:  status_glyph = 6'd17;
                        5'd1:  status_glyph = 6'd18;
                        5'd2:  status_glyph = 6'd3;
                        5'd3:  status_glyph = digit_glyph(force_hundreds);
                        5'd4:  status_glyph = digit_glyph(force_tens);
                        5'd5:  status_glyph = digit_glyph(force_ones);
                        5'd7:  status_glyph = 6'd50;
                        5'd8:  status_glyph = 6'd51;
                        5'd9:  status_glyph = 6'd3;
                        5'd10: status_glyph = keymap_select_active ? 7'd54 : 7'd71;
                        5'd11: status_glyph = keymap_select_active ? 7'd44 : 7'd8;
                        5'd13: status_glyph = 6'd8;
                        5'd14: status_glyph = 6'd55;
                        5'd15: status_glyph = 6'd3;
                        5'd16: begin
                            case (octave_select_active)
                                2'd0: status_glyph = 6'd56;
                                2'd1: status_glyph = 6'd57;
                                default: status_glyph = 6'd58;
                            endcase
                        end
                        5'd17: status_glyph = 6'd59;
                        5'd18: status_glyph = 6'd3;
                        5'd19: begin
                            case (effect_select_active)
                                2'd0: status_glyph = 6'd60;
                                2'd1: status_glyph = 6'd61;
                                2'd2: status_glyph = 6'd62;
                                default: status_glyph = 7'd120;
                            endcase
                        end
                        default: status_glyph = 6'd0;
                    endcase
                end
                default: status_glyph = 6'd0;
            endcase
            // Show the applied expression on the live performance screen.
            if (!test_mode_active && !string_mode_active && line_index==3'd0) begin
                case(character_index)
                    5'd17: status_glyph=7'd111;
                    5'd18: status_glyph=7'd3;
                    5'd19: status_glyph=(glide_active!=0)?7'd98:
                        (vibrato_active!=0)?7'd99:7'd60;
                    default: begin end
                endcase
            end
            // The demo source overrides the stored live timbre label only.
            if (string_count_visible && (line_index == 3'd0)) begin
                case(character_index)
                    5'd12: status_glyph=7'd90;
                    5'd13: status_glyph=7'd91;
                    5'd15: status_glyph=digit_glyph(polyphony_count_tens);
                    5'd16: status_glyph=digit_glyph(polyphony_count_ones);
                    5'd17: status_glyph=7'd0;
                    5'd18: status_glyph=digit_glyph(4'd0);
                    5'd19: status_glyph=digit_glyph(4'd8);
                    default: begin end
                endcase
            end
            // Keeping the live selection lets S2 stop a demo without losing it.
            if (test_mode_active && (line_index == 3'd0)) begin
                case (character_index)
                    5'd6: status_glyph = digit_glyph(4'd3);
                    5'd7: status_glyph = digit_glyph(4'd2);
                    5'd8: status_glyph = test_polyphony_active ? 7'd23 : 7'd62;
                    5'd9: status_glyph = 7'd8;
                    5'd10: status_glyph = 7'd0;
                    5'd12: status_glyph = test_polyphony_active ? 7'd90 : 7'd92;
                    5'd13: status_glyph = test_polyphony_active ? 7'd91 : 7'd47;
                    5'd15: if (!test_polyphony_active) status_glyph = digit_glyph(4'd3);
                    5'd16: if (!test_polyphony_active) status_glyph = digit_glyph(4'd2);
                    5'd17: if (!test_polyphony_active) status_glyph = 7'd0;
                    5'd18: if (!test_polyphony_active) status_glyph = 7'd21;
                    5'd19: if (!test_polyphony_active) status_glyph = 7'd22;
                    default: begin end
                endcase
            end
            if (audition_active) begin
                status_glyph=7'd0;
                if (line_index==0) begin
                    case(character_index)
                        0:status_glyph=7'd114; 1:status_glyph=7'd115;
                        2:status_glyph=7'd116; 3:status_glyph=7'd117;
                        6:status_glyph=audition_wet?7'd31:7'd30;
                        7:status_glyph=7'd3;
                        8:status_glyph=!audition_wet?((audition_target==6)?7'd64:7'd60):audition_label(audition_target,1'b0);
                        9:status_glyph=!audition_wet?((audition_target==6)?7'd8:7'd90):audition_label(audition_target,1'b1);
                        12:status_glyph=7'd25; 14:status_glyph=7'd29; 16:status_glyph=7'd25;
                        19:status_glyph=(audition_target>=2 && audition_target<=4)?strength_glyph(effect_strength_active):7'd0;
                        default:begin end
                    endcase
                end else if (line_index==1) begin
                    case(character_index)
                        0:status_glyph=7'd87; 1:status_glyph=7'd35;
                        2:status_glyph=7'd82; 3:status_glyph=7'd83;
                        6:status_glyph=7'd60; 7:status_glyph=7'd90; 8:status_glyph=7'd108;
                        9:status_glyph=7'd8; 10:status_glyph=7'd59;
                        11:status_glyph=7'd118; 12:status_glyph=7'd119;
                        default:begin end
                    endcase
                end
            end
            if (audition_active && audition_target==3'd7) begin
                status_glyph=7'd0;
                if (line_index==0) case(character_index)
                    // Reuse existing glyphs: PC曲目, never a built-in title.
                    0:status_glyph=uploaded_song?8'd130:song_select?8'd126:8'd124;
                    1:status_glyph=uploaded_song?8'd25:song_select?8'd127:8'd125;
                    2:status_glyph=uploaded_song?8'd122:song_select?8'd128:8'd125;
                    3:status_glyph=uploaded_song?8'd123:song_accompaniment?8'd133:8'd132;
                    4:status_glyph=uploaded_song?8'd0:8'd5;
                    5:status_glyph=uploaded_song && upload_active[2:0]==1 ? 8'd76 :
                        uploaded_song && upload_active[2:0]==4 ? 8'd96 : audition_wet?8'd63:8'd21;
                    6:status_glyph=uploaded_song && upload_active[2:0]==1 ? 8'd77 :
                        uploaded_song && upload_active[2:0]==4 ? 8'd97 : audition_wet?8'd24:8'd22;
                    // Long progress uses four digits within the existing 20
                    // complete cells. Cell 20 is clipped by the panel boundary.
                    8:status_glyph=song_length>=1000 ? digit_glyph(tempo_bpm/8'd100) : 8'd129;
                    9:status_glyph=song_length>=1000 ? digit_glyph((tempo_bpm/8'd10)%8'd10) : digit_glyph(tempo_bpm/8'd100);
                    10:status_glyph=song_length>=1000 ? digit_glyph(tempo_bpm%8'd10) : digit_glyph((tempo_bpm/8'd10)%8'd10);
                    11:status_glyph=song_length>=1000 ? digit_glyph(song_position/12'd1000) : digit_glyph(tempo_bpm%8'd10);
                    12:status_glyph=song_length>=1000 ? digit_glyph((song_position/12'd100)%12'd10) : 8'd0;
                    13:status_glyph=song_length>=1000 ? digit_glyph((song_position/12'd10)%12'd10) : digit_glyph(song_position/12'd100);
                    14:status_glyph=song_length>=1000 ? digit_glyph(song_position%12'd10) : digit_glyph((song_position/12'd10)%12'd10);
                    15:status_glyph=song_length>=1000 ? 8'd88 : digit_glyph(song_position%12'd10);
                    16:status_glyph=song_length>=1000 ? digit_glyph(song_length/12'd1000) : 8'd88;
                    17:status_glyph=digit_glyph((song_length/12'd100)%12'd10);
                    18:status_glyph=digit_glyph((song_length/12'd10)%12'd10);
                    19:status_glyph=digit_glyph(song_length%12'd10);
                    default:begin end
                endcase
                else if (line_index==1) case(character_index)
                    // Seventeen cells leave x=704..777 for the level meter:
                    // 0选 1停 2奏 S2回05/32 (numbers denote the three KEYs).
                    0:status_glyph=uploaded_song?8'd0:8'd33; 1:status_glyph=uploaded_song?8'd0:8'd78;
                    3:status_glyph=8'd34; 4:status_glyph=8'd63;
                    6:status_glyph=uploaded_song?8'd0:8'd35;
                    10:status_glyph=8'd35;
                    7:status_glyph=uploaded_song?8'd0:8'd5;
                    9:status_glyph=8'd87; 11:status_glyph=8'd83;
                    12:status_glyph=digit_glyph(polyphony_count_tens);
                    13:status_glyph=digit_glyph(polyphony_count_ones);
                    14:status_glyph=8'd88;
                    15:status_glyph=8'd36;
                    16:status_glyph=8'd35;
                    default:begin end
                endcase
            end
        end
    endfunction

    function [7:0] audition_label;
        input [2:0] target;
        input second;
        begin
            case(target)
                0:audition_label=second?7'd8:7'd98;
                1:audition_label=second?7'd8:7'd99;
                2:audition_label=second?7'd93:7'd61;
                3:audition_label=second?7'd94:7'd62;
                4:audition_label=second?7'd121:7'd120;
                5:audition_label=second?7'd18:7'd17;
                7:audition_label=second?7'd123:7'd122;
                default:audition_label=second?7'd44:7'd64;
            endcase
        end
    endfunction

    function [7:0] strength_glyph;
        input [1:0] strength;
        begin strength_glyph=(strength==0)?7'd103:(strength==1)?7'd57:7'd104; end
    endfunction

    function [2:0] settings_row_at;
        input [9:0] y;
        input page;
        begin
            if(page) begin
                if(y<10'd124) settings_row_at=0;
                else if(y<10'd168) settings_row_at=1;
                else if(y<10'd212) settings_row_at=2;
                else if(y<10'd256) settings_row_at=3;
                else if(y<10'd300) settings_row_at=4;
                else if(y<10'd344) settings_row_at=5;
                else settings_row_at=6;
            end else if (y < 10'd132) settings_row_at = 3'd0;
            else if (y < 10'd184) settings_row_at = 3'd1;
            else if (y < 10'd236) settings_row_at = 3'd2;
            else if (y < 10'd288) settings_row_at = 3'd3;
            else if (y < 10'd340) settings_row_at = 3'd4;
            else settings_row_at = 3'd5;
        end
    endfunction

    function [9:0] settings_row_origin;
        input [2:0] row_index;
        input page;
        begin
            if(page) case(row_index)
                0:settings_row_origin=80;
                1:settings_row_origin=124;
                2:settings_row_origin=168;
                3:settings_row_origin=212;
                4:settings_row_origin=256;
                5:settings_row_origin=300;
                default:settings_row_origin=344;
            endcase
            else case (row_index)
                3'd0: settings_row_origin = 10'd80;
                3'd1: settings_row_origin = 10'd132;
                3'd2: settings_row_origin = 10'd184;
                3'd3: settings_row_origin = 10'd236;
                3'd4: settings_row_origin = 10'd288;
                default: settings_row_origin = 10'd340;
            endcase
        end
    endfunction

    function [7:0] settings_glyph;
        input [3:0] row_index;
        input [4:0] character_index;
        begin
            settings_glyph = 6'd0;
            case (row_index)
                FIELD_KEYBOARD: case(character_index)
                    0:settings_glyph=8'd50; // 键
                    1:settings_glyph=8'd136; // 盘
                    2:settings_glyph=8'd1; // 模
                    3:settings_glyph=8'd2; // 式
                    4:settings_glyph=8'd3;
                    10:settings_glyph=status_active[ST_KEYBOARD_PIANO]?8'd135:8'd134; // 钢/同
                    11:settings_glyph=status_active[ST_KEYBOARD_PIANO]?8'd64:8'd8;
                    12:settings_glyph=status_active[ST_KEYBOARD_PIANO]?8'd8:8'd9;
                    13:settings_glyph=status_active[ST_KEYBOARD_PIANO]?8'd9:8'd0;
                    default:settings_glyph=8'd0;
                endcase
                FIELD_MODE: case (character_index)
                    5'd0: settings_glyph = 6'd1;
                    5'd1: settings_glyph = 6'd2;
                    5'd2: settings_glyph = 6'd3;
                    5'd10: settings_glyph = play_mode_active ? 7'd43 : 7'd72;
                    5'd11: settings_glyph = play_mode_active ? 7'd44 : 7'd73;
                    default: settings_glyph = 6'd0;
                endcase
                FIELD_TONE: case (character_index)
                    5'd0: settings_glyph = 6'd8;
                    5'd1: settings_glyph = 6'd9;
                    5'd2: settings_glyph = 6'd3;
                    5'd10: case (tone_select_active)
                        2'd0: settings_glyph = 6'd10;
                        2'd1: settings_glyph = 6'd12;
                        2'd2: settings_glyph = 6'd14;
                        default: settings_glyph = 7'd64;
                    endcase
                    5'd11: case (tone_select_active)
                        2'd0: settings_glyph = 6'd11;
                        2'd1: settings_glyph = 6'd13;
                        2'd2: settings_glyph = 6'd15;
                        default: settings_glyph = string_mode_active ? 6'd44 : 6'd8;
                    endcase
                    default: settings_glyph = 6'd0;
                endcase
                FIELD_NOTE: case (character_index)
                    5'd0: settings_glyph = 6'd8;
                    5'd1: settings_glyph = 6'd16;
                    5'd2: settings_glyph = 6'd3;
                    5'd10: settings_glyph = note_primary_glyph(note_select_active);
                    5'd11: settings_glyph = note_accidental_glyph(note_select_active);
                    default: settings_glyph = 6'd0;
                endcase
                FIELD_FORCE: case (character_index)
                    5'd0: settings_glyph = 6'd17;
                    5'd1: settings_glyph = 6'd18;
                    5'd2: settings_glyph = 6'd3;
                    5'd10: settings_glyph = digit_glyph(force_hundreds);
                    5'd11: settings_glyph = digit_glyph(force_tens);
                    5'd12: settings_glyph = digit_glyph(force_ones);
                    default: settings_glyph = 6'd0;
                endcase
                FIELD_KEYMAP: case (character_index)
                    5'd0: settings_glyph = 6'd50;
                    5'd1: settings_glyph = 6'd51;
                    5'd2: settings_glyph = 6'd3;
                    5'd10: settings_glyph = keymap_select_active ? 7'd54 : 7'd71;
                    5'd11: settings_glyph = keymap_select_active ? 7'd44 : 7'd8;
                    default: settings_glyph = 6'd0;
                endcase
                FIELD_OCTAVE: case (character_index)
                    5'd0: settings_glyph = 6'd8;
                    5'd1: settings_glyph = 6'd55;
                    5'd2: settings_glyph = 6'd3;
                    5'd10: case (octave_select_active)
                        2'd0: settings_glyph = 6'd56;
                        2'd1: settings_glyph = 6'd57;
                        default: settings_glyph = 6'd58;
                    endcase
                    default: settings_glyph = 6'd0;
                endcase
                FIELD_EFFECT: case (character_index)
                    5'd0: settings_glyph = 7'd8;
                    5'd1: settings_glyph = 7'd59;
                    5'd2: settings_glyph = 7'd3;
                    5'd10: case (effect_select_active)
                        2'd0: settings_glyph = 7'd63; // Approved UI: effect off = 关闭.
                        2'd1: settings_glyph = 6'd61;
                        2'd2: settings_glyph = 6'd62;
                        default: settings_glyph = 7'd120;
                    endcase
                    5'd11: case (effect_select_active)
                        2'd0: settings_glyph = 7'd24;
                        2'd1: settings_glyph = 7'd93;
                        2'd2: settings_glyph = 7'd94;
                        default: settings_glyph = 7'd121;
                    endcase
                    default: settings_glyph = 6'd0;
                endcase
                FIELD_ADDITIVE, FIELD_POLYPHONY: case (character_index)
                    5'd0: settings_glyph = digit_glyph(4'd3);
                    5'd1: settings_glyph = digit_glyph(4'd2);
                    5'd2: settings_glyph = row_index == FIELD_POLYPHONY ? 7'd23 : 7'd62;
                    5'd3: settings_glyph = 7'd8;
                    5'd10: settings_glyph = (test_mode_active &&
                        (test_polyphony_active == (row_index == FIELD_POLYPHONY))) ? 7'd76 : 7'd63;
                    5'd11: settings_glyph = (test_mode_active &&
                        (test_polyphony_active == (row_index == FIELD_POLYPHONY))) ? 7'd77 : 7'd24;
                    default: settings_glyph = 6'd0;
                endcase
                FIELD_STRING: case (character_index)
                    5'd0: settings_glyph = 7'd95;
                    5'd1: settings_glyph = 7'd44;
                    5'd2: settings_glyph = 7'd75;
                    5'd3: settings_glyph = 7'd1;
                    5'd10: settings_glyph = string_mode_active ? 7'd64 : 7'd63;
                    5'd11: settings_glyph = string_mode_active ? 7'd44 : 7'd24;
                    5'd13: settings_glyph = 7'd96;
                    5'd14: settings_glyph = 7'd97;
                    5'd15: settings_glyph = 7'd3;
                    5'd16: settings_glyph = digit_glyph(string_deadline_misses / 8'd100);
                    5'd17: settings_glyph = digit_glyph((string_deadline_misses / 8'd10) % 8'd10);
                    5'd18: settings_glyph = digit_glyph(string_deadline_misses % 8'd10);
                    default: settings_glyph = 7'd0;
                endcase
                FIELD_EXPRESSION: case (character_index)
                    5'd0:settings_glyph=7'd111; 5'd1:settings_glyph=7'd112;
                    5'd2:settings_glyph=7'd3; // Approved UI: 表情:; raster remains frozen.
                    // These bits carry score metadata only while the score row
                    // owns the shared status slot. Do not label it "acoustic".
                    5'd10:settings_glyph=song_context?7'd0:(glide_active!=0)?7'd98:(vibrato_active!=0)?7'd99:7'd60;
                    5'd11:settings_glyph=song_context?7'd0:(glide_active!=0 || vibrato_active!=0)?7'd8:7'd90;
                    default: settings_glyph = 7'd0;
                endcase
                FIELD_STRENGTH: case(character_index)
                    0:settings_glyph=7'd8; 1:settings_glyph=7'd59;
                    2:settings_glyph=7'd104; 3:settings_glyph=7'd18;
                    10:settings_glyph=strength_glyph(effect_strength_active);
                    default:settings_glyph=7'd0;
                endcase
                FIELD_AUDITION: case (character_index)
                    5'd0:settings_glyph=7'd114; 5'd1:settings_glyph=7'd115;
                    5'd2:settings_glyph=7'd116; 5'd3:settings_glyph=7'd117;
                    5'd10:settings_glyph=audition_label(audition_target,1'b0);
                    5'd11:settings_glyph=audition_label(audition_target,1'b1);
                    5'd14:settings_glyph=audition_armed?7'd76:7'd63;
                    5'd15:settings_glyph=audition_armed?7'd77:7'd24;
                    default: settings_glyph = 7'd0;
                endcase
                default: settings_glyph = 7'd0;
            endcase
            // Outside score context the shared slot contains expressions;
            // show the generic score target, not a fictitious song/tempo.
            if (row_index==FIELD_AUDITION && song_context) begin
                case(character_index)
                    0:settings_glyph=7'd122; 1:settings_glyph=7'd123;
                    2:settings_glyph=7'd4; 3:settings_glyph=7'd5;
                    6:settings_glyph=song_accompaniment?8'd133:8'd132;
                    7:settings_glyph=8'd5;
                    10:settings_glyph=song_select?8'd126:8'd124;
                    11:settings_glyph=song_select?8'd127:8'd125;
                    12:settings_glyph=song_select?8'd128:8'd125;
                    16:settings_glyph=digit_glyph(tempo_bpm/8'd100);
                    17:settings_glyph=digit_glyph((tempo_bpm/8'd10)%8'd10);
                    18:settings_glyph=digit_glyph(tempo_bpm%8'd10);
                    19:settings_glyph=8'd31;
                    20:settings_glyph=8'd130;
                    21:settings_glyph=8'd131;
                    default:begin end
                endcase
            end
        end
    endfunction

    `include "chinese_font_24x24.vh"

    function [3:0] piano_note_at;
        input [10:0] x;
        input black_row, white_row;
        begin
            piano_note_at = 4'hf;
            if (black_row) begin
                if ((x >= 11'd101) && (x < 11'd151))
                    piano_note_at = 4'd1;
                else if ((x >= 11'd211) && (x < 11'd261))
                    piano_note_at = 4'd3;
                else if ((x >= 11'd431) && (x < 11'd481))
                    piano_note_at = 4'd6;
                else if ((x >= 11'd541) && (x < 11'd591))
                    piano_note_at = 4'd8;
                else if ((x >= 11'd651) && (x < 11'd701))
                    piano_note_at = 4'd10;
            end

            if ((piano_note_at == 4'hf) &&
                white_row) begin
                if ((x >= 11'd16) && (x < 11'd126))
                    piano_note_at = 4'd0;
                else if ((x >= 11'd126) && (x < 11'd236))
                    piano_note_at = 4'd2;
                else if ((x >= 11'd236) && (x < 11'd346))
                    piano_note_at = 4'd4;
                else if ((x >= 11'd346) && (x < 11'd456))
                    piano_note_at = 4'd5;
                else if ((x >= 11'd456) && (x < 11'd566))
                    piano_note_at = 4'd7;
                else if ((x >= 11'd566) && (x < 11'd676))
                    piano_note_at = 4'd9;
                else if ((x >= 11'd676) && (x < 11'd784))
                    piano_note_at = 4'd11;
            end
        end
    endfunction

    function piano_border_at;
        input [3:0] note_value;
        input [10:0] x;
        input black_border, white_border;
        begin
            piano_border_at = 1'b0;
            case (note_value)
                4'd0:  piano_border_at = (x == 11'd16)  || (x == 11'd125) || white_border;
                4'd1:  piano_border_at = (x == 11'd101) || (x == 11'd150) || black_border;
                4'd2:  piano_border_at = (x == 11'd126) || (x == 11'd235) || white_border;
                4'd3:  piano_border_at = (x == 11'd211) || (x == 11'd260) || black_border;
                4'd4:  piano_border_at = (x == 11'd236) || (x == 11'd345) || white_border;
                4'd5:  piano_border_at = (x == 11'd346) || (x == 11'd455) || white_border;
                4'd6:  piano_border_at = (x == 11'd431) || (x == 11'd480) || black_border;
                4'd7:  piano_border_at = (x == 11'd456) || (x == 11'd565) || white_border;
                4'd8:  piano_border_at = (x == 11'd541) || (x == 11'd590) || black_border;
                4'd9:  piano_border_at = (x == 11'd566) || (x == 11'd675) || white_border;
                4'd10: piano_border_at = (x == 11'd651) || (x == 11'd700) || black_border;
                4'd11: piano_border_at = (x == 11'd676) || (x == 11'd783) || white_border;
                default: piano_border_at = 1'b0;
            endcase
        end
    endfunction

    function [10:0] piano_label_x;
        input [3:0] note_value;
        begin
            case (note_value)
                4'd0:  piano_label_x = 11'd59;
                4'd1:  piano_label_x = 11'd102;
                4'd2:  piano_label_x = 11'd169;
                4'd3:  piano_label_x = 11'd212;
                4'd4:  piano_label_x = 11'd279;
                4'd5:  piano_label_x = 11'd389;
                4'd6:  piano_label_x = 11'd432;
                4'd7:  piano_label_x = 11'd499;
                4'd8:  piano_label_x = 11'd542;
                4'd9:  piano_label_x = 11'd609;
                4'd10: piano_label_x = 11'd652;
                default: piano_label_x = 11'd718;
            endcase
        end
    endfunction

    function [5:0] piano_label_glyph;
        input [3:0] note_value;
        input [1:0] character_index;
        begin
            if (character_index == 2'd0)
                piano_label_glyph = note_primary_glyph(note_value);
            else if ((character_index == 2'd1) &&
                     ((note_value == 4'd1) || (note_value == 4'd3) ||
                      (note_value == 4'd6) || (note_value == 4'd8) ||
                      (note_value == 4'd10)))
                piano_label_glyph = 6'd32;
            else
                piano_label_glyph = 6'd0;
        end
    endfunction

    function glyph_pixel;
        input [23:0] row_bits;
        input [4:0] column_index;
        begin
            case (column_index)
                5'd0: glyph_pixel = row_bits[23];
                5'd1: glyph_pixel = row_bits[22];
                5'd2: glyph_pixel = row_bits[21];
                5'd3: glyph_pixel = row_bits[20];
                5'd4: glyph_pixel = row_bits[19];
                5'd5: glyph_pixel = row_bits[18];
                5'd6: glyph_pixel = row_bits[17];
                5'd7: glyph_pixel = row_bits[16];
                5'd8: glyph_pixel = row_bits[15];
                5'd9: glyph_pixel = row_bits[14];
                5'd10: glyph_pixel = row_bits[13];
                5'd11: glyph_pixel = row_bits[12];
                5'd12: glyph_pixel = row_bits[11];
                5'd13: glyph_pixel = row_bits[10];
                5'd14: glyph_pixel = row_bits[9];
                5'd15: glyph_pixel = row_bits[8];
                5'd16: glyph_pixel = row_bits[7];
                5'd17: glyph_pixel = row_bits[6];
                5'd18: glyph_pixel = row_bits[5];
                5'd19: glyph_pixel = row_bits[4];
                5'd20: glyph_pixel = row_bits[3];
                5'd21: glyph_pixel = row_bits[2];
                5'd22: glyph_pixel = row_bits[1];
                5'd23: glyph_pixel = row_bits[0];
                default: glyph_pixel = 1'b0;
            endcase
        end
    endfunction

    always @* begin
        if (tone_select_active == 2'd1) begin
            wave_sample_scaled = history_sample_scaled;
        end else begin
            case (scope_x[1:0])
                2'd0: wave_sample_scaled = history_sample_scaled;
                2'd1: wave_sample_scaled = history_sample_scaled
                                           + history_delta_ext;
                2'd2: wave_sample_scaled = history_sample_scaled
                                           + (history_delta_ext <<< 1);
                default: wave_sample_scaled = history_sample_scaled
                                                   + history_delta_ext
                                                   + (history_delta_ext <<< 1);
            endcase
        end
    end

    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            status_shadow <= DEFAULT_STATUS;
            status_active <= DEFAULT_STATUS;
            upload_shadow<=0;upload_active<=0;
        end else begin
            if (status_update) begin
                status_shadow <= status_payload;
                upload_shadow<=UPLOAD_UI!=0 ? upload_status : 4'd0;
            end

            if (frame_start) begin
                if (status_update)
                    status_active <= status_payload;
                else
                    status_active <= status_shadow;
                upload_active<=UPLOAD_UI!=0 ? (status_update ? upload_status : upload_shadow) : 4'd0;
            end
        end
    end

    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            audio_level_peak   <= 8'd0;
            audio_level_active <= 8'd0;
        end else if (frame_start) begin
            audio_level_active <= audio_level_peak;
            audio_level_peak   <= audio_sample_valid ? audio_level_sample : 8'd0;
        end else if (audio_sample_valid &&
                     (audio_level_sample > audio_level_peak)) begin
            audio_level_peak <= audio_level_sample;
        end
    end

    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            capture_write_ptr <= 8'd0;
            capture_bank      <= 1'b0;
            capture_ready     <= 1'b0;
            capture_active    <= 1'b1;
            capture_trigger_armed <= 1'b0;
            capture_test_mode_d <= 1'b0;
            capture_sample_divider <= 2'd0;
            trigger_wait_samples <= 10'd0;
            display_bank      <= 1'b1;
            display_valid     <= 1'b0;
        end else begin
            capture_test_mode_d <= test_mode_active;

            if (test_mode_active != capture_test_mode_d) begin
                capture_write_ptr <= 8'd0;
                capture_ready <= 1'b0;
                capture_active <= ~test_mode_active;
                capture_trigger_armed <= 1'b0;
                capture_sample_divider <= 2'd0;
                trigger_wait_samples <= 10'd0;
            end else if (frame_start && capture_ready) begin
                display_bank      <= capture_bank;
                display_valid     <= 1'b1;
                capture_bank      <= ~capture_bank;
                capture_write_ptr <= 8'd0;
                capture_ready     <= 1'b0;
                capture_active    <= ~test_mode_active;
                capture_trigger_armed <= 1'b0;
                capture_sample_divider <= 2'd0;
                trigger_wait_samples <= 10'd0;
            end else if (audio_sample_valid && !capture_ready) begin
                if (test_mode_active && !capture_active) begin
                    // Auto-trigger after 1024 valid samples without a crossing.
                    // Silence, DC and quiet tails must replace the old trace.
                    // Count samples, not pixel clocks; keep normal 4:1 capture.
                    if ((capture_trigger_armed && scope_trigger_high) ||
                        trigger_wait_samples == 10'd1023) begin
                        capture_active <= 1'b1;
                        capture_trigger_armed <= 1'b0;
                        capture_sample_divider <= 2'd0;
                        trigger_wait_samples <= 10'd0;
                    end else begin
                        trigger_wait_samples <= trigger_wait_samples + 10'd1;
                        if (!capture_trigger_armed) begin
                        if (scope_trigger_low)
                            capture_trigger_armed <= 1'b1;
                        end
                    end
                end else begin
                    if (!test_mode_active ||
                        (capture_sample_divider == 2'd0)) begin
                        sample_history[{capture_bank, capture_write_ptr}]
                            <= capture_sample;

                        if (capture_write_ptr == 8'hff) begin
                            capture_ready <= 1'b1;
                            capture_active <= 1'b0;
                        end else begin
                            capture_write_ptr <= capture_write_ptr + 8'd1;
                        end
                    end

                    capture_sample_divider <= test_mode_active
                                            ? capture_sample_divider + 2'd1
                                            : 2'd0;
                end
            end
        end
    end

    always @* begin
        text_red = 6'd0; text_green = 6'd0; text_blue = 6'd0;
        text_enable = 1'b0; text_force = 1'b0;
        base_red   = 6'd0;
        base_green = 6'd0;
        base_blue  = 6'd0;

        if (data_enable) begin
            base_red   = 6'd1;
            base_green = 6'd3;
            base_blue  = 6'd5;

            if (setting_mode_active) begin
                base_red = 6'd1; base_green = 6'd4; base_blue = 6'd8;
                if (settings_title_bar_region) begin
                    base_red = 6'd3;
                    base_green = settings_title_selected ? 6'd18 : 6'd7;
                    base_blue = settings_title_selected ? 6'd30 : 6'd12;
                    if (settings_title_bar_border) begin
                        if (settings_title_selected && (selected_field_active == 3'd7)) begin
                            base_red = 6'd63; base_green = 6'd44; base_blue = 6'd4;
                        end else begin
                            base_red = 6'd8; base_green = 6'd43; base_blue = 6'd52;
                        end
                    end else if (settings_title_glyph_on) begin
                        text_enable = 1'b1;
                        text_red = settings_title_selected ? 6'd63 : 6'd32;
                        text_green = settings_title_selected ? 6'd56 : 6'd42;
                        text_blue = settings_title_selected ? 6'd8 : 6'd48;
                    end
                end else if (settings_panel_region) begin
                    base_red = 6'd2; base_green = 6'd6; base_blue = 6'd10;
                    if (settings_panel_border) begin
                        base_red = 6'd8; base_green = 6'd43; base_blue = 6'd52;
                    end else if (settings_row_region) begin
                        base_red   = settings_row_selected ? 6'd4  : 6'd2;
                        base_green = settings_row_selected ? 6'd18 : 6'd8;
                        base_blue  = settings_row_selected ? 6'd30 : 6'd14;
                        if (settings_row_border) begin
                            base_red   = settings_row_selected ? 6'd63 : 6'd5;
                            base_green = settings_row_selected ? 6'd44 : 6'd30;
                            base_blue  = settings_row_selected ? 6'd4  : 6'd38;
                        end else if (settings_glyph_on) begin
                        text_enable = 1'b1;
                            text_red   = settings_row_selected ? 6'd63 : 6'd45;
                            text_green = settings_row_selected ? 6'd56 : 6'd61;
                            text_blue  = settings_row_selected ? 6'd8  : 6'd63;
                        end
                    end
                end else if (settings_hint_on) begin
                        text_enable = 1'b1;
                    text_red = 6'd38; text_green = 6'd52; text_blue = 6'd57;
                end
            end else if (status_panel_region) begin
                base_red   = status_line_selected ? 6'd0  : 6'd2;
                base_green = status_line_selected ? 6'd2  : 6'd7;
                base_blue  = status_line_selected ? 6'd12 : 6'd13;

                if (status_panel_border) begin
                    base_red   = 6'd7;
                    base_green = 6'd43;
                    base_blue  = 6'd52;
                end else if (status_level_border) begin
                    base_red = 6'd8; base_green = 6'd42; base_blue = 6'd48;
                end else if (status_level_fill) begin
                    if (active_x < 11'd740) begin
                        base_red = 6'd6; base_green = 6'd58; base_blue = 6'd19;
                    end else if (active_x < 11'd760) begin
                        base_red = 6'd63; base_green = 6'd48; base_blue = 6'd5;
                    end else begin
                        base_red = 6'd63; base_green = 6'd10; base_blue = 6'd5;
                    end
                end else if (status_glyph_on) begin
                        text_enable = 1'b1;
                        text_force = status_count_slash_pixel;
                    text_red   = status_line_selected ? 6'd63 : 6'd31;
                    text_green = status_line_selected ? 6'd45 : 6'd63;
                    text_blue  = status_line_selected ? 6'd4  : 6'd60;
                end
            end else if (line_y_ge_12 && line_y_lt_82) begin
                if ((active_x >= 11'd16) && (active_x < 11'd74)) begin
                    if ((active_x == 11'd16) || (active_x == 11'd73) ||
                        line_y_eq_12 || line_y_eq_81) begin
                        base_red = 6'd5; base_green = 6'd43; base_blue = 6'd52;
                    end else begin
                        base_red   = key_pressed_active[0] ? 6'd24 : 6'd63;
                        base_green = key_pressed_active[0] ? 6'd4  : 6'd10;
                        base_blue  = key_pressed_active[0] ? 6'd5  : 6'd13;
                    end
                end else if ((active_x >= 11'd88) && (active_x < 11'd146)) begin
                    if ((active_x == 11'd88) || (active_x == 11'd145) ||
                        line_y_eq_12 || line_y_eq_81) begin
                        base_red = 6'd5; base_green = 6'd43; base_blue = 6'd52;
                    end else begin
                        base_red   = key_pressed_active[1] ? 6'd3  : 6'd5;
                        base_green = key_pressed_active[1] ? 6'd24 : 6'd63;
                        base_blue  = key_pressed_active[1] ? 6'd5  : 6'd14;
                    end
                end else if ((active_x >= 11'd160) && (active_x < 11'd218)) begin
                    if ((active_x == 11'd160) || (active_x == 11'd217) ||
                        line_y_eq_12 || line_y_eq_81) begin
                        base_red = 6'd5; base_green = 6'd43; base_blue = 6'd52;
                    end else begin
                        base_red   = key_pressed_active[2] ? 6'd4  : 6'd8;
                        base_green = key_pressed_active[2] ? 6'd11 : 6'd29;
                        base_blue  = key_pressed_active[2] ? 6'd24 : 6'd63;
                    end
                end
            end else if (piano_note_valid) begin
                if (piano_key_border) begin
                    base_red   = 6'd2;
                    base_green = 6'd19;
                    base_blue  = 6'd24;
                end else if (piano_note_pressed) begin
                    base_red   = 6'd63;
                    base_green = 6'd47;
                    base_blue  = 6'd7;
                end else if (piano_note_selected) begin
                    base_red   = piano_note_is_black ? 6'd3  : 6'd13;
                    base_green = piano_note_is_black ? 6'd31 : 6'd49;
                    base_blue  = piano_note_is_black ? 6'd43 : 6'd56;
                end else if (piano_note_is_black) begin
                    base_red = 6'd1; base_green = 6'd3; base_blue = 6'd5;
                end else begin
                    base_red = 6'd55; base_green = 6'd59; base_blue = 6'd60;
                end
                if (!piano_key_border && piano_label_on) begin
                    text_enable = 1'b1;
                    if (piano_note_is_black) begin
                        text_red = 6'd23; text_green = 6'd54; text_blue = 6'd59;
                    end else begin
                        text_red = 6'd2; text_green = 6'd8; text_blue = 6'd11;
                    end
                end
            end else if ((active_x >= 11'd16) && (active_x < (COMPACT_SCOPE ? 11'd528 : 11'd784)) &&
                         line_scope) begin
                if ((active_x == 11'd16) || (active_x == (COMPACT_SCOPE ? 11'd527 : 11'd783)) ||
                    line_scope_border) begin
                    base_red = 6'd4; base_green = 6'd35; base_blue = 6'd44;
                end else if (display_valid &&
                    (((active_y_signed >= wave_y - 11'sd1) &&
                      (active_y_signed <= wave_y + 11'sd1)) ||
                     square_edge_pixel)) begin
                    base_red   = 6'd63;
                    base_green = 6'd56;
                    base_blue  = 6'd4;
                end else if ((active_x[5:0] == 6'd0) ||
                             line_scope_grid) begin
                    base_red = 6'd2; base_green = 6'd14; base_blue = 6'd20;
                end else begin
                    base_red = 6'd1; base_green = 6'd5; base_blue = 6'd8;
                end
            end
        end
    end

endmodule

`default_nettype wire
