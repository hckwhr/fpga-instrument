`timescale 1ns/1ps
`default_nettype none
// Stage 30: instrument_control with the song_page next-state mirror must match
// the frozen stage-29 control on every output and every clock, and song_page
// must equal the decode it replaces on every clock.
module tb_song_page_mirror;
    reg clk = 0, reset_n = 0;
    reg [2:0] key_pressed = 0;
    reg setting_pressed = 0, remote_song_start = 0;
    always #5 clk = ~clk;

    localparam W = 3+1+1+1+3+1+2+1+4+7+1+2+2+2+2+2+1+3+1+1+2+1+1+1+28;
    wire [W-1:0] got, want;
`define CONTROL_PORTS(bus) \
        .clk(clk), .reset_n(reset_n), .key_pressed(key_pressed), \
        .setting_pressed(setting_pressed), .remote_song_start(remote_song_start), \
        .play_trigger(bus[W-1 -: 3]), .play_mute(bus[W-4]), .setting_mode(bus[W-5]), \
        .settings_page(bus[W-6]), .selected_field(bus[W-7 -: 3]), .play_mode(bus[W-10]), \
        .tone_select(bus[W-11 -: 2]), .string_mode(bus[W-13]), .note_select(bus[W-14 -: 4]), \
        .force_value(bus[W-18 -: 7]), .keymap_select(bus[W-25]), .octave_select(bus[W-26 -: 2]), \
        .effect_select(bus[W-28 -: 2]), .effect_strength(bus[W-30 -: 2]), .glide_select(bus[W-32 -: 2]), \
        .vibrato_select(bus[W-34 -: 2]), .audition_mode(bus[W-36]), .audition_target(bus[W-37 -: 3]), \
        .song_select(bus[W-40]), .song_accompaniment(bus[W-41]), .song_tempo(bus[W-42 -: 2]), \
        .song_change(bus[W-44]), .test_mode(bus[W-45]), .test_polyphony(bus[W-46]), \
        .status_payload(bus[27:0])
    instrument_control #(.PLAY_GUARD_CYCLES(5), .PLAY_GUARD_COUNTER_WIDTH(3)) dut (`CONTROL_PORTS(got));
    stage29_instrument_control #(.PLAY_GUARD_CYCLES(5), .PLAY_GUARD_COUNTER_WIDTH(3)) frozen (`CONTROL_PORTS(want));

    integer cycles = 0, changes = 0, page_high = 0, page_edges = 0, setting_edges = 0, errors = 0;
    integer active_high = 0, song_high = 0, test_high = 0;
    integer seed = 32'h5A6E_3001;
    reg page_d = 0, setting_d = 0;
    wire decode = dut.audition_mode && dut.audition_target == 3'd7 && !dut.setting_mode;
    always @(negedge clk) if (reset_n) begin
        cycles = cycles + 1;
        if (got !== want) begin
            errors = errors + 1;
            if (errors < 5) $display("# ERROR: output mismatch at %0t got=%h want=%h", $time, got, want);
        end
        if (dut.song_page !== decode) begin
            errors = errors + 1;
            if (errors < 5) $display("# ERROR: song_page=%b decode=%b at %0t", dut.song_page, decode, $time);
        end
        if (dut.audition_active !== (dut.audition_mode && !dut.setting_mode && !dut.test_mode) ||
            dut.song_active !== (dut.audition_mode && !dut.setting_mode && !dut.test_mode && dut.audition_target == 3'd7) ||
            dut.self_test_active !== (dut.test_mode && !dut.setting_mode)) begin
            errors = errors + 1;
            if (errors < 5) $display("# ERROR: mode decode mirror differs at %0t", $time);
        end
        active_high = active_high + dut.audition_active; song_high = song_high + dut.song_active;
        test_high = test_high + dut.self_test_active;
        changes = changes + got[W-44];
        page_high = page_high + dut.song_page;
        page_edges = page_edges + (dut.song_page != page_d);
        setting_edges = setting_edges + (dut.setting_mode != setting_d);
        page_d = dut.song_page; setting_d = dut.setting_mode;
    end

    // Keys are held for a random number of clocks, including single-clock
    // presses and simultaneous keys, so every guard and pulse case is reached.
    integer hold;
    initial begin
        repeat (4) @(posedge clk);
        reset_n = 1;
        while (cycles < 600000) begin
            @(posedge clk); #1;
            if ({$random(seed)} % 4 == 0) key_pressed[0] = ~key_pressed[0];
            if ({$random(seed)} % 6 == 0) key_pressed[1] = ~key_pressed[1];
            if ({$random(seed)} % 5 == 0) key_pressed[2] = ~key_pressed[2];
            if ({$random(seed)} % 40 == 0) setting_pressed = ~setting_pressed;
            remote_song_start = ({$random(seed)} % 97 == 0);
            if ({$random(seed)} % 20000 == 0) begin
                reset_n = 0; @(posedge clk); #1; reset_n = 1;
            end
            hold = {$random(seed)} % 3;
            repeat (hold) @(posedge clk);
        end
        if (errors != 0) $display("# ERROR: %0d mismatches", errors);
        else if (changes < 200 || page_edges < 200 || setting_edges < 200 || page_high < 2000 ||
                 active_high < 2000 || song_high < 2000 || test_high < 2000)
            $display("# ERROR: weak coverage changes=%0d page_edges=%0d setting_edges=%0d page_high=%0d",
                     changes, page_edges, setting_edges, page_high);
        else $display("# PASS: %0d clocks identical to stage 29; song_change=%0d song_page edges=%0d high=%0d setting edges=%0d",
                      cycles, changes, page_edges, page_high, setting_edges);
        $finish;
    end
endmodule
`default_nettype wire