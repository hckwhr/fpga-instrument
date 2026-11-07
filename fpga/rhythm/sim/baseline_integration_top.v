`default_nettype none

// Frozen effects_expression_20261002 routing, simulation only.
module baseline_integration_top (
    input  wire       sys_clk,
    input  wire       key0_n,
    input  wire       key1_n,
    input  wire       key2_n,
    input  wire       setting_key,
    output wire       status_led,
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
    wire pixel_clk;
    wire lcd_pll_locked;
    wire pixel_async_reset_n;
    wire pixel_internal_reset_n;
    wire key0_pressed;
    wire key1_pressed;
    wire key2_pressed;
    wire setting_key_pressed;
    wire [2:0] key_play_trigger;
    wire       key_play_mute;
    wire       setting_mode;
    wire       settings_page;
    wire [2:0] selected_field;
    wire       play_mode;
    wire [1:0] tone_select;
    wire string_mode;
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
    wire audition_mode, audition_active, audition_wet, audition_mute;
    wire [2:0] audition_gates;
    wire [3:0] audition_note;
    wire [2:0] audition_target, audition_trigger;
    wire [6:0] audition_force;
    wire [6:0] audition_play_force = (audition_target==5 && audition_wet)?audition_force:7'd96;
    wire [1:0] audition_tone = (audition_target>=2)?2'd3:2'd0;
    wire [6:0] performance_force;
    wire signed [7:0] performance_bend;
    wire [7:0] performance_vibrato;
    wire audition_effects = audition_target>=2 && audition_target<=4;
    wire audition_strings = audition_active && audition_target==6 && audition_wet;
    wire [1:0] audition_effect = audition_target==2?2'd1:audition_target==3?2'd2:2'd3;
    wire signed [15:0] effects_input;
    wire [27:0] displayed_status_payload;
    wire       test_mode;
    wire       test_polyphony;
    wire       self_test_active;
    wire [1:0] active_effect_select;
    wire [27:0] status_payload_audio;
    wire [55:0] status_payload_cdc_audio;
    wire [55:0] status_payload_pixel;
    wire        status_payload_update_pixel;
    wire signed [15:0] raw_audio_sample;
    wire signed [15:0] additive_test_sample;
    wire signed [15:0] polyphony_test_sample;
    wire signed [15:0] pre_effect_audio_sample;
    wire signed [15:0] dry_half=pre_effect_audio_sample/16'sd2;
    wire signed [15:0] dry_quarter=pre_effect_audio_sample/16'sd4;
    wire signed [15:0] audition_dry=(effect_strength==0)?dry_half+dry_quarter:
        (effect_strength==1)?dry_half:dry_quarter;
    assign effects_input = audition_active && audition_effects && !audition_wet
        ? audition_dry:pre_effect_audio_sample;
    wire signed [15:0] audio_sample;
    wire additive_all_partials_active;
    wire [5:0] polyphony_active_voice_count;
    wire polyphony_all_voices_active;
    wire audio_sample_strobe;
    wire audio_stream_ready;
    wire signed [15:0] pixel_audio_sample;
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
    assign self_test_active = test_mode && !setting_mode;
    assign displayed_voice_count = ((string_mode || audition_strings) && !self_test_active)
        ? {2'd0,string_voice_count} : polyphony_active_voice_count;
    assign audition_active = audition_mode && !setting_mode && !test_mode;
    assign displayed_status_payload = audition_active
        ? {2'b00,active_effect_select,1'b0,selected_field,1'b0,audition_tone,audition_note,audition_play_force,1'b0,2'd1,audition_gates}
        : status_payload_audio;
    assign status_payload_cdc_audio = {effect_strength,audition_target,audition_wet,audition_active,audition_mode,
        vibrato_select, glide_select, string_deadline_misses, settings_page, (string_mode || audition_strings),
        displayed_voice_count, displayed_status_payload};
    assign active_effect_select = self_test_active ? 2'd0 : audition_active
        ? ((audition_effects && audition_wet)?audition_effect:2'd0):effect_select;
    assign pre_effect_audio_sample = self_test_active
                                   ? (test_polyphony
                                      ? polyphony_test_sample
                                      : additive_test_sample)
                                   : ((string_mode || audition_strings) ? string_sample : raw_audio_sample);

    // RGB and sync change after pixel-clock rising edges. The dedicated DDR
    // output generates the panel's rising edge half a cycle later without
    // routing the pixel clock through a LUT.
    assign lcd_hsync = pixel_internal_reset_n ? lcd_hsync_internal : 1'b1;
    assign lcd_vsync = pixel_internal_reset_n ? lcd_vsync_internal : 1'b1;
    assign lcd_de    = pixel_internal_reset_n ? lcd_de_internal : 1'b0;
    assign lcd_bl    = pixel_internal_reset_n;
    assign lcd_r     = pixel_internal_reset_n ? lcd_r_internal : 6'd0;
    assign lcd_g     = pixel_internal_reset_n ? lcd_g_internal : 6'd0;
    assign lcd_b     = pixel_internal_reset_n ? lcd_b_internal : 6'd0;

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

    key_debounce u_key0_debounce (
        .clk    (audio_clk),
        .reset_n(audio_internal_reset_n),
        .key_n  (key0_n),
        .pressed(key0_pressed)
    );

    key_debounce u_key1_debounce (
        .clk    (audio_clk),
        .reset_n(audio_internal_reset_n),
        .key_n  (key1_n),
        .pressed(key1_pressed)
    );

    key_debounce u_key2_debounce (
        .clk    (audio_clk),
        .reset_n(audio_internal_reset_n),
        .key_n  (key2_n),
        .pressed(key2_pressed)
    );

    // SOM S2 is externally pulled low and goes high when pressed.
    key_debounce u_setting_key_debounce (
        .clk    (audio_clk),
        .reset_n(audio_internal_reset_n),
        .key_n  (~setting_key),
        .pressed(setting_key_pressed)
    );

    instrument_control u_instrument_control (
        .clk           (audio_clk),
        .reset_n       (audio_internal_reset_n),
        .key_pressed   ({key2_pressed, key1_pressed, key0_pressed}),
        .setting_pressed(setting_key_pressed),
        .remote_song_start(1'b0), .song_select(), .song_change(), .song_tempo(), .song_accompaniment(),
        .play_trigger  (key_play_trigger),
        .play_mute     (key_play_mute),
        .setting_mode  (setting_mode),
        .settings_page (settings_page),
        .selected_field(selected_field),
        .play_mode     (play_mode),
        .tone_select   (tone_select),
        .string_mode   (string_mode),
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
        .test_polyphony(test_polyphony),
        .status_payload(status_payload_audio)
    );

    status_bundle_cdc #(
        .WIDTH(56)
    ) u_status_bundle_cdc (
        .src_clk       (audio_clk),
        .src_reset_n   (audio_internal_reset_n),
        .src_payload   (status_payload_cdc_audio),
        .dst_clk       (pixel_clk),
        .dst_reset_n   (pixel_internal_reset_n),
        .dst_payload   (status_payload_pixel),
        .dst_update    (status_payload_update_pixel)
    );

    expression_audition u_expression_audition (
        .clk(audio_clk), .reset_n(audio_internal_reset_n),
        .sample_strobe(audio_sample_strobe), .enable(audition_active),
        .percussive(audition_target>=2), .trigger(audition_trigger), .force_level(audition_force),
        .wet(audition_wet), .mute(audition_mute), .gates(audition_gates), .note(audition_note)
    );

    // Current board uses manual controls. V2 needs the verified ADC scanner/CDC,
    // calibration and pressure-event routing at this boundary.
    performance_controls u_performance_controls (
        .clk(audio_clk),.reset_n(audio_internal_reset_n),.sample_strobe(audio_sample_strobe),
        .sensor_enable(1'b0),.frame_valid(1'b0),.force_raw(10'd0),.x_raw(10'd512),.y_raw(10'd512),
        .force_zero(10'd0),.x_center(10'd512),.y_center(10'd512),.force_gain_q12(12'd508),
        .manual_force(force_value),.manual_vibrato(vibrato_select),
        .force_value(performance_force),.bend(performance_bend),.vibrato_depth(performance_vibrato),
        .pressure_gate(),.pressure_trigger(),.sensor_ready()
    );

    audio_voice_mixer u_audio_voice_mixer (.song_release(1'b0),
        .clk           (audio_clk),
        .reset_n       (audio_internal_reset_n),
        .sample_strobe (audio_sample_strobe),
        .voice_trigger (audition_active ? audition_trigger : key_play_trigger),
        .voice_gate    (audition_active ? audition_gates : {key2_pressed, key1_pressed, key0_pressed}),
        .mute          (key_play_mute || string_mode || (audition_active && audition_mute)),
        .play_mode     (audition_active ? 1'b0 : play_mode),
        .tone_select   (audition_active ? audition_tone : tone_select),
        .note_select   (audition_active ? audition_note : note_select),
        .keymap_select (audition_active ? 1'b0 : keymap_select),
        .octave_select (audition_active ? 2'd1 : octave_select),
        .force_value   (audition_active ? audition_play_force : performance_force),
        .bend          (audition_active ? 8'sd0 : performance_bend),
        .glide_select  (audition_active ? ((audition_wet && audition_target==0)?2'd3:2'd0) : glide_select),
        .vibrato_depth (audition_active ? (audition_wet && audition_target==1 ? 8'd128:8'd0) : performance_vibrato),
        .sample        (raw_audio_sample)
    );

    physical_string_bank u_physical_string_bank (
        .clk(audio_clk), .reset_n(audio_internal_reset_n),
        .sample_strobe(audio_sample_strobe), .enable((string_mode || audition_strings) && !key_play_mute && !(audition_active && audition_mute)),
        .voice_trigger(audition_active?audition_trigger:key_play_trigger),
        .voice_gate(audition_active?audition_gates:{key2_pressed,key1_pressed,key0_pressed}),
        .play_mode(audition_active?1'b0:play_mode), .keymap_select(audition_active?1'b0:keymap_select),
        .note_select(audition_active?audition_note:note_select), .octave_select(audition_active?2'd1:octave_select),
        .force_value(audition_active?7'd96:performance_force), .sample(string_sample),
        .bend(8'sd0), .vibrato_depth(8'd0),
        .active_voices(string_active_voices), .active_voice_count(string_voice_count),
        .deadline_miss_count(string_deadline_misses)
    );

    additive_bank_32 u_additive_bank_32 (
        .clk                (audio_clk),
        .reset_n            (audio_internal_reset_n),
        .sample_strobe      (audio_sample_strobe),
        .enable             (self_test_active && !test_polyphony),
        .sample             (additive_test_sample),
        .all_partials_active(additive_all_partials_active)
    );

    polyphony_bank_32 u_polyphony_bank_32 (
        .bend(8'sd0),.vibrato_depth(8'd0),.glide_select(2'd0),
        .event_mode(1'b0),.event_flush(1'b0),.event_valid(1'b0),.event_on(1'b0),
        .event_id(16'd0),.event_note(4'd0),.event_octave(2'd0),.event_force(7'd0),.event_ready(),
        .clk               (audio_clk),
        .reset_n           (audio_internal_reset_n),
        .sample_strobe     (audio_sample_strobe),
        .enable            (self_test_active && test_polyphony),
        .voice_trigger     (key_play_trigger),
        .voice_gate        ({key2_pressed, key1_pressed, key0_pressed}),
        .play_mode         (play_mode),
        .tone_select       (tone_select),
        .note_select       (note_select),
        .keymap_select     (keymap_select),
        .octave_select     (octave_select),
        .force_value       (performance_force),
        .sample            (polyphony_test_sample),
        .active_voice_count(polyphony_active_voice_count),
        .held_note_mask(), .all_voices_active (polyphony_all_voices_active)
    );

    audio_effects u_audio_effects (
        .clk           (audio_clk),
        .reset_n       (audio_internal_reset_n),
        .sample_strobe (audio_sample_strobe),
        .effect_select (active_effect_select),
        .effect_strength(effect_strength),
        .mute          (setting_mode || (audition_active && audition_mute)),
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

    audio_sample_cdc u_audio_sample_cdc (
        .src_clk          (audio_clk),
        .src_reset_n      (audio_internal_reset_n),
        .src_sample       (audio_sample),
        .src_sample_strobe(audio_sample_strobe),
        .dst_clk          (pixel_clk),
        .dst_reset_n      (pixel_internal_reset_n),
        .dst_sample       (pixel_audio_sample),
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

    lcd_test_pattern u_lcd_test_pattern (
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
        .status_payload    ({12'd0,status_payload_pixel}),
        .status_update     (status_payload_update_pixel),
        .red               (lcd_r_internal),
        .green             (lcd_g_internal),
        .blue              (lcd_b_internal)
    );

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
