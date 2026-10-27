`default_nettype none
`include "note_event_contract.vh"

// Stimulus for the all-engine self-test: every sounding unit is still one of
// the production oscillators or strings; this module only tells them which
// pitch to play, as a keyboard or a score would.
//
//  - polyphony_bank_32 receives 32 note-on events and holds them, one voice
//    per pitch;
//  - physical_string_bank receives one KEY0 pluck at a time, cycling through
//    8 pitches so each string is struck again before it has died away.
//
// Pitches are chosen so that the 32 + 8 fundamentals and the additive bank's
// 32 harmonics of 110 Hz are all different: strings take C3..G3, polyphony
// takes the 32 remaining equal-tempered pitches up to B6 that sit at least
// 3 Hz from any multiple of 110 Hz (no A, no E above E3, no B5).
module concurrent_test_source #(parameter integer CE_ENABLE=0,
    
    parameter integer PLUCK_INTERVAL_SAMPLES = 12_000,  // 0.25 s: 2 s per string
    parameter integer STARTUP_INTERVAL_SAMPLES = 256,   // first pass over 8 strings
    parameter [6:0] POLY_FORCE = 7'd64
) (
    input wire clock_enable,
    
    input  wire clk, reset_n, sample_strobe, enable,
    input  wire event_ready,
    output wire event_valid,
    output wire event_on,
    output wire [`NOTE_EVENT_ID_WIDTH-1:0] event_id,
    output wire [3:0] event_note,
    output wire [1:0] event_octave,
    output wire [6:0] event_force,
    output wire poly_notes_issued,
    output reg  [2:0] string_trigger,
    output wire [3:0] string_note,
    output wire [1:0] string_octave
);
    // {octave, note}; octave 0 = C3.
    function [5:0] poly_pitch;
        input [4:0] index;
        begin
            case (index)
                 0: poly_pitch = {2'd0, 4'd8};   1: poly_pitch = {2'd0, 4'd10};
                 2: poly_pitch = {2'd0, 4'd11};  3: poly_pitch = {2'd1, 4'd0};
                 4: poly_pitch = {2'd1, 4'd1};   5: poly_pitch = {2'd1, 4'd2};
                 6: poly_pitch = {2'd1, 4'd3};   7: poly_pitch = {2'd1, 4'd5};
                 8: poly_pitch = {2'd1, 4'd6};   9: poly_pitch = {2'd1, 4'd7};
                10: poly_pitch = {2'd1, 4'd8};  11: poly_pitch = {2'd1, 4'd10};
                12: poly_pitch = {2'd1, 4'd11}; 13: poly_pitch = {2'd2, 4'd0};
                14: poly_pitch = {2'd2, 4'd1};  15: poly_pitch = {2'd2, 4'd2};
                16: poly_pitch = {2'd2, 4'd3};  17: poly_pitch = {2'd2, 4'd5};
                18: poly_pitch = {2'd2, 4'd6};  19: poly_pitch = {2'd2, 4'd7};
                20: poly_pitch = {2'd2, 4'd8};  21: poly_pitch = {2'd2, 4'd10};
                22: poly_pitch = {2'd3, 4'd0};  23: poly_pitch = {2'd3, 4'd1};
                24: poly_pitch = {2'd3, 4'd2};  25: poly_pitch = {2'd3, 4'd3};
                26: poly_pitch = {2'd3, 4'd5};  27: poly_pitch = {2'd3, 4'd6};
                28: poly_pitch = {2'd3, 4'd7};  29: poly_pitch = {2'd3, 4'd8};
                30: poly_pitch = {2'd3, 4'd10}; default: poly_pitch = {2'd3, 4'd11};
            endcase
        end
    endfunction

    // One event per accepted handshake. The payload depends only on the index,
    // which moves on acceptance, so it is stable while valid waits for ready.
    reg [5:0] poly_index;
    assign poly_notes_issued = poly_index[5];
    assign event_valid = enable && !poly_notes_issued;
    assign event_on = `NOTE_EVENT_ON;
    assign event_id = {10'd0, poly_index} + 16'd1;
    assign {event_octave, event_note} = poly_pitch(poly_index[4:0]);
    assign event_force = POLY_FORCE;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) poly_index <= 6'd0;
        else if ((!CE_ENABLE || clock_enable)) if (!enable) poly_index <= 6'd0;
        else if (event_valid && event_ready) poly_index <= poly_index + 6'd1;
    end

    // KEY0 in pluck mode with the gates low strikes exactly the selected note.
    // The note index is held for the whole interval; the bank reads it on the
    // sample boundary after the one-clock trigger.
    reg [2:0] string_index;
    reg first_pass;
    reg [23:0] interval_count;
    wire [23:0] interval_last = (first_pass ? STARTUP_INTERVAL_SAMPLES
                                            : PLUCK_INTERVAL_SAMPLES) - 1;
    assign string_note = {1'b0, string_index};
    assign string_octave = 2'd0;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            string_index <= 3'd0; first_pass <= 1'b1;
            interval_count <= 24'd0; string_trigger <= 3'b000;
        end else if ((!CE_ENABLE || clock_enable)) if (!enable) begin
            string_index <= 3'd0; first_pass <= 1'b1;
            interval_count <= 24'd0; string_trigger <= 3'b000;
        end else begin
            string_trigger <= 3'b000;
            if (sample_strobe) begin
                if (interval_count == 24'd0) string_trigger <= 3'b001;
                if (interval_count == interval_last) begin
                    interval_count <= 24'd0;
                    string_index <= string_index + 3'd1;
                    if (string_index == 3'd7) first_pass <= 1'b0;
                end else interval_count <= interval_count + 24'd1;
            end
        end
    end
endmodule
`default_nettype wire
