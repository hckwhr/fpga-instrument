`timescale 1ns/1ps
`default_nettype none
// The three production engines driven together by concurrent_test_source at
// the production rate of 1024 clocks per sample. Writes each engine's PCM so
// the gains of the final mix can be chosen from measured peaks, and so the
// spectrum can be checked for 72 separate fundamentals.
module tb_concurrent_engines;
    parameter integer SETTLE_SAMPLES = 42000;   // additive bank needs 32 x 1200
    parameter integer CAPTURE_SAMPLES = 65536;
    reg clk = 0, reset_n = 0;
    always #5 clk = ~clk;
    reg [9:0] divider = 0;
    reg sample_strobe = 0;
    always @(posedge clk) begin
        divider <= divider + 10'd1;
        sample_strobe <= (divider == 10'd1023);
    end

    wire event_ready, event_valid, event_on, issued;
    wire [15:0] event_id;
    wire [3:0] event_note, string_note;
    wire [1:0] event_octave, string_octave;
    wire [6:0] event_force;
    wire [2:0] string_trigger;
    concurrent_test_source source (
        .clk(clk), .reset_n(reset_n), .sample_strobe(sample_strobe), .enable(1'b1),
        .event_ready(event_ready), .event_valid(event_valid), .event_on(event_on),
        .event_id(event_id), .event_note(event_note), .event_octave(event_octave),
        .event_force(event_force), .poly_notes_issued(issued),
        .string_trigger(string_trigger), .string_note(string_note), .string_octave(string_octave));

    wire signed [15:0] poly_sample, string_sample, additive_sample;
    wire [5:0] poly_count;
    wire [3:0] string_count;
    wire [7:0] string_misses;
    wire additive_all;
    polyphony_bank_32 poly (
        .clk(clk), .reset_n(reset_n), .sample_strobe(sample_strobe), .enable(1'b1),
        .voice_trigger(3'b000), .voice_gate(3'b000), .play_mode(1'b0), .tone_select(2'd0),
        .note_select(4'd0), .keymap_select(1'b0), .octave_select(2'd1), .force_value(7'd96),
        .glide_select(2'd0), .bend(8'sd0), .vibrato_depth(8'd0),
        .event_mode(1'b1), .event_flush(1'b0), .wide_event_octave(1'b1), .event_valid(event_valid), .event_on(event_on),
        .event_id(event_id), .event_note(event_note), .event_octave(event_octave),
        .event_force(event_force), .event_ready(event_ready),
        .sample(poly_sample), .active_voice_count(poly_count),
        .held_note_mask(), .all_voices_active());
    physical_string_bank strings (
        .clk(clk), .reset_n(reset_n), .sample_strobe(sample_strobe), .enable(1'b1),
        .voice_trigger(string_trigger), .voice_gate(3'b000), .play_mode(1'b1),
        .keymap_select(1'b0), .note_select(string_note), .octave_select(string_octave),
        .force_value(7'd96), .sample(string_sample), .active_voices(),
        .active_voice_count(string_count), .deadline_miss_count(string_misses));
    additive_bank_32 additive (
        .clk(clk), .reset_n(reset_n), .sample_strobe(sample_strobe), .enable(1'b1),
        .sample(additive_sample), .all_partials_active(additive_all));

    integer fd, samples = 0, minimum_strings = 8, minimum_poly = 32;
    initial begin
        fd = $fopen("sim/concurrent_engines.csv", "w");
        $fdisplay(fd, "poly,string,additive,poly_count,string_count");
        repeat (8) @(posedge clk);
        reset_n = 1;
    end
    always @(posedge clk) if (reset_n && sample_strobe) begin
        samples = samples + 1;
        if (samples > SETTLE_SAMPLES) begin
            $fdisplay(fd, "%0d,%0d,%0d,%0d,%0d", poly_sample, string_sample, additive_sample,
                      poly_count, string_count);
            if (string_count < minimum_strings) minimum_strings = string_count;
            if (poly_count < minimum_poly) minimum_poly = poly_count;
        end
        if (samples == SETTLE_SAMPLES + CAPTURE_SAMPLES) begin
            $fclose(fd);
            if (!issued || !additive_all || minimum_poly != 32 || string_misses != 0)
                $display("# ERROR: issued=%b additive_all=%b min_poly=%0d min_strings=%0d string_misses=%0d",
                         issued, additive_all, minimum_poly, minimum_strings, string_misses);
            else $display("# PASS: 32 poly voices and all 32 partials held for %0d samples; strings active min %0d of 8, no deadline miss",
                          CAPTURE_SAMPLES, minimum_strings);
            $finish;
        end
    end
endmodule
`default_nettype wire
