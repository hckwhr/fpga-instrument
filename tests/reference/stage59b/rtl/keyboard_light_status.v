`default_nettype none

// Consume the existing coherent display snapshot in pixel_clk only.
// The song mask is already present; manual notes use the same pitch classes
// as the LCD keyboard. This is a held-key guide, not an envelope/tail meter.
module keyboard_light_status #(parameter integer LIVE_KEYBOARD=0) (
    input wire clk,
    input wire reset_n,
    input wire [67:0] status_payload,
    output reg [11:0] held_notes
);
    `include "instrument_contract.vh"
    wire [2:0] keys = status_payload[ST_KEYS +: 3];
    wire [3:0] note = status_payload[ST_NOTE +: 4];
    wire keymap = status_payload[ST_KEYMAP];
    wire song = status_payload[ST_AUDITION_ACTIVE] &&
                (status_payload[ST_AUDITION_TARGET +: 3] == 3'd7);
    reg [11:0] decoded_notes;
    reg [4:0] root_sum, third_sum, fifth_sum;
    function [11:0] pitch_mask;
        input [4:0] pitch;
        reg [4:0] folded;
        begin
            folded = (pitch >= 5'd24) ? pitch - 5'd24 :
                     (pitch >= 5'd12) ? pitch - 5'd12 : pitch;
            pitch_mask = 12'b1 << folded;
        end
    endfunction
    always @* begin
        root_sum = {1'b0,note};
        third_sum = {1'b0,note} + 5'd2;
        fifth_sum = {1'b0,note} + 5'd4;
        decoded_notes = 12'd0;
        if (song || (LIVE_KEYBOARD && !status_payload[ST_SETTING] &&
            !status_payload[ST_AUDITION_ACTIVE] && !status_payload[ST_TEST] && !status_payload[ST_STRING])) begin
            decoded_notes = status_payload[ST_HELD_NOTES +: 12];
        end else if (!status_payload[ST_SETTING] && note < 4'd12) begin
            if (keymap && status_payload[ST_TEST] && status_payload[ST_POLYPHONY]) begin
                if (keys[0]) decoded_notes = decoded_notes | pitch_mask(root_sum) |
                    pitch_mask(root_sum+5'd4) | pitch_mask(root_sum+5'd7);
                if (keys[1]) decoded_notes = decoded_notes | pitch_mask(root_sum+5'd5) |
                    pitch_mask(root_sum+5'd9) | pitch_mask(root_sum);
                if (keys[2]) decoded_notes = decoded_notes | pitch_mask(root_sum+5'd7) |
                    pitch_mask(root_sum+5'd11) | pitch_mask(root_sum+5'd2);
            end else if (keymap) begin
                root_sum = {1'b0,note} + (keys[2] ? 5'd7 : keys[1] ? 5'd5 : 5'd0);
                third_sum = root_sum + 5'd4;
                fifth_sum = root_sum + 5'd7;
                if (keys != 3'd0) decoded_notes = pitch_mask(root_sum) |
                    pitch_mask(third_sum) | pitch_mask(fifth_sum);
            end else begin
                if (keys[0]) decoded_notes = decoded_notes | pitch_mask(root_sum);
                if (keys[1]) decoded_notes = decoded_notes | pitch_mask(third_sum);
                if (keys[2]) decoded_notes = decoded_notes | pitch_mask(fifth_sum);
            end
        end
    end
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) held_notes <= 12'd0;
        else held_notes <= decoded_notes;
    end
endmodule

`default_nettype wire
