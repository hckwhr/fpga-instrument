`default_nettype none

module av_top #(
    parameter integer HALF_RATE_ENABLE = 0,
    parameter integer LARGE_SCORE_ENABLE = 0,
    parameter integer SONG_UPLOAD_ENABLE = 0,
    parameter integer SCORE_PLAYBACK_ENABLE = 0,
    parameter integer SHARED_CLKS_PER_BIT = 5208,
    parameter integer HC05_CLKS_PER_BIT = 5120,
    parameter integer FSR_ENABLE = 0,
    parameter integer V3_INPUT_ENABLE = 0,
    parameter integer V3_ANALOG_KEYS_ENABLE = 0,
    parameter integer LEGACY_VOICE_ENABLE = 1,
    parameter integer ADDITIVE_BANK_ENABLE = 1,
    parameter integer STRING_BANK_ENABLE = 1,
    parameter integer BRIGHT_OUTPUT_ENABLE = 0,
    parameter integer RGB_PIXELS_PER_KEY = 3,
    parameter integer RGB_STARTUP_TEST_ENABLE = 0,
    // 50 MHz sys_clk: 250 us idle + 16 us SPI, about 3.76 ksample/s.
    // Keep the 1 MHz SPI clock and the existing pressure filter/onset guard.
    parameter integer FSR_SAMPLE_PERIOD_CYCLES = 12500
) (
    input  wire       sys_clk,
    input  wire       key0_n,
    input  wire       key1_n,
    input  wire       key2_n,
    input  wire       setting_key,
    input  wire       hc05_rx,
    input  wire       adc_miso,
    input  wire       key_serial,
    output wire       key_load_n,key_shift_clk,pluck_debug,
    output wire       adc_sclk, adc_mosi, adc_cs0_n, adc_cs1_n,
    output wire [3:0] adc_led,
    output wire       hc05_tx,
    output wire       status_led,
    output wire       ws2812_data,
    output wire       led_enable,
    output wire       audio_bck,
    output wire       audio_ws,
    output wire       audio_din,
    output wire       audio_pa_en_n,
    output wire       lcd_pclk,
    output wire       lcd_hsync,
    output wire       lcd_vsync,
    output wire       lcd_de,
    output wire       lcd_bl,
    output wire [5:0] lcd_r,
    output wire [5:0] lcd_g,
    output wire [5:0] lcd_b
);

    `include "instrument_contract.vh"

    localparam [24:0] HEARTBEAT_HALF_PERIOD_CYCLES = 25'd25_000_000;
    reg [1:0]  sys_reset_sync_n;
    reg [1:0]  audio_reset_sync_n;
    reg [1:0]  pixel_reset_sync_n;
    reg [1:0]  audio_lock_sys_sync;
    reg [1:0]  pixel_lock_sys_sync;
    reg [24:0] heartbeat_counter;
    reg        heartbeat_led_on;

    wire sys_internal_reset_n;
    wire sys_async_reset_n;
    wire audio_clk;
    wire audio_pll_locked;
    wire audio_async_reset_n;
    wire audio_internal_reset_n;
    wire audio_sample_strobe;
    // Common phase, no fabric clock. All ordinary engine state advances on
    // half_tick; reset release and the serializer remain on the physical clock.
    reg half_tick;
    wire engine_ce = !HALF_RATE_ENABLE || half_tick;
    always @(posedge audio_clk or negedge audio_internal_reset_n)
        if(!audio_internal_reset_n) half_tick<=1'b0;
        else half_tick<=!half_tick;

    // Capture the serializer pulse on either phase. A pending pulse is cleared
    // only by an enabled accepting edge; there is exactly one engine sample per
    // unchanged 1024-clock stereo frame (512 engine steps).
    reg sample_pending;
    wire engine_sample_strobe = audio_sample_strobe || sample_pending;
    always @(posedge audio_clk or negedge audio_internal_reset_n)
        if(!audio_internal_reset_n) sample_pending<=1'b0;
        else if(engine_ce) sample_pending<=1'b0;
        else if(audio_sample_strobe) sample_pending<=1'b1;
    wire pixel_clk;
    wire lcd_pll_locked;
    wire pixel_async_reset_n;
    wire pixel_internal_reset_n;
    wire key0_pressed;
    wire key1_pressed;
    wire key2_pressed;
    wire setting_key_pressed;
    wire board_key0,board_key1,board_key2,board_setting;
    wire [15:0] v3_keys;
    wire [6:0] v3_force;
    wire [83:0] v3_key_forces;
    wire signed [7:0] v3_bend;
    wire [7:0] v3_vibrato;
    wire v3_pressure,v3_ready;
    wire [2:0] key_play_trigger;
    wire       key_play_mute;
    wire       setting_mode;
    wire       settings_page;
    wire [2:0] selected_field;
    wire       play_mode;
    wire [1:0] tone_select;
    wire string_mode;
    wire keyboard_piano;
    localparam integer KEYBOARD_MODE_ENABLE=V3_ANALOG_KEYS_ENABLE && !ADDITIVE_BANK_ENABLE;
    // Piano is a live keyboard overlay, not a destructive preset. The stored
    // tone/string/effect/expression choices return unchanged in original mode.
    // Decode the new overlay before it enters the existing broadcast source
    // selection. Stage59's keyboard_piano combinational cone reached 5159
    // sequential inputs (3929 in the string bank). Do not distribute another
    // menu-controlled LUT through that cone or apply a maxfan workaround.
    // Both menu values change only while setting_mode keeps the engines muted.
    // One common-CE step (2 physical clocks in production) settles this decode
    // before a released/rearmed pressure key can be accepted. Flush/rearm and
    // the additional keyboard_string_owner stage remain unchanged.
    reg live_string_mode_q;
    always @(posedge audio_clk or negedge audio_internal_reset_n)
        if(!audio_internal_reset_n) live_string_mode_q<=DEFAULT_STRING;
        else if(engine_ce) live_string_mode_q<=string_mode && !keyboard_piano;
    wire live_string_mode=KEYBOARD_MODE_ENABLE ? live_string_mode_q : string_mode;
    wire signed [15:0] string_sample;
    wire [7:0] string_active_voices;
    wire [3:0] string_voice_count;
    wire [7:0] string_deadline_misses;
    wire [5:0] displayed_voice_count;
    wire [3:0] note_select;
    wire [6:0] force_value;
    wire       keymap_select;
    wire [1:0] octave_select;
    wire [1:0] effect_select;
    wire [1:0] effect_strength;
    wire [1:0] glide_select, vibrato_select;
    wire audition_mode, audition_wet, audition_mute;
    wire audition_active /* synthesis syn_keep = 1 syn_maxfan = 8 */;
    wire [2:0] audition_gates;
    wire [3:0] audition_note;
    wire [2:0] audition_target, audition_trigger;
    wire [6:0] audition_force;
    wire song_active /* synthesis syn_keep = 1 syn_maxfan = 8 */;
    wire uploaded_run,uploaded_valid,uploaded_flush,uploaded_on,uploaded_melody,uploaded_ready;
    wire [15:0] uploaded_id;
    wire [3:0] uploaded_note;
    wire [1:0] uploaded_octave;
    wire [6:0] uploaded_force;
    wire [2:0] uploaded_state;
    wire [11:0] uploaded_index,uploaded_length;
    wire [1:0] uploaded_tempo;
    reg uploaded_selected;
    wire remote_song_start, remote_song_stop;
    wire score_active=song_active || uploaded_selected;
    wire upload_local_stop=key1_pressed || setting_key_pressed || setting_mode || remote_song_start || remote_song_stop || song_active;
    always @(posedge audio_clk or negedge audio_internal_reset_n)begin
        if(!audio_internal_reset_n)uploaded_selected<=0;
        else if (engine_ce) if(SONG_UPLOAD_ENABLE==0 || setting_key_pressed || setting_mode || remote_song_start || song_active)uploaded_selected<=0;
        else if(uploaded_run)uploaded_selected<=1;
    end
    wire song_gate, song_trigger, song_done;
    wire [3:0] song_note;
    wire [1:0] song_octave;
    wire [6:0] song_force;
    wire [7:0] song_note_index;
    wire song_select, song_change, song_accompaniment;
    wire signed [15:0] song_audio_sample;
    wire [1:0] song_tempo;
    wire [3:0] twinkle_note, ode_note;
    wire [11:0] twinkle_duration, ode_duration, twinkle_gate, ode_gate;
    wire [7:0] twinkle_length, ode_length;
    wire [1:0] twinkle_octave, ode_octave;
    wire [6:0] twinkle_force, ode_force;
    wire [7:0] song_score_index, song_score_length;
    wire [3:0] song_score_note;
    wire [1:0] song_score_octave;
    wire [6:0] song_score_force;
    wire [23:0] song_score_duration, song_score_gate;
    wire song_event_valid, song_event_ready, song_event_flush, song_event_on;
    wire song_display_ready, song_bank_ready;
    wire poly_bank_ready;
    wire [11:0] song_held_notes;
    wire ensemble_ready, ensemble_valid, ensemble_on, ensemble_fault, ensemble_melody;
    wire timeline_flush, timeline_done;
    wire [7:0] timeline_note_index, timeline_length;
    wire [8:0] timeline_rom_index;
    wire [9:0] timeline_event_count;
    wire [23:0] timeline_end_tick;
    wire [63:0] timeline_data;
    wire solo_valid, solo_ready, solo_flush, solo_on, solo_done;
    wire [7:0] solo_note_index;
    wire [15:0] solo_id;
    wire [3:0] solo_note;
    wire [1:0] solo_octave;
    wire [6:0] solo_force;
    wire [15:0] ensemble_id;
    wire [3:0] ensemble_note;
    wire [1:0] ensemble_octave;
    wire [6:0] ensemble_force;
    wire [15:0] song_event_id;
    wire [3:0] song_event_note;
    wire [1:0] song_event_octave;
    wire [6:0] song_event_force;
    wire song_receiver_ready = song_bank_ready;
    assign song_event_ready = song_display_ready && song_receiver_ready;
    assign solo_ready = !uploaded_selected && !song_accompaniment && song_event_ready;
    assign ensemble_ready = !uploaded_selected && song_bank_ready && (!ensemble_melody || song_display_ready);
    assign uploaded_ready=uploaded_selected && song_bank_ready && (!uploaded_melody || song_display_ready);
    assign song_event_valid = uploaded_selected ? (uploaded_valid && uploaded_melody) : song_accompaniment ? (ensemble_valid && ensemble_melody) : solo_valid;
    assign song_event_on = uploaded_selected ? uploaded_on : song_accompaniment ? ensemble_on : solo_on;
    assign song_event_id = uploaded_selected ? uploaded_id : song_accompaniment ? ensemble_id : solo_id;
    assign song_event_note = uploaded_selected ? uploaded_note : song_accompaniment ? ensemble_note : solo_note;
    assign song_event_octave = uploaded_selected ? uploaded_octave : song_accompaniment ? ensemble_octave : solo_octave;
    assign song_event_force = uploaded_selected ? uploaded_force : song_accompaniment ? ensemble_force : solo_force;
    assign song_event_flush = uploaded_selected ? uploaded_flush : song_accompaniment ? timeline_flush : solo_flush;
    assign song_done = song_accompaniment ? timeline_done : solo_done;
    assign song_note_index = song_accompaniment ? timeline_note_index : solo_note_index;
    wire [6:0] audition_play_force = (audition_target==5 && audition_wet)?audition_force:7'd96;
    wire [1:0] audition_tone = (audition_target>=2)?2'd3:2'd0;
    wire [6:0] performance_force;
    wire signed [7:0] performance_bend;
    wire [7:0] performance_vibrato;
    wire [6:0] fsr_force;
    wire fsr_gate, fsr_trigger, fsr_ready;
    wire v3_live;
    wire v3_keyboard_live, v3_string_live, string_event_mode, string_event_ready;
    reg poly_event_mode /* synthesis syn_maxfan = 8 */;
    reg keyboard_string_owner;
    always @(posedge audio_clk or negedge audio_internal_reset_n)
        if(!audio_internal_reset_n) keyboard_string_owner<=0;
        else if(engine_ce) keyboard_string_owner<=live_string_mode;
    // A mode transition cancels queued events before either new owner accepts.
    // The registered polyphony mode must be off before strings may accept.
    wire keyboard_enable = v3_keyboard_live && (keyboard_string_owner==live_string_mode) &&
        (!live_string_mode || !poly_event_mode);
    assign string_event_mode = v3_string_live && !poly_event_mode;
    wire v3_valid,v3_on;
    wire [15:0] v3_id;
    wire [3:0] v3_note;
    wire [1:0] v3_octave;
    wire [6:0] v3_velocity;
    wire [11:0] v3_held_notes;
    reg poly_live;
    wire v3_bank_ready=string_event_mode ? string_event_ready :
        (song_bank_ready && poly_live && v3_live);
    keyboard_note_events #(.CE_ENABLE(HALF_RATE_ENABLE),.PER_KEY_FORCE_ENABLE(V3_ANALOG_KEYS_ENABLE)) u_v3_events(.clock_enable(engine_ce),
        .clk(audio_clk),.reset_n(audio_internal_reset_n),.enable(keyboard_enable),.keys(v3_keys[11:0]),
        .octave(octave_select),.velocity(v3_pressure ? v3_force : force_value),
        .key_forces(v3_key_forces),
        .event_ready(v3_bank_ready),.event_valid(v3_valid),.event_on(v3_on),.event_id(v3_id),
        .event_note(v3_note),.event_octave(v3_octave),.event_force(v3_velocity),.held_notes(v3_held_notes));
    assign pluck_debug=V3_INPUT_ENABLE && v3_valid && v3_bank_ready && v3_on;
    wire [2:0] live_voice_gate={key2_pressed,key1_pressed,key0_pressed | fsr_gate};
    wire [2:0] live_voice_trigger=key_play_trigger | {2'b00,fsr_trigger};
    wire [6:0] live_force=fsr_gate ? fsr_force : performance_force;
    wire audition_effects = audition_target>=2 && audition_target<=4;
    wire audition_strings = audition_active && audition_target==6 && audition_wet;
    // Reuse the 32 independent lanes for A/B demonstrations. The retired DDS
    // stays disabled; manual-bank ownership also retains its tested glide.
    wire bank_audition = !LEGACY_VOICE_ENABLE && audition_active && !song_active;
    // Ordinary DDS and physical strings share the audition/manual event route.
    // performance_force feeds all live engines; bend/vibrato remain DDS-only.
    wire [2:0] routed_voice_trigger = song_active ? {2'b00,song_trigger} :
        audition_active ? audition_trigger : live_voice_trigger;
    wire [2:0] routed_voice_gate = song_active ? {2'b00,song_gate} :
        audition_active ? audition_gates : live_voice_gate;
    wire       routed_play_mode = audition_active ? 1'b0 : play_mode;
    wire [1:0] routed_tone = audition_active ? audition_tone : tone_select;
    wire       routed_keymap = audition_active ? 1'b0 : keymap_select;
    // Decode the audition target in parallel with mode ownership. Nesting
    // song_active outside audition_active duplicates the mode path before
    // the DDS lookup and phase accumulator (post-route timing critical).
    wire [3:0] routed_note = audition_active
        ? ((audition_target == 3'd7) ? song_note : audition_note) : note_select;
    wire [1:0] routed_octave = song_active ? song_octave :
        (audition_active ? 2'd1 : octave_select);
    wire [6:0] routed_force = song_active ? song_force :
        (audition_active ? audition_play_force : live_force);
    wire signed [7:0] routed_bend = audition_active ? 8'sd0 : performance_bend;
    wire [1:0] routed_glide = audition_active
        ? ((audition_wet && audition_target==0) ? 2'd3 : 2'd0) : glide_select;
    wire [7:0] routed_vibrato = audition_active
        ? ((audition_wet && audition_target==1) ? 8'd128 : 8'd0) : performance_vibrato;
    wire [6:0] routed_string_force = audition_active ? 7'd96 : live_force;
    wire       string_path_active = !score_active &&
        ((audition_active ? string_mode : live_string_mode) || audition_strings);
    wire       routed_audio_mute = setting_mode ||
        (audition_active && !song_active && audition_mute);
    wire [1:0] audition_effect = audition_target==2?2'd1:audition_target==3?2'd2:2'd3;
    wire signed [15:0] effects_input;
    wire [CONTROL_STATUS_WIDTH-1:0] displayed_status_payload;
    wire       test_mode;
    wire       test_polyphony;
    wire       self_test_active;
    // All-engine self-test: polyphony, strings and the additive bank sound at
    // once so a spectrum capture can count every independent unit.
    wire        test_concurrent;
    wire        concurrent_active = self_test_active && test_polyphony && test_concurrent;
    wire        concurrent_event_valid;
    wire [15:0] concurrent_event_id;
    wire [3:0]  concurrent_event_note, concurrent_string_note;
    wire [1:0]  concurrent_event_octave, concurrent_string_octave;
    wire [6:0]  concurrent_event_force;
    wire [2:0]  concurrent_string_trigger;
    reg signed [15:0] concurrent_mix;
    wire [1:0] active_effect_select;
    wire [CONTROL_STATUS_WIDTH-1:0] status_payload_audio;
    wire [DISPLAY_STATUS_WIDTH-1:0] status_payload_cdc_audio;
    wire [DISPLAY_STATUS_WIDTH-1:0] status_payload_pixel;
    wire [11:0] upload_status_audio={uploaded_index[11:8],uploaded_length[11:8],uploaded_selected,uploaded_state};
    wire [11:0] upload_status_pixel;
    wire        status_payload_update_pixel;
    wire signed [15:0] raw_audio_sample;
    reg signed [15:0] live_mix_sample;
    wire signed [15:0] additive_test_sample;
    wire signed [15:0] polyphony_test_sample;
    wire signed [15:0] pre_effect_audio_sample;
    wire signed [15:0] dry_half=pre_effect_audio_sample/16'sd2;
    wire signed [15:0] dry_quarter=pre_effect_audio_sample/16'sd4;
    wire signed [15:0] audition_dry=(effect_strength==0)?dry_half+dry_quarter:
        (effect_strength==1)?dry_half:dry_quarter;
    wire signed [15:0] audition_source = audition_active && audition_effects && !audition_wet
        ? audition_dry:pre_effect_audio_sample;
    // Gentle feed-forward shelf: DC gain 1, Nyquist gain 1.5 (+3.52 dB).
    // No change to the waveguide loop, delay RAM or tuning tables. Register
    // once per PCM slot; effects consume the previous settled sample as before.
    generate if(BRIGHT_OUTPUT_ENABLE) begin: bright_output
        reg signed [15:0] previous_sample, bright_sample;
        wire signed [17:0] current_wide={{2{audition_source[15]}},audition_source};
        wire signed [17:0] previous_wide={{2{previous_sample[15]}},previous_sample};
        wire signed [17:0] bright_value=current_wide+((current_wide-previous_wide)>>>2);
        always @(posedge audio_clk or negedge audio_internal_reset_n)
            if(!audio_internal_reset_n)begin previous_sample<=0;bright_sample<=0;end
            else if(engine_ce && engine_sample_strobe)begin
                previous_sample<=routed_audio_mute ? 16'sd0 : audition_source;
                bright_sample<=routed_audio_mute ? 16'sd0 :
                    bright_value>18'sd32767 ? 16'sh7fff :
                    bright_value < -18'sd32768 ? 16'sh8000 : bright_value[15:0];
            end
        assign effects_input=bright_sample;
    end else begin: original_output
        assign effects_input=audition_source;
    end endgenerate
    wire signed [15:0] audio_sample;
    wire additive_all_partials_active;
    wire [5:0] polyphony_active_voice_count;
    wire polyphony_all_voices_active;
    // One coherent clock stage separates source selection from DDS/ADSR
    // arithmetic. Delay the sample enable with every control/event input.
    // Downstream effects consume the previous sample, so their audio cadence
    // stays unchanged; a full slot contains 1024 clocks.
    reg dds_sample_strobe, dds_mute, dds_play_mode, dds_keymap;
    // Same-cycle song ownership also feeds the polyphonic bank after merging.
    // The routed shared register drove 895 loads; allow local data drivers.
    reg dds_song_release /* synthesis syn_maxfan = 8 */;
    reg [2:0] dds_trigger, dds_gate;
    reg [1:0] dds_tone, dds_octave, dds_glide;
    reg [3:0] dds_note;
    reg [6:0] dds_force;
    reg signed [7:0] dds_bend;
    reg [7:0] dds_vibrato;
    always @(posedge audio_clk or negedge audio_internal_reset_n) begin
        if (!audio_internal_reset_n) begin
            dds_sample_strobe<=0; dds_mute<=1; dds_play_mode<=0; dds_keymap<=0;
            dds_song_release<=0;
            dds_trigger<=0; dds_gate<=0; dds_tone<=0; dds_octave<=0;
            dds_glide<=0; dds_note<=0; dds_force<=0; dds_bend<=0; dds_vibrato<=0;
        end else if (engine_ce) begin
            dds_sample_strobe<=engine_sample_strobe;
            dds_song_release<=score_active;
            dds_mute<=key_play_mute || string_mode || score_active || (audition_active && !song_active && audition_mute);
            dds_play_mode<=routed_play_mode; dds_keymap<=routed_keymap;
            dds_trigger<=routed_voice_trigger; dds_gate<=routed_voice_gate;
            dds_tone<=routed_tone; dds_octave<=routed_octave; dds_glide<=routed_glide;
            dds_note<=routed_note; dds_force<=routed_force;
            dds_bend<=routed_bend; dds_vibrato<=routed_vibrato;
        end
    end
    wire audio_stream_ready;
    wire [31:0] pixel_audio_pair;
    wire signed [15:0] pixel_audio_sample = pixel_audio_pair[15:0];
    wire [1023:0] spectrum_audio,spectrum_pixel;
    wire spectrum_update_pixel,spectrum_frame_valid;
    wire [7:0] spectrum_deadline_misses;
    wire visual_overlay;
    wire [17:0] visual_rgb;
    reg [17:0] base_rgb_delay;
    reg [1:0] hsync_delay,vsync_delay,de_delay;

    wire pixel_audio_sample_valid;
    wire lcd_hsync_internal;
    wire lcd_vsync_internal;
    wire lcd_de_internal;
    wire lcd_hsync_timing;
    wire lcd_vsync_timing;
    wire lcd_de_timing;
    wire lcd_frame_start;
    wire [10:0] lcd_active_x;
    wire [9:0] lcd_active_y;
    wire [5:0] lcd_r_internal;
    wire [5:0] lcd_g_internal;
    wire [5:0] lcd_b_internal;
    wire       lcd_pclk_tristate;

    assign sys_async_reset_n      = audio_pll_locked & lcd_pll_locked;
    assign sys_internal_reset_n   = sys_reset_sync_n[1];
    assign audio_async_reset_n    = audio_pll_locked;
    assign audio_internal_reset_n = audio_reset_sync_n[1];
    assign pixel_async_reset_n    = lcd_pll_locked;
    assign pixel_internal_reset_n = pixel_reset_sync_n[1];

    assign status_led    = (audio_lock_sys_sync[1] && pixel_lock_sys_sync[1])
                         ? ~heartbeat_led_on : 1'b0;
    assign audio_pa_en_n = ~(audio_stream_ready && audio_internal_reset_n);
    assign key0_pressed=board_key0 | (V3_INPUT_ENABLE && setting_mode && v3_keys[13]);
    assign key1_pressed=board_key1 | (V3_INPUT_ENABLE && v3_keys[15]);
    assign key2_pressed=board_key2 | (V3_INPUT_ENABLE && setting_mode && v3_keys[14]);
    assign setting_key_pressed=board_setting | (V3_INPUT_ENABLE && v3_keys[12]);
    assign song_bank_ready=poly_bank_ready && (poly_live==v3_live);
    assign v3_keyboard_live=V3_INPUT_ENABLE && v3_ready && !score_active && !setting_mode &&
        !setting_key_pressed && !audition_active && !self_test_active;
    assign v3_live=v3_keyboard_live && !live_string_mode;
    assign v3_string_live=STRING_BANK_ENABLE && v3_keyboard_live && live_string_mode;
    assign displayed_voice_count = (string_path_active && !self_test_active)
        ? {2'd0,string_voice_count} : polyphony_active_voice_count;
    // audition_active, song_active and self_test_active are registered in
    // instrument_control from next-state values (stage 30b); same value on
    // every clock as the former combinational decodes here.
    assign displayed_status_payload = uploaded_selected
        ? {2'b00,active_effect_select,1'b0,selected_field,1'b0,2'd3,
           song_note,song_force,1'b0,song_octave,2'b00,song_gate}
        : audition_active
        ? {2'b00,active_effect_select,1'b0,selected_field,1'b0,
           audition_tone,
           song_active ? song_note : audition_note,
           song_active ? song_force : audition_play_force,
           1'b0,
           song_active ? song_octave : 2'd1,
           song_active ? {2'b00,song_gate} : audition_gates}
        : ((FSR_ENABLE || V3_INPUT_ENABLE) && !setting_mode && !self_test_active)
            ? {status_payload_audio[27:13],live_force,status_payload_audio[5:3],live_voice_gate}
            : status_payload_audio;
    // In active song context keymap/force are not drawn; carry actual score
    // length in the same atomic CDC transaction without expanding the bus.
    assign status_payload_cdc_audio[CONTROL_STATUS_WIDTH-1:0] = score_active
        ? {displayed_status_payload[27:13],uploaded_selected ? uploaded_length[7:0] : song_score_length,displayed_status_payload[4:0]}
        : (KEYBOARD_MODE_ENABLE && keyboard_piano && v3_live)
        ? {displayed_status_payload[27:19],2'd3,displayed_status_payload[16:0]}
        : displayed_status_payload;
    assign status_payload_cdc_audio[ST_STRENGTH +: 2] = effect_strength;
    assign status_payload_cdc_audio[ST_AUDITION_TARGET +: 3] = uploaded_selected ? 3'd7 : audition_target;
    // For the song target this slot reports completion, never an A/B state.
    assign status_payload_cdc_audio[ST_AUDITION_WET] = uploaded_selected ? !uploaded_run : song_active ? song_done : audition_wet;
    assign status_payload_cdc_audio[ST_AUDITION_ACTIVE] = audition_active || uploaded_selected;
    assign status_payload_cdc_audio[ST_AUDITION_ARMED] = audition_mode;
    wire song_menu_context=setting_mode && audition_target==3'd7 &&
        configured_settings_field_id(settings_page,selected_field,
            ADDITIVE_BANK_ENABLE!=0,STRING_BANK_ENABLE!=0)==FIELD_AUDITION;
    assign status_payload_cdc_audio[ST_VIBRATO +: 2] = uploaded_selected ? uploaded_tempo : (song_active || song_menu_context) ? song_tempo : vibrato_select;
    assign status_payload_cdc_audio[ST_GLIDE +: 2] = (song_active || song_menu_context) ? {song_accompaniment,song_select} : glide_select;
    assign status_payload_cdc_audio[ST_DEADLINES +: 8] =
        uploaded_selected ? uploaded_index[7:0] : song_active ? song_note_index : string_deadline_misses;
    assign status_payload_cdc_audio[ST_PAGE] = settings_page;
    assign status_payload_cdc_audio[ST_STRING] = setting_mode ? string_mode : string_path_active;
    assign status_payload_cdc_audio[ST_VOICES +: 6] = displayed_voice_count;
    assign status_payload_cdc_audio[ST_HELD_NOTES +: 12] =
        (KEYBOARD_MODE_ENABLE && setting_mode) ? {keyboard_piano,11'd0} :
        v3_string_live ? v3_held_notes : (score_active || v3_live) ? song_held_notes : 12'd0;
    // Uploaded instrumental scores use a repeatable dry sound. Do not inherit
    // the last live-keyboard effect; manual/audition effect choices are retained.
    assign active_effect_select = (SCORE_PLAYBACK_ENABLE && uploaded_selected) ? 2'd0 : self_test_active ? 2'd0 : audition_active
        ? ((audition_effects && audition_wet)?audition_effect:2'd0):effect_select;
    assign pre_effect_audio_sample = self_test_active
                                   ? (test_polyphony
                                      ? ((test_concurrent && ADDITIVE_BANK_ENABLE) ? concurrent_mix
                                                         : polyphony_test_sample)
                                      : (ADDITIVE_BANK_ENABLE ? additive_test_sample : polyphony_test_sample))
                                    : score_active ? song_audio_sample
                                    : v3_live ? live_mix_sample
                                    : bank_audition && !audition_strings ? song_audio_sample
                                    : ((STRING_BANK_ENABLE && string_path_active) ? string_sample : raw_audio_sample);
    // Board keys retain their three-voice engine while the twelve external
    // keys own the event bank. Both samples settle before the next audio slot.
    wire signed [16:0] live_mix_sum =
        $signed({raw_audio_sample[15],raw_audio_sample}) +
        $signed({song_audio_sample[15],song_audio_sample});
    generate if(LEGACY_VOICE_ENABLE) begin: legacy_mix
    always @(posedge audio_clk or negedge audio_internal_reset_n)
        if(!audio_internal_reset_n)live_mix_sample<=16'sd0;
        else if (engine_ce) live_mix_sample<=live_mix_sum>17'sd32767 ? 16'sh7fff :
            live_mix_sum < -17'sd32768 ? 16'sh8000 : live_mix_sum[15:0];
    end else begin: event_mix
        always @* live_mix_sample=song_audio_sample;
    end endgenerate
    // Fixed score gain, independent of voice count: no loudness pumping as
    // harmony starts/releases. Wide signed shift and final saturation protect
    // against malformed future scores; the current five-note score is measured.
    wire signed [18:0] song_boost = {polyphony_test_sample,3'b000};
    assign song_audio_sample = song_boost>19'sd32767 ? 16'sh7fff :
        song_boost < -19'sd32768 ? 16'sh8000 : song_boost[15:0];

    // RGB and sync change after pixel-clock rising edges. The dedicated DDR
    // output generates the panel's rising edge half a cycle later without
    // routing the pixel clock through a LUT.
    assign lcd_hsync = pixel_internal_reset_n ? hsync_delay[1] : 1'b1;
    assign lcd_vsync = pixel_internal_reset_n ? vsync_delay[1] : 1'b1;
    assign lcd_de    = pixel_internal_reset_n ? de_delay[1] : 1'b0;
    assign lcd_bl    = pixel_internal_reset_n;
    assign lcd_r     = pixel_internal_reset_n ? (visual_overlay ? visual_rgb[17:12] : base_rgb_delay[17:12]) : 6'd0;
    assign lcd_g     = pixel_internal_reset_n ? (visual_overlay ? visual_rgb[11:6] : base_rgb_delay[11:6]) : 6'd0;
    assign lcd_b     = pixel_internal_reset_n ? (visual_overlay ? visual_rgb[5:0] : base_rgb_delay[5:0]) : 6'd0;

    audio_pll u_audio_pll (
        .clkin   (sys_clk),
        .init_clk(sys_clk),
        .clkout0 (audio_clk),
        .lock    (audio_pll_locked)
    );

    lcd_pll u_lcd_pll (
        .clkin   (sys_clk),
        .init_clk(sys_clk),
        .clkout0 (pixel_clk),
        .lock    (lcd_pll_locked)
    );

    ODDR u_lcd_pclk_oddr (
        .Q0 (lcd_pclk),
        .Q1 (lcd_pclk_tristate),
        .D0 (1'b0),
        .D1 (pixel_internal_reset_n),
        .TX (1'b0),
        .CLK(pixel_clk)
    );

    key_debounce #(.CE_ENABLE(HALF_RATE_ENABLE),.COUNTER_WIDTH(16), .STABLE_CYCLES(49152)) u_key0_debounce (.clock_enable(engine_ce),
        .clk    (audio_clk),
        .reset_n(audio_internal_reset_n),
        .key_n  (key0_n),
        .pressed(board_key0)
    );

    key_debounce #(.CE_ENABLE(HALF_RATE_ENABLE),.COUNTER_WIDTH(16), .STABLE_CYCLES(49152)) u_key1_debounce (.clock_enable(engine_ce),
        .clk    (audio_clk),
        .reset_n(audio_internal_reset_n),
        .key_n  (key1_n),
        .pressed(board_key1)
    );

    key_debounce #(.CE_ENABLE(HALF_RATE_ENABLE),.COUNTER_WIDTH(16), .STABLE_CYCLES(49152)) u_key2_debounce (.clock_enable(engine_ce),
        .clk    (audio_clk),
        .reset_n(audio_internal_reset_n),
        .key_n  (key2_n),
        .pressed(board_key2)
    );

    // SOM S2 is externally pulled low and goes high when pressed.
    key_debounce #(.CE_ENABLE(HALF_RATE_ENABLE)) u_setting_key_debounce (.clock_enable(engine_ce),
        .clk    (audio_clk),
        .reset_n(audio_internal_reset_n),
        .key_n  (~setting_key),
        .pressed(board_setting)
    );

    instrument_control #(.CE_ENABLE(HALF_RATE_ENABLE),.ADDITIVE_BANK_ENABLE(ADDITIVE_BANK_ENABLE),
        .STRING_BANK_ENABLE(STRING_BANK_ENABLE),.LEGACY_VOICE_ENABLE(LEGACY_VOICE_ENABLE),
        .KEYBOARD_MODE_ENABLE(KEYBOARD_MODE_ENABLE)) u_instrument_control (.clock_enable(engine_ce),
        .clk           (audio_clk),
        .reset_n       (audio_internal_reset_n),
        .key_pressed   (uploaded_selected ? 3'b000 : {key2_pressed, key1_pressed, key0_pressed}),
        .setting_pressed(setting_key_pressed),
        .remote_song_start(remote_song_start),
        .song_select(song_select), .song_change(song_change),
        .song_accompaniment(song_accompaniment),
        .song_tempo(song_tempo),
        .play_trigger  (key_play_trigger),
        .play_mute     (key_play_mute),
        .setting_mode  (setting_mode),
        .settings_page (settings_page),
        .selected_field(selected_field),
        .play_mode     (play_mode),
        .tone_select   (tone_select),
        .string_mode   (string_mode),
        .keyboard_piano(keyboard_piano),
        .note_select   (note_select),
        .force_value   (force_value),
        .keymap_select (keymap_select),
        .octave_select (octave_select),
        .effect_select (effect_select),
        .effect_strength(effect_strength),
        .glide_select  (glide_select),
        .vibrato_select(vibrato_select),
        .audition_mode (audition_mode),
        .audition_target(audition_target),
        .test_mode     (test_mode),
        .audition_active(audition_active), .song_active(song_active),
        .self_test_active(self_test_active),
        .test_polyphony(test_polyphony),
        .test_concurrent(test_concurrent),
        .status_payload(status_payload_audio)
    );

    status_bundle_cdc #(.SRC_CE_ENABLE(HALF_RATE_ENABLE),.DST_CE_ENABLE(0),
        .WIDTH(DISPLAY_STATUS_WIDTH+12)
    ) u_status_bundle_cdc (.src_clock_enable(engine_ce),.dst_clock_enable(1'b1),
        .src_clk       (audio_clk),
        .src_reset_n   (audio_internal_reset_n),
        .src_payload   ({upload_status_audio,status_payload_cdc_audio}),
        .dst_clk       (pixel_clk),
        .dst_reset_n   (pixel_internal_reset_n),
        .dst_payload   ({upload_status_pixel,status_payload_pixel}),
        .dst_update    (status_payload_update_pixel)
    );

    // Reuse the existing audio -> pixel snapshot; no new audio-domain load.
    wire [11:0] keyboard_light_notes;
    keyboard_light_status #(.LIVE_KEYBOARD(V3_INPUT_ENABLE)) u_keyboard_light_status (
        .clk(pixel_clk), .reset_n(pixel_internal_reset_n),
        .status_payload(status_payload_pixel), .held_notes(keyboard_light_notes)
    );
    ws2812_tx #(.PIXELS_PER_KEY(RGB_PIXELS_PER_KEY),
        .STARTUP_TEST_ENABLE(RGB_STARTUP_TEST_ENABLE)) u_ws2812_tx (
        .clk(pixel_clk), .reset_n(pixel_internal_reset_n),
        .held_notes(keyboard_light_notes),
        .data_out(ws2812_data), .buffer_enable(led_enable)
    );

    expression_audition #(.CE_ENABLE(HALF_RATE_ENABLE)) u_expression_audition (.clock_enable(engine_ce),
        .clk(audio_clk), .reset_n(audio_internal_reset_n),
        .sample_strobe(engine_sample_strobe), .enable(audition_active && !song_active),
        .percussive(audition_target>=2), .trigger(audition_trigger), .force_level(audition_force),
        .wet(audition_wet), .mute(audition_mute), .gates(audition_gates), .note(audition_note)
    );

    generate if(SONG_UPLOAD_ENABLE)begin: shared_link
    localparam integer UPLOAD_PROGRESS_BITS=LARGE_SCORE_ENABLE ? 12 : 8;
    wire [UPLOAD_PROGRESS_BITS-1:0] index_audio_raw,length_audio_raw;
    assign uploaded_index={{(12-UPLOAD_PROGRESS_BITS){1'b0}},index_audio_raw};
    assign uploaded_length={{(12-UPLOAD_PROGRESS_BITS){1'b0}},length_audio_raw};
    instrument_production_link #(.SCORE_BITS(LARGE_SCORE_ENABLE ? 12 : 9),.PROGRESS_BITS(LARGE_SCORE_ENABLE ? 12 : 8),.CE_ENABLE(HALF_RATE_ENABLE),.SCOPE_ENABLE(1),.CLKS_PER_BIT(SHARED_CLKS_PER_BIT)) endpoint (.clock_enable(engine_ce),
        .sys_clk(sys_clk),.audio_clk(audio_clk),.reset_n(audio_async_reset_n),.rx(hc05_rx),.tx(hc05_tx),
        .setting_mode(setting_mode || setting_key_pressed),.stop_key(key1_pressed),
        .song_active(song_active),.song_done(song_done),.song_index(song_note_index),.song_length(song_score_length),
        .play_request(remote_song_start),.stop_request(remote_song_stop),
        .sample_strobe(engine_sample_strobe),.scope_sample_strobe(audio_sample_strobe),
        .scope_dry_sample(pre_effect_audio_sample),.scope_wet_sample(audio_sample),
        .playback_busy(),.published(),.staging(),.link_fault(),.rx_dropped(),
        .event_flush(uploaded_flush),.event_valid(uploaded_valid),.event_on(uploaded_on),.event_melody(uploaded_melody),
        .event_id(uploaded_id),.event_note(uploaded_note),.event_octave(uploaded_octave),.event_force(uploaded_force),
        .event_ready(uploaded_ready),.local_stop(upload_local_stop),
        .upload_selected(uploaded_selected),
        .play_blocked(setting_mode || audition_active || self_test_active || setting_key_pressed || remote_song_start),
        .active_audio(uploaded_run),.state_audio(uploaded_state),.note_index_audio(index_audio_raw),
        .melody_count_audio(length_audio_raw),.tempo_audio(uploaded_tempo));
    end else begin: legacy_link
    assign uploaded_run=0;assign uploaded_state=0;assign uploaded_index=0;
    assign uploaded_length=0;assign uploaded_tempo=0;
    assign uploaded_valid=0;assign uploaded_flush=1;assign uploaded_on=0;assign uploaded_melody=0;
    assign uploaded_id=0;assign uploaded_note=0;assign uploaded_octave=0;assign uploaded_force=0;
    hc05_link #(.CLKS_PER_BIT(HC05_CLKS_PER_BIT)) u_hc05_link (
        .clk(audio_clk),.reset_n(audio_internal_reset_n),.rx(hc05_rx),.tx(hc05_tx),
        .setting_mode(setting_mode || setting_key_pressed),.stop_key(key1_pressed),
        .song_active(song_active),.song_done(song_done),.song_index(song_note_index),
        .song_length(song_score_length),
        .play_request(remote_song_start),.stop_request(remote_song_stop)
    );
    end endgenerate

    song_player #(.CE_ENABLE(HALF_RATE_ENABLE)) u_song_player (.clock_enable(engine_ce),
        .score_index(song_score_index), .score_length(song_select ? ode_length : twinkle_length),
        .score_note(song_score_note), .score_octave(song_score_octave),
        .score_force(song_score_force), .score_duration(song_score_duration),
        .score_gate(song_score_gate),
        .clk(audio_clk), .reset_n(audio_internal_reset_n),
        .sample_strobe(engine_sample_strobe), .enable(song_active && !song_accompaniment),
        .stop_pressed(key1_pressed), .replay_pressed(key2_pressed), .done(solo_done),
        .remote_start(remote_song_start || song_change), .remote_stop(remote_song_stop),
        .note_index(solo_note_index),
        .event_valid(solo_valid), .event_ready(solo_ready),
        .event_flush(solo_flush), .event_on(solo_on),
        .event_id(solo_id), .event_note(solo_note),
        .event_octave(solo_octave), .event_force(solo_force)
    );

    song_timeline_rom #(.CE_ENABLE(HALF_RATE_ENABLE)) u_timeline_rom (.clock_enable(engine_ce),
        .clk(audio_clk), .select(song_select), .index(timeline_rom_index),
        .data(timeline_data), .length(timeline_event_count),
        .end_tick(timeline_end_tick), .melody_count(timeline_length)
    );
    song_timeline #(.CE_ENABLE(HALF_RATE_ENABLE)) u_song_timeline (.clock_enable(engine_ce),
        .clk(audio_clk), .reset_n(audio_internal_reset_n),
        .sample_strobe(engine_sample_strobe), .enable(song_active && song_accompaniment),
        .stop_pressed(key1_pressed), .replay_pressed(key2_pressed),
        .remote_start(remote_song_start || song_change), .remote_stop(remote_song_stop),
        .tempo_select(song_tempo), .score_index(timeline_rom_index),
        .score_data(timeline_data), .score_length(timeline_event_count), .score_end_tick(timeline_end_tick),
        .note_index(timeline_note_index), .done(timeline_done),
        .event_valid(ensemble_valid), .event_ready(ensemble_ready), .event_flush(timeline_flush),
        .event_on(ensemble_on), .event_id(ensemble_id), .event_note(ensemble_note),
        .event_octave(ensemble_octave), .event_force(ensemble_force), .event_melody(ensemble_melody),
        .deadline_fault(ensemble_fault)
    );

    song_score_twinkle u_song_score (
        .index(song_score_index), .length(twinkle_length),
        .note(twinkle_note), .octave(twinkle_octave), .force_level(twinkle_force),
        .duration_ticks(twinkle_duration), .gate_ticks(twinkle_gate)
    );
    song_score_ode u_ode_score (
        .index(song_score_index), .length(ode_length),
        .note(ode_note), .octave(ode_octave), .force_level(ode_force),
        .duration_ticks(ode_duration), .gate_ticks(ode_gate)
    );
    assign song_score_length = song_accompaniment ? timeline_length : (song_select ? ode_length : twinkle_length);
    assign song_score_note = song_select ? ode_note : twinkle_note;
    song_timing #(.CE_ENABLE(HALF_RATE_ENABLE)) u_song_timing (.clock_enable(engine_ce),
        .clk(audio_clk), .tempo_select(song_tempo),
        .duration_ticks(song_select ? ode_duration : twinkle_duration),
        .gate_ticks(song_select ? ode_gate : twinkle_gate),
        .duration_samples(song_score_duration), .gate_samples(song_score_gate)
    );
    assign song_score_octave = song_select ? ode_octave : twinkle_octave;
    assign song_score_force = song_select ? ode_force : twinkle_force;

    // Last-event metadata only: the actual bank owns the multi-key display.
    // Both receivers still accept together, but the observer no longer limits
    // a burst to one event per sample. Song DDS remains muted.
    note_event_voice #(.CE_ENABLE(HALF_RATE_ENABLE),.LIMIT_PER_SAMPLE(0)) u_song_voice (.clock_enable(engine_ce),
        .clk(audio_clk), .reset_n(audio_internal_reset_n),
        .sample_strobe(engine_sample_strobe), .flush(song_event_flush),
        // Metadata observer for the current monophonic score, not a sound source.
        // Both consumers accept exactly once on the same edge.
        .event_valid(song_event_valid && song_receiver_ready), .event_ready(song_display_ready),
        .event_on(song_event_on), .event_id(song_event_id),
        .event_note(song_event_note), .event_octave(song_event_octave),
        .event_force(song_event_force),
        .gate(song_gate), .trigger(song_trigger), .note(song_note),
        .octave(song_octave), .force_level(song_force)
    );

    // Keep manual expression unchanged; FSR is an additional live key source.
    // It never enters instrument_control's menu/song transport button inputs.
    generate if(V3_INPUT_ENABLE && V3_ANALOG_KEYS_ENABLE)begin : v3_analog
        v3_analog_input #(.CE_ENABLE(HALF_RATE_ENABLE)) u_inputs(.clock_enable(engine_ce),
            .sys_clk(sys_clk),.sys_reset_n(sys_internal_reset_n),
            .audio_clk(audio_clk),.audio_reset_n(audio_internal_reset_n),.sample_strobe(engine_sample_strobe),
            .adc_miso(adc_miso),.manual_vibrato(vibrato_select),
            .adc_sclk(adc_sclk),.adc_mosi(adc_mosi),.adc_cs0_n(adc_cs0_n),.adc_cs1_n(adc_cs1_n),
            .keys(v3_keys),.key_forces(v3_key_forces),.force_value(v3_force),.bend(v3_bend),
            .vibrato_depth(v3_vibrato),.pressure_gate(v3_pressure),.ready(v3_ready));
        assign key_load_n=1'b1;assign key_shift_clk=1'b0;
        // Four-level force meter, lit from adc_led[0] upward. The previous
        // assignment mixed two status flags with two thresholds, so a medium
        // press lit three LEDs and the two force bits were not adjacent.
        // force_value is already zero with no key held, and ready/gate are
        // shown on the panel, so the board LEDs are purely a meter.
        // Thresholds divide the 40..127 range the velocity curve produces, so
        // the first LED needs a press past the trigger point rather than
        // lighting on contact.
        assign adc_led=~{v3_force>=7'd106,v3_force>=7'd84,
                         v3_force>=7'd62,v3_force>=7'd41};
        assign fsr_force=v3_force;assign fsr_gate=1'b0;assign fsr_trigger=1'b0;assign fsr_ready=v3_ready;
    end else if(V3_INPUT_ENABLE)begin : v3_input
        v3_performance_input u_inputs(
            .sys_clk(sys_clk),.sys_reset_n(sys_internal_reset_n),
            .audio_clk(audio_clk),.audio_reset_n(audio_internal_reset_n),.sample_strobe(audio_sample_strobe),
            .adc_miso(adc_miso),.key_serial(key_serial),.manual_force(force_value),.manual_vibrato(vibrato_select),
            .adc_sclk(adc_sclk),.adc_mosi(adc_mosi),.adc_cs_n(adc_cs0_n),
            .key_load_n(key_load_n),.key_shift_clk(key_shift_clk),.keys(v3_keys),
            .force_value(v3_force),.bend(v3_bend),.vibrato_depth(v3_vibrato),
            .pressure_gate(v3_pressure),.ready(v3_ready),.calibrated(),.force_zero(),.x_center(),.y_center());
        assign adc_cs1_n=1'b1;
        // Four-level force meter, lit from adc_led[0] upward. The previous
        // assignment mixed two status flags with two thresholds, so a medium
        // press lit three LEDs and the two force bits were not adjacent.
        // force_value is already zero with no key held, and ready/gate are
        // shown on the panel, so the board LEDs are purely a meter.
        // Thresholds divide the 40..127 range the velocity curve produces, so
        // the first LED needs a press past the trigger point rather than
        // lighting on contact.
        assign adc_led=~{v3_force>=7'd106,v3_force>=7'd84,
                         v3_force>=7'd62,v3_force>=7'd41};
        assign fsr_force=v3_force;assign fsr_gate=1'b0;assign fsr_trigger=1'b0;assign fsr_ready=v3_ready;
    end else if(FSR_ENABLE)begin : fsr_input
        fsr_performance_input #(.SAMPLE_PERIOD_CYCLES(FSR_SAMPLE_PERIOD_CYCLES)) u_fsr(
            .sys_clk(sys_clk),.sys_reset_n(sys_internal_reset_n),
            .audio_clk(audio_clk),.audio_reset_n(audio_internal_reset_n),
            .sample_strobe(audio_sample_strobe),
            .live_enable(!setting_mode && !setting_key_pressed && !audition_active && !self_test_active),
            .adc_miso(adc_miso),.adc_sclk(adc_sclk),.adc_mosi(adc_mosi),
            .adc_cs0_n(adc_cs0_n),.adc_cs1_n(adc_cs1_n),.adc_led(adc_led),
            .force_value(fsr_force),.gate(fsr_gate),.trigger(fsr_trigger),.ready(fsr_ready));
    end else begin : no_fsr_input
        assign adc_sclk=1'b0;
        assign adc_mosi=1'b0;
        assign adc_cs0_n=1'b1;
        assign adc_cs1_n=1'b1;
        assign adc_led=4'b1111;
        assign fsr_force=7'd0;
        assign fsr_gate=1'b0;
        assign fsr_trigger=1'b0;
        assign fsr_ready=1'b0;
    end
    if(!V3_INPUT_ENABLE)begin : inactive_v3
        assign key_load_n=1'b1;assign key_shift_clk=1'b0;
        assign v3_keys=16'd0;assign v3_force=7'd0;assign v3_bend=8'sd0;
        assign v3_vibrato=8'd0;assign v3_pressure=1'b0;assign v3_ready=1'b0;
    end endgenerate
    generate if(!V3_ANALOG_KEYS_ENABLE)begin : no_per_key_force
        assign v3_key_forces=84'd0;
    end endgenerate
    wire [6:0] manual_performance_force;
    wire signed [7:0] manual_performance_bend;
    wire [7:0] manual_performance_vibrato;
    assign performance_force=V3_INPUT_ENABLE && v3_pressure ? v3_force : manual_performance_force;
    assign performance_bend=V3_INPUT_ENABLE ? v3_bend : manual_performance_bend;
    assign performance_vibrato=V3_INPUT_ENABLE ? v3_vibrato : manual_performance_vibrato;
    performance_controls #(.CE_ENABLE(HALF_RATE_ENABLE)) u_performance_controls (.clock_enable(engine_ce),
        .clk(audio_clk),.reset_n(audio_internal_reset_n),.sample_strobe(engine_sample_strobe),
        .sensor_enable(1'b0),.frame_valid(1'b0),.force_raw(10'd0),.x_raw(10'd512),.y_raw(10'd512),
        .force_zero(10'd0),.x_center(10'd512),.y_center(10'd512),.force_gain_q12(12'd508),
        .manual_force(force_value),.manual_vibrato(vibrato_select),
        .force_value(manual_performance_force),.bend(manual_performance_bend),.vibrato_depth(manual_performance_vibrato),
        .pressure_gate(),.pressure_trigger(),.sensor_ready()
    );

    generate if(LEGACY_VOICE_ENABLE) begin: legacy_voice
    audio_voice_mixer #(.CE_ENABLE(HALF_RATE_ENABLE)) u_audio_voice_mixer (.clock_enable(engine_ce),
        .clk           (audio_clk),
        .reset_n       (audio_internal_reset_n),
        .sample_strobe (dds_sample_strobe),
        .voice_trigger (dds_trigger),
        .voice_gate    (dds_gate),
        .mute          (dds_mute),
        .song_release  (dds_song_release),
        .play_mode     (dds_play_mode),
        .tone_select   (dds_tone),
        .note_select   (dds_note),
        .keymap_select (dds_keymap),
        .octave_select (dds_octave),
        .force_value   (dds_force),
        .bend          (dds_bend),
        .glide_select  (dds_glide),
        .vibrato_depth (dds_vibrato),
        .sample        (raw_audio_sample)
    );
    end else begin: no_legacy_voice
        assign raw_audio_sample=16'sd0;
    end endgenerate

    concurrent_test_source #(.CE_ENABLE(HALF_RATE_ENABLE)) u_concurrent_test_source (.clock_enable(engine_ce),
        .clk(audio_clk), .reset_n(audio_internal_reset_n),
        .sample_strobe(engine_sample_strobe), .enable(concurrent_active),
        .event_ready(song_bank_ready), .event_valid(concurrent_event_valid),
        .event_on(), .event_id(concurrent_event_id),
        .event_note(concurrent_event_note), .event_octave(concurrent_event_octave),
        .event_force(concurrent_event_force), .poly_notes_issued(),
        .string_trigger(concurrent_string_trigger),
        .string_note(concurrent_string_note), .string_octave(concurrent_string_octave)
    );
    // Unity-gain sum of the three engines, widened then saturated. Saturation
    // is a guard, not part of the sound. Registered so the output selection
    // gains one data input rather than an adder.
    wire signed [17:0] concurrent_sum =
        $signed({{2{polyphony_test_sample[15]}}, polyphony_test_sample}) +
        $signed({{2{string_sample[15]}}, string_sample}) +
        $signed({{2{additive_test_sample[15]}}, additive_test_sample});
    always @(posedge audio_clk or negedge audio_internal_reset_n) begin
        if (!audio_internal_reset_n) concurrent_mix <= 16'sd0;
        else if (engine_ce) concurrent_mix <= concurrent_sum > 18'sd32767 ? 16'sh7fff :
            concurrent_sum < -18'sd32768 ? 16'sh8000 : concurrent_sum[15:0];
    end

    generate if(STRING_BANK_ENABLE) begin: strings_enabled
    physical_string_bank #(.CE_ENABLE(HALF_RATE_ENABLE),.EVENT_SUPPORT(V3_INPUT_ENABLE)) u_physical_string_bank (.clock_enable(engine_ce),
        .clk(audio_clk), .reset_n(audio_internal_reset_n),
        .event_mode(string_event_mode),.event_flush(1'b0),
        .event_valid(v3_valid && keyboard_enable),.event_ready(string_event_ready),
        .event_on(v3_on),.event_id(v3_id),.event_note_in(v3_note),
        .event_octave_in(v3_octave),.event_force_in(v3_velocity),
        .sample_strobe(engine_sample_strobe),
        .enable((concurrent_active && ADDITIVE_BANK_ENABLE) || (string_path_active && !key_play_mute && !(audition_active && audition_mute))),
        .voice_trigger(concurrent_active ? concurrent_string_trigger : routed_voice_trigger),
        .voice_gate(concurrent_active ? 3'b000 : routed_voice_gate),
        .play_mode(concurrent_active || routed_play_mode),
        .keymap_select(!concurrent_active && routed_keymap),
        .note_select(concurrent_active ? concurrent_string_note : routed_note),
        .octave_select(concurrent_active ? concurrent_string_octave : routed_octave),
        .force_value(concurrent_active ? 7'd96 : routed_string_force), .sample(string_sample),
        // Neutral expression during the self-test: the captured spectrum must
        // show fixed fundamentals, not a bent or vibrato-swept pitch.
        .bend(concurrent_active ? 8'sd0 : (audition_active ? 8'sd0 : performance_bend)),
        .vibrato_depth(concurrent_active ? 8'd0 : (audition_active ? 8'd0 : performance_vibrato)),
        .active_voices(string_active_voices), .active_voice_count(string_voice_count),
        .deadline_miss_count(string_deadline_misses)
    );
    end else begin: strings_disabled
        assign string_event_ready=1'b0;
        assign string_sample=16'sd0;
        assign string_active_voices=8'd0;
        assign string_voice_count=4'd0;
        assign string_deadline_misses=8'd0;
    end endgenerate

    generate if(ADDITIVE_BANK_ENABLE) begin: additive_enabled
    additive_bank_32 #(.CE_ENABLE(HALF_RATE_ENABLE)) u_additive_bank_32 (.clock_enable(engine_ce),
        .clk                (audio_clk),
        .reset_n            (audio_internal_reset_n),
        .sample_strobe      (engine_sample_strobe),
        .enable             (self_test_active && (!test_polyphony || test_concurrent)),
        .sample             (additive_test_sample),
        .all_partials_active(additive_all_partials_active)
    );
    end else begin: additive_disabled
        assign additive_test_sample=16'sd0;
        assign additive_all_partials_active=1'b0;
    end endgenerate

    // Reuse the same physical lanes for manual polyphony and score events.
    // The two owners are exclusive; the bank clears on an owner transition.
    // Register the entire sample/control bundle to break the menu -> owner ->
    // 32 envelope lanes path. Manual events and the sample edge move together.
    // Score payload is NOT blindly delayed: it remains stable until the live
    // ready/valid handshake. The display receiver blocks acceptance immediately
    // on a flush, while this registered flush cancels the bank one clock later.
    reg poly_sample_strobe, poly_event_flush;
    // Stage-19 routing found 522 data loads on the common bank enable.
    reg poly_enable /* synthesis syn_maxfan = 8 */;
    reg poly_play_mode, poly_keymap;
    reg [2:0] poly_trigger;
    // Stage-18 route report: this data net drove 39 loads with an 8.281 ns
    // segment into release logic. SUG550 5.11 permits local driver replication;
    // bound this data fanout without adding a cycle or constraining clocks.
    reg [2:0] poly_gate /* synthesis syn_maxfan = 8 */;
    reg [1:0] poly_tone, poly_octave;
    // Routed stage-20 mode bits reached 67 loads before the pitch select.
    reg [1:0] poly_glide /* synthesis syn_maxfan = 8 */;
    reg [3:0] poly_note;
    reg [6:0] poly_force;
    reg signed [7:0] poly_bend;
    reg [7:0] poly_vibrato /* synthesis syn_maxfan = 8 */;
    reg poly_wide_octave;
    always @(posedge audio_clk or negedge audio_internal_reset_n) begin
        if (!audio_internal_reset_n) begin
            poly_sample_strobe<=0; poly_enable<=0; poly_event_mode<=0; poly_event_flush<=1;poly_live<=0;
            poly_play_mode<=0; poly_keymap<=0; poly_trigger<=0; poly_gate<=0;
            poly_tone<=0; poly_octave<=0; poly_note<=0; poly_force<=0;
            poly_bend<=0; poly_vibrato<=0; poly_glide<=0; poly_wide_octave<=0;
        end else if (engine_ce) begin
            poly_sample_strobe<=engine_sample_strobe;
            poly_enable<=(self_test_active && test_polyphony) || score_active || v3_live || bank_audition;
            poly_live<=v3_live;
            // The concurrent self-test drives the bank through the same event
            // bus a score uses, so the 32 voices are real allocations.
            poly_event_mode<=score_active || concurrent_active || v3_live;
            poly_wide_octave<=concurrent_active;
            poly_event_flush<= (poly_live != v3_live) ||
                (!v3_live && !concurrent_active && (song_event_flush || (!uploaded_selected && ensemble_fault)));
            poly_play_mode<=bank_audition ? routed_play_mode : play_mode;
            poly_keymap<=bank_audition ? routed_keymap : keymap_select;
            poly_trigger<=bank_audition ? routed_voice_trigger : key_play_trigger;
            poly_gate<=bank_audition ? routed_voice_gate : {key2_pressed,key1_pressed,key0_pressed};
            // Tone 0 (triangle) during the self-test: a fixed, analysable
            // spectrum per voice instead of whatever the menu last selected.
            poly_tone<=score_active ? 2'd3 : concurrent_active ? 2'd0 : bank_audition ? routed_tone :
                (KEYBOARD_MODE_ENABLE && keyboard_piano && v3_live) ? 2'd3 : tone_select;
            poly_octave<=bank_audition ? routed_octave : octave_select;
            poly_note<=bank_audition ? routed_note : note_select;
            poly_force<=bank_audition ? routed_force : performance_force;
            poly_bend<=bank_audition ? routed_bend : performance_bend;
            poly_vibrato<=bank_audition ? routed_vibrato : performance_vibrato;
            poly_glide<=bank_audition ? routed_glide : glide_select;
        end
    end
    polyphony_bank_32 #(.CE_ENABLE(HALF_RATE_ENABLE),.LIVE_EVENT_SUPPORT(V3_INPUT_ENABLE),
        .SCORE_ENVELOPE_ENABLE(SCORE_PLAYBACK_ENABLE),
        .PER_KEY_FORCE_SUPPORT(V3_ANALOG_KEYS_ENABLE),
        .KEYBOARD_SCALE_SUPPORT(KEYBOARD_MODE_ENABLE),
        .SHARED_KEY_FORCE(V3_ANALOG_KEYS_ENABLE),
        .SHARED_PITCH(V3_ANALOG_KEYS_ENABLE),
        .SHARED_PITCH_LANES(16),
        .SUSTAIN_COMPARE_PIPELINE(1)) u_polyphony_bank_32 (.clock_enable(engine_ce),
        .clk               (audio_clk),
        .reset_n           (audio_internal_reset_n),
        .sample_strobe     (poly_sample_strobe),
        .enable            (poly_enable),
        .event_mode        (poly_event_mode),
        .live_event_enable (poly_live),
        .keyboard_piano   (keyboard_piano),
        .event_flush       (poly_event_flush),
        .event_valid       ((poly_live==v3_live) && (v3_live ? (v3_valid && poly_live) : uploaded_selected ? (uploaded_valid && (!uploaded_melody || song_display_ready)) : concurrent_active ? concurrent_event_valid : song_accompaniment ? (ensemble_valid && (!ensemble_melody || song_display_ready)) : (song_event_valid && song_display_ready))),
        .event_ready       (poly_bank_ready),
        .event_on          (v3_live ? v3_on : uploaded_selected ? uploaded_on : concurrent_active || (song_accompaniment ? ensemble_on : song_event_on)),
        .event_id          (v3_live ? v3_id : uploaded_selected ? uploaded_id : concurrent_active ? concurrent_event_id : song_accompaniment ? ensemble_id : song_event_id),
        .event_note        (v3_live ? v3_note : uploaded_selected ? uploaded_note : concurrent_active ? concurrent_event_note : song_accompaniment ? ensemble_note : song_event_note),
        .event_octave      (v3_live ? v3_octave : uploaded_selected ? uploaded_octave : concurrent_active ? concurrent_event_octave : song_accompaniment ? ensemble_octave : song_event_octave),
        .wide_event_octave (poly_wide_octave),
        .event_force       (v3_live ? v3_velocity : uploaded_selected ? uploaded_force : concurrent_active ? concurrent_event_force : song_accompaniment ? ensemble_force : song_event_force),
        .voice_trigger     (poly_trigger),
        .voice_gate        (poly_gate),
        .play_mode         (poly_play_mode),
        .tone_select       (poly_tone),
        .note_select       (poly_note),
        .keymap_select     (poly_keymap),
        .octave_select     (poly_octave),
        .force_value       (poly_force),
        .key_forces        (v3_key_forces),
        .bend              (poly_bend),
        .glide_select      (poly_glide),
        .vibrato_depth     (poly_vibrato),
        .sample            (polyphony_test_sample),
        .active_voice_count(polyphony_active_voice_count),
        .held_note_mask     (song_held_notes),
        .all_voices_active (polyphony_all_voices_active)
    );

    audio_effects #(.CE_ENABLE(HALF_RATE_ENABLE)) u_audio_effects (.clock_enable(engine_ce),
        .clk           (audio_clk),
        .reset_n       (audio_internal_reset_n),
        .sample_strobe (engine_sample_strobe),
        .effect_select (active_effect_select),
        .effect_strength(effect_strength),
        .mute          (routed_audio_mute),
        .sample_in     (effects_input),
        .sample_out    (audio_sample)
    );

    pt8211_tx u_pt8211_tx (
        .audio_clk    (audio_clk),
        .reset_n      (audio_internal_reset_n),
        .sample_in    (audio_sample),
        .sample_strobe(audio_sample_strobe),
        .audio_bck    (audio_bck),
        .audio_ws     (audio_ws),
        .audio_din    (audio_din),
        .stream_ready (audio_stream_ready)
    );

    audio_sample_cdc #(.SRC_CE_ENABLE(HALF_RATE_ENABLE),.DST_CE_ENABLE(0),.WIDTH(32)) u_audio_sample_cdc (.src_clock_enable(engine_ce),.dst_clock_enable(1'b1),
        .src_clk          (audio_clk),
        .src_reset_n      (audio_internal_reset_n),
        .src_sample       ({pre_effect_audio_sample,audio_sample}),
        .src_sample_strobe(engine_sample_strobe),
        .dst_clk          (pixel_clk),
        .dst_reset_n      (pixel_internal_reset_n),
        .dst_sample       (pixel_audio_pair),
        .dst_sample_valid (pixel_audio_sample_valid)
    );

    lcd_timing_800x480 u_lcd_timing (
        .pixel_clk  (pixel_clk),
        .reset_n    (pixel_internal_reset_n),
        .hsync      (lcd_hsync_timing),
        .vsync      (lcd_vsync_timing),
        .data_enable(lcd_de_timing),
        .frame_start(lcd_frame_start),
        .active_x   (lcd_active_x),
        .active_y   (lcd_active_y)
    );

    lcd_test_pattern #(.COMPACT_SCOPE(1),.UPLOAD_UI(SONG_UPLOAD_ENABLE),.LIVE_KEYBOARD(V3_INPUT_ENABLE),
        .ADDITIVE_BANK_ENABLE(ADDITIVE_BANK_ENABLE),.STRING_BANK_ENABLE(STRING_BANK_ENABLE),
        .KEYBOARD_MODE_ENABLE(KEYBOARD_MODE_ENABLE)) u_lcd_test_pattern (
        .upload_status(upload_status_pixel),
        .pixel_clk         (pixel_clk),
        .reset_n           (pixel_internal_reset_n),
        .active_x          (lcd_active_x),
        .active_y          (lcd_active_y),
        .data_enable       (lcd_de_timing),
        .hsync_in          (lcd_hsync_timing),
        .vsync_in          (lcd_vsync_timing),
        .hsync_out         (lcd_hsync_internal),
        .vsync_out         (lcd_vsync_internal),
        .de_out            (lcd_de_internal),
        .frame_start       (lcd_frame_start),
        .audio_sample      (pixel_audio_sample),
        .audio_sample_valid(pixel_audio_sample_valid),
        .status_payload    (status_payload_pixel),
        .status_update     (status_payload_update_pixel),
        .red               (lcd_r_internal),
        .green             (lcd_g_internal),
        .blue              (lcd_b_internal)
    );

    // Visual analysis is a side branch. It never stalls the audio sample clock.
    spectrum_analyzer #(.FRAME_GAP_SAMPLES(12'd1024)) u_spectrum (
        .clk(audio_clk),.reset_n(audio_internal_reset_n),
        .sample_strobe(audio_sample_strobe),.sample_in(audio_sample),
        .levels(spectrum_audio),.frame_valid(spectrum_frame_valid),
        .deadline_misses(spectrum_deadline_misses)
    );
    audio_sample_cdc #(.SRC_CE_ENABLE(0),.DST_CE_ENABLE(0),.WIDTH(1024)) u_spectrum_cdc (.src_clock_enable(1'b1),.dst_clock_enable(1'b1),
        .src_clk(audio_clk),.src_reset_n(audio_internal_reset_n),.src_sample(spectrum_audio),
        .src_sample_strobe(spectrum_frame_valid),
        .dst_clk(pixel_clk),.dst_reset_n(pixel_internal_reset_n),
        .dst_sample(spectrum_pixel),.dst_sample_valid(spectrum_update_pixel)
    );
    visual_feedback u_visual_feedback (
        .clk(pixel_clk),.reset_n(pixel_internal_reset_n),.frame_start(lcd_frame_start),
        .enable(!status_payload_pixel[ST_SETTING]),.x(lcd_active_x),.y(lcd_active_y),
        .spectrum(spectrum_pixel),.spectrum_update(spectrum_update_pixel),
        .audio_pair(pixel_audio_pair),.audio_pair_valid(pixel_audio_sample_valid),
        .overlay(visual_overlay),.rgb(visual_rgb)
    );
    // Legacy renderer already has one pixel of latency; new panels have two.
    always @(posedge pixel_clk or negedge pixel_internal_reset_n) begin
        if(!pixel_internal_reset_n)begin
            base_rgb_delay<=0;hsync_delay<=2'b11;vsync_delay<=2'b11;de_delay<=0;
        end else begin
            base_rgb_delay<={lcd_r_internal,lcd_g_internal,lcd_b_internal};
            hsync_delay<={hsync_delay[0],lcd_hsync_timing};
            vsync_delay<={vsync_delay[0],lcd_vsync_timing};
            de_delay<={de_delay[0],lcd_de_timing};
        end
    end

    // Asynchronous assertion gives an immediate safe state; release is
    // synchronized separately in each clock domain.
    always @(posedge sys_clk or negedge sys_async_reset_n) begin
        if (!sys_async_reset_n)
            sys_reset_sync_n <= 2'b00;
        else
            sys_reset_sync_n <= {sys_reset_sync_n[0], 1'b1};
    end

    always @(posedge audio_clk or negedge audio_async_reset_n) begin
        if (!audio_async_reset_n)
            audio_reset_sync_n <= 2'b00;
        else
            audio_reset_sync_n <= {audio_reset_sync_n[0], 1'b1};
    end

    always @(posedge pixel_clk or negedge pixel_async_reset_n) begin
        if (!pixel_async_reset_n)
            pixel_reset_sync_n <= 2'b00;
        else
            pixel_reset_sync_n <= {pixel_reset_sync_n[0], 1'b1};
    end

    always @(posedge sys_clk or negedge sys_internal_reset_n) begin
        if (!sys_internal_reset_n) begin
            audio_lock_sys_sync <= 2'b00;
            pixel_lock_sys_sync <= 2'b00;
            heartbeat_counter   <= 25'd0;
            heartbeat_led_on    <= 1'b0;
        end else begin
            audio_lock_sys_sync <= {audio_lock_sys_sync[0], audio_pll_locked};
            pixel_lock_sys_sync <= {pixel_lock_sys_sync[0], lcd_pll_locked};

            if (heartbeat_counter == HEARTBEAT_HALF_PERIOD_CYCLES - 25'd1) begin
                heartbeat_counter <= 25'd0;
                heartbeat_led_on  <= ~heartbeat_led_on;
            end else begin
                heartbeat_counter <= heartbeat_counter + 25'd1;
            end
        end
    end

endmodule

`default_nettype wire
