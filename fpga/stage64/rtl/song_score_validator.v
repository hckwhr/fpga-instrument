`default_nettype none
// ABI 12 admission scanner. The RAM read address is sampled at an edge and
// read_data arrives after that edge. Two states separate address and capture.
// Slot tails use 25-bit time so a release near 24'hffffff cannot wrap early.
module song_score_validator #(parameter integer SCORE_BITS=9, PROGRESS_BITS=8) (
    input wire clk, reset_n, start,
    input wire [SCORE_BITS:0] length,
    input wire [23:0] end_tick,
    input wire [PROGRESS_BITS-1:0] melody_count,
    input wire [15:0] expected_crc,
    output wire [SCORE_BITS-1:0] read_index,
    input wire [63:0] read_data,
    output reg busy, done, valid,
    output reg [15:0] actual_crc
);
    localparam [3:0] IDLE=0, CLEAR=1, FETCH=2, CAPTURE=3, CRC_BYTE=4,
                     HEADER=5, SCAN=6, APPLY=7, ADVANCE=8, FINISH=9, FAIL=10;
    reg [3:0] state, slot_index, free_slot, match_slot;
    reg [SCORE_BITS:0] event_index;
    reg [63:0] word_q, crc_shift;
    reg [2:0] byte_index;
    reg [15:0] crc;
    reg [23:0] previous_tick;
    reg previous_last, previous_on;
    reg [15:0] previous_id;
    reg [4:0] group_count, occupied_count, active_count;
    reg [10:0] velocity_sum;
    reg [SCORE_BITS:0] note_count, melody_seen;
    reg found_free, found_match, active_melody;
    // SUG550 5.16: shallow multi-index slot tables use spare FFs, not SSRAM.
    reg slot_used [0:15] /* synthesis syn_ramstyle="registers" */;
    reg slot_active [0:15] /* synthesis syn_ramstyle="registers" */;
    reg [15:0] slot_id [0:15] /* synthesis syn_ramstyle="registers" */;
    reg [22:0] slot_attributes [0:15] /* synthesis syn_ramstyle="registers" */;
    reg [23:0] slot_start [0:15] /* synthesis syn_ramstyle="registers" */;
    reg [24:0] slot_release [0:15] /* synthesis syn_ramstyle="registers" */;
    wire [23:0] tick = word_q[63:40];
    wire note_on = word_q[39];
    // ABI 13 keeps the 64-bit event layout and 16-bit unique note ID.
    // The low byte is a modulo-256 progress tag, checked against a FULL counter.
    // Full UI/status progress is counted by the timeline, never this tag.
    wire [15:0] note_id = word_q[38:23];
    wire [7:0] progress = word_q[7:0];
    wire [6:0] force_value = word_q[16:10];
    wire melody = word_q[8];
    wire slot_live = slot_used[slot_index] &&
        (slot_active[slot_index] || slot_release[slot_index] > {1'b0,tick});
    assign read_index = event_index[SCORE_BITS-1:0];

    function [15:0] crc_byte;
        input [15:0] old_crc;
        input [7:0] value;
        reg [15:0] next_crc;
        integer bit_number;
        begin
            next_crc = old_crc ^ {value,8'd0};
            for (bit_number=0; bit_number<8; bit_number=bit_number+1)
                next_crc = next_crc[15] ? (next_crc << 1) ^ 16'h1021 : next_crc << 1;
            crc_byte = next_crc;
        end
    endfunction

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state<=IDLE; busy<=0; done<=0; valid<=0; actual_crc<=16'hffff;
            slot_index<=0; free_slot<=0; match_slot<=0; event_index<=0;
            word_q<=0; crc_shift<=0; byte_index<=0; crc<=16'hffff;
            previous_tick<=0; previous_last<=0; previous_on<=0; previous_id<=0;
            group_count<=0; occupied_count<=0; active_count<=0; velocity_sum<=0;
            note_count<=0; melody_seen<=0; found_free<=0; found_match<=0; active_melody<=0;
        end else begin
            done<=0;
            case (state)
                IDLE: if (start) begin
                    busy<=1; valid<=0; crc<=16'hffff; actual_crc<=16'hffff;
                    event_index<=0; slot_index<=0; active_count<=0; note_count<=0; melody_seen<=0;
                    previous_tick<=0; previous_last<=0; previous_on<=0; previous_id<=0; group_count<=0;
                    if (length==0 || length>(1 << SCORE_BITS) || length[0] || melody_count==0 || end_tick==0) state<=FAIL;
                    else state<=CLEAR;
                end
                CLEAR: begin
                    slot_used[slot_index]<=0; slot_active[slot_index]<=0;
                    slot_id[slot_index]<=0; slot_attributes[slot_index]<=0;
                    slot_start[slot_index]<=0; slot_release[slot_index]<=0;
                    if (slot_index==4'd15) state<=FETCH;
                    else slot_index<=slot_index+1'b1;
                end
                FETCH: state<=CAPTURE;
                CAPTURE: begin
                    word_q<=read_data; crc_shift<=read_data; byte_index<=0; state<=CRC_BYTE;
                end
                CRC_BYTE: begin
                    crc<=crc_byte(crc,crc_shift[63:56]); crc_shift<={crc_shift[55:0],8'd0};
                    if (byte_index==3'd7) state<=HEADER;
                    else byte_index<=byte_index+1'b1;
                end
                HEADER: begin
                    if (tick>end_tick || word_q[22:19]>=4'd12 || word_q[18:17]>=2'd3 || force_value==0 ||
                        (!melody && progress!=0) ||
                        (event_index!=0 && (tick<previous_tick ||
                        (tick==previous_tick && (previous_last || group_count==5'd16 ||
                          (previous_on && !note_on) || (previous_on==note_on && note_id<=previous_id))) ||
                        (tick>previous_tick && !previous_last)))) state<=FAIL;
                    else begin
                        group_count<=(event_index==0 || tick!=previous_tick) ? 5'd1 : group_count+1'b1;
                        slot_index<=0; occupied_count<=0; velocity_sum<=0;
                        found_free<=0; found_match<=0; active_melody<=0; state<=SCAN;
                    end
                end
                SCAN: begin
                    if (slot_live) begin
                        occupied_count<=occupied_count+1'b1;
                        velocity_sum<=velocity_sum+{4'd0,slot_attributes[slot_index][16:10]};
                        if (slot_active[slot_index] && slot_attributes[slot_index][8]) active_melody<=1;
                        if (slot_active[slot_index] && slot_id[slot_index]==note_id) begin
                            found_match<=1; match_slot<=slot_index;
                        end
                    end else begin
                        slot_used[slot_index]<=0;
                        if (!found_free) begin found_free<=1; free_slot<=slot_index; end
                    end
                    if (slot_index==4'd15) state<=APPLY;
                    else slot_index<=slot_index+1'b1;
                end
                APPLY: if (note_on) begin
                    if (!found_free || found_match || occupied_count>=5'd16 ||
                        velocity_sum+{4'd0,force_value}>11'd768 || note_count>=(1 << (SCORE_BITS-1)) ||
                        note_id!=note_count ||
                        (melody && (active_melody || melody_seen>=(PROGRESS_BITS>8 ? (1 << (SCORE_BITS-1)) : 255) || progress!=melody_seen[7:0]))) state<=FAIL;
                    else begin
                        slot_used[free_slot]<=1; slot_active[free_slot]<=1; slot_id[free_slot]<=note_id;
                        slot_attributes[free_slot]<=word_q[22:0]; slot_start[free_slot]<=tick;
                        active_count<=active_count+1'b1; note_count<=note_count+1'b1;
                        if (melody) melody_seen<=melody_seen+1'b1;
                        state<=ADVANCE;
                    end
                end else begin
                    if (!found_match || active_count==0 || tick<=slot_start[match_slot] ||
                        (word_q[22:0] & 23'h7ffdff)!=(slot_attributes[match_slot] & 23'h7ffdff)) state<=FAIL;
                    else begin
                        slot_active[match_slot]<=0; slot_release[match_slot]<={1'b0,tick}+25'd6;
                        active_count<=active_count-1'b1; state<=ADVANCE;
                    end
                end
                ADVANCE: begin
                    previous_tick<=tick; previous_last<=word_q[9]; previous_on<=note_on; previous_id<=note_id;
                    if (event_index+1'b1==length) state<=FINISH;
                    else begin event_index<=event_index+1'b1; state<=FETCH; end
                end
                FINISH: begin
                    actual_crc<=crc;
                    if (active_count!=0 || !previous_last || melody_seen!=melody_count || crc!=expected_crc) state<=FAIL;
                    else begin busy<=0; done<=1; valid<=1; state<=IDLE; end
                end
                FAIL: begin actual_crc<=crc; busy<=0; done<=1; valid<=0; state<=IDLE; end
                default: state<=FAIL;
            endcase
        end
    end
endmodule
`default_nettype wire
