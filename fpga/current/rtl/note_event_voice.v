`default_nettype none
`include "note_event_contract.vh"

// Single-voice bridge to the existing sample-clocked DDS/ADSR interface.
// One acceptance per sample interval keeps ON visible to the DDS before OFF.
// A new ON replaces this voice; this bridge is not a polyphonic allocator.
// A passive last-event observer may disable the slot limit. It must never be
// used to drive a mono DDS in that configuration (ON/OFF may share a slot).
module note_event_voice #(parameter integer CE_ENABLE=0,
    
    parameter integer LIMIT_PER_SAMPLE = 1
) (
    input wire clock_enable,
    
    input wire clk, reset_n, sample_strobe, flush,
    input wire event_valid, event_on,
    input wire [`NOTE_EVENT_ID_WIDTH-1:0] event_id,
    input wire [`NOTE_EVENT_NOTE_WIDTH-1:0] event_note,
    input wire [`NOTE_EVENT_OCTAVE_WIDTH-1:0] event_octave,
    input wire [`NOTE_EVENT_FORCE_WIDTH-1:0] event_force,
    output wire event_ready,
    output reg gate, trigger,
    output reg [3:0] note,
    output reg [1:0] octave,
    output reg [6:0] force_level
);
    reg [`NOTE_EVENT_ID_WIDTH-1:0] active_id;
    reg accepted_in_slot;
    assign event_ready = reset_n && !flush && !sample_strobe &&
        ((LIMIT_PER_SAMPLE == 0) || !accepted_in_slot);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            gate<=0; trigger<=0; note<=0; octave<=1; force_level<=96;
            active_id<=0; accepted_in_slot<=0;
        end else if ((!CE_ENABLE || clock_enable)) if (flush) begin
            gate<=0; trigger<=0; accepted_in_slot<=0;
            // Keep pitch/velocity while the old envelope releases.
        end else begin
            if (sample_strobe) begin
                trigger<=0;
                accepted_in_slot<=0;
            end
            if (event_valid && event_ready) begin
                accepted_in_slot<=1;
                if (event_on == `NOTE_EVENT_ON) begin
                    if (event_note<4'd12 && event_octave<2'd3 && event_force!=7'd0) begin
                        gate<=1; trigger<=1; active_id<=event_id;
                        note<=event_note; octave<=event_octave; force_level<=event_force;
                    end
                end else if (gate && event_id==active_id) begin
                    gate<=0;
                end
            end
        end
    end
endmodule
`default_nettype wire
