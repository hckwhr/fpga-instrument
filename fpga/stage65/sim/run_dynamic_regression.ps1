param(
    [string]$ModelSimBin = 'E:/modelsim/win64',
    [string[]]$Benches = @(
        'tb_instrumental_envelope', 'tb_instrumental_upload_pcm',
        'tb_uart_high_baud', 'tb_scope_115200', 'tb_song_capacity4096', 'tb_song_progress4096', 'tb_audio_scope_uart', 'tb_scope_production_uart',
        'tb_keyboard_modes_menu', 'tb_keyboard_modes_pitch', 'tb_keyboard_modes_pins',
        'tb_playability_menu_lcd', 'tb_v3_playability_pins',
        'tb_menu_delay_contract', 'tb_string_keyboard_events', 'tb_v3_string_pins', 'tb_string_menu',
        'tb_half_rate_pitch', 'tb_half_rate_force', 'tb_half_rate_datapaths',
        'tb_song_reply_exact', 'tb_poly_force_shared', 'tb_poly_pitch_shared', 'tb_poly_pitch_fast_strobe',
        'tb_poly_pitch_half_shared', 'tb_poly_pitch_half_fast_strobe',
        'tb_poly_stage54_exact', 'tb_v3_analog_input', 'tb_v3_hardware_top', 'tb_v3_key_force',
        'tb_v3_production_latency',
        'tb_keypad_165', 'tb_mcp3008_scanner', 'tb_v3_performance_input', 'tb_keyboard_note_events', 'tb_v3_production_top',
        'tb_uart_byte_cdc', 'tb_song_local_control', 'tb_song_production_top', 'tb_production_legacy_cdc',
        'tb_uart_line_router', 'tb_uart_line_tx_mux', 'tb_instrument_shared_uart', 'tb_shared_uart_pcm',
        'tb_song_control_uart', 'tb_song_control_pcm',
        'tb_song_uploaded_player', 'tb_song_uploaded_player_slow', 'tb_song_upload_pcm',
        'tb_song_upload_store', 'tb_song_upload_timeline', 'tb_song_upload_frame_rx',
        'tb_song_upload_link', 'tb_song_upload_uart',
        'tb_fsr_instrument',
        'tb_fsr_production_latency',
        'tb_i2c_register', 'tb_gt911_touch', 'tb_gt911_reset', 'tb_touch_preview',
        'tb_ws2812_12_chain', 'tb_ws2812_12_startup',
        'tb_ws2812_timing', 'tb_ws2812_chain', 'tb_keyboard_light_status',
        'tb_concurrent_entry', 'tb_concurrent_engines', 'tb_concurrent_top',
        'tb_string_decay', 'tb_visual_freshness', 'tb_spectrum_stop', 'tb_effect_transition_top', 'tb_effect_transition', 'tb_string_route_exact', 'tb_string_expression', 'tb_string_expression_top', 'tb_string_load', 'tb_string_load_top',
        'tb_poly_glide', 'tb_poly_glide_top', 'tb_poly_expression', 'tb_poly_expression_top', 'tb_expression_slew', 'tb_allocator_exact', 'tb_poly_force', 'tb_poly_force_top', 'tb_poly_adsr',
        'tb_song_timeline', 'tb_song_timeline_capacity', 'tb_song_ensemble',
        'tb_piano_lookup_exact', 'tb_pitch_arithmetic_exact', 'tb_poly_mix_pipeline', 'tb_poly_mix_fast_strobe',
        'tb_song_poly_display', 'tb_poly_control_pipeline', 'tb_polyphony_events', 'tb_song_event_path', 'tb_mixer_pipeline', 'tb_hc05_link', 'tb_hc05_top',
        'tb_note_event_voice', 'tb_song_score_rom', 'tb_song_player_data', 'tb_song_player', 'tb_song_top', 'tb_song_select', 'tb_song_lcd', 'tb_song_transport', 'tb_song_tempo', 'tb_dds_control_pipeline',
        'tb_spectrum', 'tb_spectrum_gap', 'tb_visual_feedback', 'tb_visual_latency', 'tb_visual_top', 'tb_audio_pair_cdc',
        'tb_integration_control', 'tb_integration_routing',
        'tb_continuous_expression', 'tb_effect_strength', 'tb_performance_controls',
        'tb_audio_effects', 'tb_expression_audition', 'tb_pitch_expression',
        'tb_settings_pages', 'tb_dynamic_strings8', 'tb_audio_voice_mixer',
        'tb_polyphony_bank_32', 'tb_lcd_pipeline', 'tb_lcd_polyphony_count',
        'tb_smooth_audio', 'tb_physical_strings', 'tb_effects_audition',
        'tb_p2_audio', 'tb_audio_sample_cdc', 'tb_additive_bank_32', 'tb_song_page_mirror'
    ),
    # 1 keeps the original serial run. Higher values run that many benches at once.
    [int]$Jobs = 1
)
$ErrorActionPreference = 'Stop'
# These eight retain the default legacy/module configuration, not the V3 image.
# They are still executed by every full run; nothing is dropped from the suite.
$legacyBenches=@('tb_audio_voice_mixer','tb_dds_control_pipeline','tb_expression_audition',
    'tb_expression_slew','tb_integration_routing','tb_mixer_pipeline','tb_pitch_expression','tb_smooth_audio')
$retainedEngineBenches=@('tb_menu_delay_contract','tb_half_rate_datapaths',
    'tb_concurrent_entry','tb_concurrent_engines','tb_concurrent_top','tb_string_decay',
    'tb_string_route_exact','tb_string_expression','tb_string_expression_top',
    'tb_string_load','tb_string_load_top','tb_dynamic_strings8','tb_physical_strings',
    'tb_additive_bank_32','tb_effects_audition')
$legacyBenches += $retainedEngineBenches
Write-Output 'Stage65: all 136 stage64 benches retained; score envelope/live-owner isolation and UART-to-DAC instrumental playback added (138 total).'
Write-Output ('Suite: {0} current/module checks, {1} retained legacy/module checks, {2} total' -f
    @($Benches | Where-Object {$_ -notin $legacyBenches}).Count,
    @($Benches | Where-Object {$_ -in $legacyBenches}).Count,$Benches.Count)
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    if (!(Test-Path work)) { & "$ModelSimBin/vlib.exe" work }
    # Bootstrap a clean library: earlier runs relied on inherited compiled
    # modules. Compile every enabled portable source and existing bench.
    [xml]$projectXml = Get-Content fpga_instrument_av.gprj -Raw
    $portableSources = @($projectXml.Project.FileList.File | Where-Object {
        $_.enable -eq '1' -and $_.type -eq 'file.verilog' -and
        $_.path -notmatch 'audio_pll/|lcd_pll/|src/pll_init'
    } | ForEach-Object { $_.path })
    # Retired product features keep their historical standalone regression.
    $portableSources += @('rtl/i2c_byte_master.v', 'rtl/i2c_register_master.v',
                         'rtl/gt911_touch.v', 'rtl/touch_preview.v')
    $testSources = @(Get-ChildItem sim -File | Where-Object {
        $_.Extension -in '.v','.sv' -and $_.Name -ne 'tb_latency_audit.v'
    } | ForEach-Object { $_.FullName })
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl+sim' @portableSources @testSources
    if ($LASTEXITCODE -ne 0) { throw 'Clean library bootstrap failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' rtl/concurrent_test_source.v sim/tb_concurrent_entry.v sim/tb_concurrent_engines.v sim/tb_concurrent_top.v
    if ($LASTEXITCODE -ne 0) { throw 'Concurrent all-engine self-test compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' rtl/string_pitch_control.v
    if ($LASTEXITCODE -ne 0) { throw 'String pitch controller compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' rtl/pitch_expression.v sim/stage9_pitch_expression.v sim/tb_pitch_arithmetic_exact.v sim/tb_piano_lookup_exact.v
    if ($LASTEXITCODE -ne 0) { throw 'Audio arithmetic equivalence compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' rtl/polyphony_bank_32.v sim/stage9_polyphony_bank_32.v sim/tb_poly_mix_pipeline.v sim/tb_poly_mix_fast_strobe.v
    if ($LASTEXITCODE -ne 0) { throw 'Polyphony mix equivalence compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' rtl/uart_8n1.v rtl/hc05_link.v sim/tb_hc05_link.sv sim/tb_hc05_top.sv
    if ($LASTEXITCODE -ne 0) { throw 'HC05 UART compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' rtl/note_event_voice.v sim/tb_note_event_voice.v
    if ($LASTEXITCODE -ne 0) { throw 'Note event bridge compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' rtl/song_score_ode.v rtl/song_timing.v rtl/song_timeline.v rtl/song_timeline_rom.v sim/tb_song_timeline.v
    if ($LASTEXITCODE -ne 0) { throw 'Second score compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' rtl/instrument_control.v rtl/status_bundle_cdc.v rtl/audio_voice_mixer.v rtl/polyphony_bank_32.v rtl/physical_string_voice.v rtl/physical_string_bank.v rtl/lcd_timing_800x480.v rtl/lcd_test_pattern.v rtl/song_score_twinkle.v rtl/song_player.v sim/tb_audio_voice_mixer.v sim/tb_polyphony_bank_32.v sim/tb_lcd_pipeline.v sim/tb_lcd_polyphony_count.v sim/baseline_audio_voice_mixer.v sim/tb_smooth_audio.v sim/tb_physical_strings.v sim/tb_settings_pages.v sim/tb_song_score_rom.v sim/tb_song_player.v
    if ($LASTEXITCODE -ne 0) { throw 'ModelSim compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' sim/tb_polyphony_events.v
    if ($LASTEXITCODE -ne 0) { throw 'Polyphony event test compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' sim/stage12_polyphony_bank_32.v sim/tb_poly_adsr.v
    if ($LASTEXITCODE -ne 0) { throw 'Polyphony ADSR test compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' sim/stage15_polyphony_bank_32.v sim/tb_poly_force.v sim/tb_poly_force_top.v
    if ($LASTEXITCODE -ne 0) { throw 'Continuous polyphony force compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' sim/stage16_polyphony_bank_32.v sim/tb_allocator_exact.v
    if ($LASTEXITCODE -ne 0) { throw 'Allocator equivalence compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' sim/stage18_polyphony_bank_32.v sim/tb_poly_expression.v sim/tb_poly_expression_top.v
    if ($LASTEXITCODE -ne 0) { throw 'Polyphony expression compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' sim/stage19_polyphony_bank_32.v sim/tb_poly_glide.v sim/tb_poly_glide_top.v
    if ($LASTEXITCODE -ne 0) { throw 'Polyphony glide compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' sim/stage5_audio_voice_mixer.v sim/tb_mixer_pipeline.v
    if ($LASTEXITCODE -ne 0) { throw 'Mixer pipeline equivalence compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' sim/tb_song_player_data.v
    if ($LASTEXITCODE -ne 0) { throw 'Score data test compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' rtl/pitch_expression.v rtl/expression_audition.v sim/baseline_expression_mixer.v sim/tb_pitch_expression.v sim/tb_expression_audition.v sim/tb_dynamic_strings8.v
    if ($LASTEXITCODE -ne 0) { throw 'Dynamic string test compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' rtl/reverb_comb.v rtl/audio_effects.v rtl/performance_controls.v sim/tb_audio_effects.v sim/tb_performance_controls.v
    if ($LASTEXITCODE -ne 0) { throw 'Effects/control test compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' sim/stage22_audio_effects.v sim/tb_effect_transition.v sim/tb_effect_transition_top.v
    if ($LASTEXITCODE -ne 0) { throw 'Effect transition test compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' sim/tb_expression_slew.v
    if ($LASTEXITCODE -ne 0) { throw 'Expression slew test compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' sim/baseline_audio_effects.v sim/tb_effect_strength.v sim/tb_continuous_expression.v
    if ($LASTEXITCODE -ne 0) { throw 'Strength/continuous-expression compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' rtl/spectrum_analyzer.v rtl/visual_feedback.v rtl/av_top.v rtl/key_debounce.v rtl/pt8211_tx.v rtl/additive_bank_32.v rtl/audio_sample_cdc.v sim/tb_effects_audition.v sim/tb_spectrum.v sim/tb_spectrum_gap.v sim/tb_visual_feedback.v sim/tb_visual_latency.v sim/tb_visual_top.v sim/tb_audio_pair_cdc.v
    if ($LASTEXITCODE -ne 0) { throw 'Production audition compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' sim/tb_visual_freshness.v sim/tb_spectrum_stop.v
    if ($LASTEXITCODE -ne 0) { throw 'Visual freshness compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' sim/baseline_integration_control.v sim/baseline_integration_top.v sim/tb_integration_control.v sim/tb_integration_routing.v rtl/dds_tone_generator.v sim/tb_p2_audio.v sim/tb_audio_sample_cdc.v sim/tb_additive_bank_32.v sim/tb_song_top.v
    if ($LASTEXITCODE -ne 0) { throw 'Integration/transport regression compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' sim/tb_song_lcd.v sim/tb_dds_control_pipeline.v
    if ($LASTEXITCODE -ne 0) { throw 'Song LCD compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' sim/tb_song_select.v sim/tb_song_transport.v sim/tb_song_tempo.v
    if ($LASTEXITCODE -ne 0) { throw 'Song selection compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' sim/tb_song_event_path.v
    if ($LASTEXITCODE -ne 0) { throw 'Production event path compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' sim/tb_poly_control_pipeline.v
    if ($LASTEXITCODE -ne 0) { throw 'Polyphony control pipeline compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' sim/tb_song_poly_display.v
    if ($LASTEXITCODE -ne 0) { throw 'Polyphonic display compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' sim/tb_song_ensemble.v sim/tb_song_timeline_capacity.v
    if ($LASTEXITCODE -ne 0) { throw 'Song ensemble compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' sim/stage20_physical_string_voice.v sim/tb_string_expression.v sim/tb_string_expression_top.v sim/tb_string_load.v sim/tb_string_load_top.v
    if ($LASTEXITCODE -ne 0) { throw 'String expression/load compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' sim/stage22_physical_string_voice.v sim/tb_string_route_exact.v
    if ($LASTEXITCODE -ne 0) { throw 'String route equivalence compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' sim/stage25_physical_string_voice.v sim/tb_string_decay.v
    if ($LASTEXITCODE -ne 0) { throw 'String decay compile failed' }
    & "$ModelSimBin/vlog.exe" -work work '+incdir+rtl' sim/stage29_instrument_control.v sim/tb_song_page_mirror.v
    if ($LASTEXITCODE -ne 0) { throw 'Song page mirror compile failed' }
    if ($Jobs -le 1) {
        foreach ($bench in $Benches) {
            $result = & "$ModelSimBin/vsim.exe" -c "work.$bench" -do 'run -all; quit -f' 2>&1
            $exitCode = $LASTEXITCODE
            $result | Tee-Object -FilePath "sim/$bench.log"
            if ($exitCode -ne 0 -or !($result -match '# PASS:') -or ($result -match '# ERROR:|# \*\* (Error|Fatal):')) {
                throw "$bench failed"
            }
        }
    } else {
        # Automatic vsim optimization writes the shared work/@_opt cache.
        # ModelSim 10.6d produced vsim-7 (_deps missing) under Jobs=12 even
        # though the bench subsequently passed. Elaborate unique designs
        # sequentially first; the parallel simulations then only read them.
        foreach($bench in $Benches) {
            & "$ModelSimBin/vopt.exe" "work.$bench" -o "${bench}_regression"
            if($LASTEXITCODE -ne 0){throw "Optimization failed: $bench"}
        }
        # Keep separate transcript/WLF files and collect every outcome.
        $root = (Get-Location).Path
        $outcomes = $Benches | ForEach-Object -ThrottleLimit $Jobs -Parallel {
            Set-Location $using:root
            $result = & "$using:ModelSimBin/vsim.exe" -c "work.$($_)_regression" -l "sim/$_.transcript" -wlf "sim/$_.wlf" -do 'run -all; quit -f' 2>&1
            $exitCode = $LASTEXITCODE
            $result | Set-Content -Path "sim/$_.log"
            Remove-Item "sim/$_.wlf" -ErrorAction SilentlyContinue
            $passed = $exitCode -eq 0 -and ($result -match '# PASS:') -and !($result -match '# ERROR:|# \*\* (Error|Fatal):')
            [pscustomobject]@{ Bench = $_; Passed = [bool]$passed }
        }
        $outcomes | Sort-Object Bench | ForEach-Object { '{0} {1}' -f ($_.Passed ? 'PASS' : 'FAIL'), $_.Bench }
        $failed = @($outcomes | Where-Object { -not $_.Passed })
        if ($outcomes.Count -ne $Benches.Count) { throw "Only $($outcomes.Count) of $($Benches.Count) benches reported" }
        if ($failed.Count) { throw "$($failed.Count) failed: $($failed.Bench -join ', ')" }
    }
} finally { Pop-Location }
