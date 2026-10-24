`default_nettype none

`include "note_event_contract.vh"

// Monophonic score scheduler, independent of score contents.
// Lookup length 0..255; duration and gate are independent 24-bit sample counts.
// Note 15 is a rest (gate=0); other invalid rows terminate safely.
module song_player #(parameter integer CE_ENABLE=0,
    
    parameter integer QUARTER_SAMPLES = 28_800
) (
    input wire clock_enable,
    
    input wire clk, reset_n, sample_strobe, enable,
    input wire stop_pressed, replay_pressed,
    input wire remote_start, remote_stop,
    output wire [7:0] score_index,
    input wire [7:0] score_length,
    input wire [3:0] score_note,
    input wire [1:0] score_octave,
    input wire [6:0] score_force,
    input wire [23:0] score_duration,
    input wire [23:0] score_gate,
    output reg [7:0] note_index,
    output reg done,
    input wire event_ready,
    output wire event_flush,
    output reg event_valid,
    output reg event_on,
    output reg [`NOTE_EVENT_ID_WIDTH-1:0] event_id,
    output reg [`NOTE_EVENT_NOTE_WIDTH-1:0] event_note,
    output reg [`NOTE_EVENT_OCTAVE_WIDTH-1:0] event_octave,
    output reg [`NOTE_EVENT_FORCE_WIDTH-1:0] event_force
);
    // QUARTER_SAMPLES: 4..32767; score durations are independent of this value.
    // 150 ms at production rate: the existing 144-gain ADSR release needs
    // 6912 samples, so it finishes before the next pitch change (7200 samples).
    localparam [15:0] RELEASE_GAP = QUARTER_SAMPLES/4;
    reg [23:0] remaining, gate_remaining;
    reg enable_d, stop_d, replay_d, launch_pending;
    reg [`NOTE_EVENT_ID_WIDTH-1:0] next_id;
    wire stop_event = (stop_pressed && !stop_d) || remote_stop;
    wire replay_event = (replay_pressed && !replay_d) || remote_start;
    wire [7:0] next_index = note_index + 8'd1;
    assign event_flush = !enable || stop_event || !enable_d || replay_event;
    // One lookup port: replay always fetches row zero, never the previous row.
    assign score_index = launch_pending ? 8'd0 : next_index;
    wire rest_row = score_note == 4'd15;
    wire score_row_valid = score_index < score_length && score_duration != 24'd0 &&
        (rest_row ? score_gate == 24'd0 :
         (score_note < 4'd12 && score_octave < 2'd3 && score_force != 7'd0 &&
          score_gate != 24'd0 && score_gate < score_duration));

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            event_valid<=0; event_on<=`NOTE_EVENT_OFF; event_id<=0;
            event_note<=0; next_id<=0; note_index<=0; done<=0;
            event_octave<=1; event_force<=96;
            remaining<=0; gate_remaining<=0; enable_d<=0; stop_d<=0; replay_d<=0;
            launch_pending<=0;
        end else if ((!CE_ENABLE || clock_enable)) begin
            enable_d<=enable; stop_d<=stop_pressed; replay_d<=replay_pressed;
            if (event_valid && event_ready) event_valid<=0;
            if (!enable) begin
                event_valid<=0; event_note<=0; note_index<=0; done<=0;
                remaining<=0; gate_remaining<=0; launch_pending<=0;
            end else if (stop_event) begin
                event_valid<=0; done<=1; launch_pending<=0; gate_remaining<=0;
            end else if (!enable_d || replay_event) begin
                // First entry and replay begin with a release gap, so a replay
                // during a held note cannot retain the old envelope or pitch.
                event_valid<=0; done<=0; launch_pending<=1;
                note_index<=0;
                remaining<=RELEASE_GAP;
                gate_remaining<=0;
            end else if (sample_strobe && (!event_valid || event_ready)) begin
                // One-entry mailbox: stall score time rather than lose an event.
                if (!done) begin
                    if (gate_remaining!=0) begin
                        gate_remaining<=gate_remaining-1'b1;
                        if (gate_remaining==1) begin
                            event_valid<=1; event_on<=`NOTE_EVENT_OFF;
                        end
                    end
                    if (launch_pending) begin
                        if (remaining>1) remaining<=remaining-1'b1;
                        else if (!score_row_valid) begin
                            launch_pending<=0; done<=1; remaining<=0;
                        end
                        else begin
                            launch_pending<=0; note_index<=0; event_note<=score_note;
                            event_valid<=!rest_row; event_on<=`NOTE_EVENT_ON;
                            event_id<=next_id; next_id<=next_id+1'b1;
                            event_octave<=score_octave; event_force<=score_force;
                            remaining<=score_duration;
                            gate_remaining<=score_gate;
                        end
                    end else if (remaining==1) begin
                        if (!score_row_valid) begin
                            done<=1; remaining<=0;
                        end else begin
                            note_index<=next_index; event_note<=score_note;
                            event_valid<=!rest_row; event_on<=`NOTE_EVENT_ON;
                            event_id<=next_id; next_id<=next_id+1'b1;
                            event_octave<=score_octave; event_force<=score_force;
                            remaining<=score_duration;
                            gate_remaining<=score_gate;
                        end
                    end else if (remaining>1) begin
                        remaining<=remaining-1'b1;
                    end
                end
            end
        end
    end
endmodule
`default_nettype wire
