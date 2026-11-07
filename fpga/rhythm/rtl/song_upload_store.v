`default_nettype none
// Decoded transaction backend, not an ASCII/UART receiver. The caller must
// validate the complete wire frame/CRC and deduplicate session/sequence before
// issuing commands. DATA is one 64-bit word; a block ACK follows all word ACKs.
// All ports share clk. playback_busy is a SAME-DOMAIN ownership lock.
module song_upload_store #(parameter integer SCORE_BITS=9, PROGRESS_BITS=8,
    
    parameter integer IDLE_TIMEOUT_CYCLES = 1_500_000_000
) (
    input wire clk, reset_n,
    input wire command_valid,
    output wire command_ready,
    input wire [1:0] command,
    input wire [SCORE_BITS:0] request_length,
    input wire [23:0] request_end_tick,
    input wire [PROGRESS_BITS-1:0] request_melody_count,
    input wire [15:0] request_crc,
    input wire [SCORE_BITS-1:0] request_index,
    input wire [63:0] request_word,
    output reg response_valid,
    input wire response_ready,
    output reg [3:0] response_code,
    output reg [SCORE_BITS:0] response_count,
    input wire playback_busy,
    input wire [SCORE_BITS-1:0] score_index,
    output reg [63:0] score_data,
    output reg score_valid,
    output reg [SCORE_BITS:0] score_length,
    output reg [23:0] score_end_tick,
    output reg [PROGRESS_BITS-1:0] score_melody_count,
    output reg [15:0] score_crc,
    output reg published,
    output reg staging,
    output reg expired
);
    localparam [1:0] BEGIN=0, DATA=1, COMMIT=2, ABORT=3;
    localparam [3:0] OK=0, STATE_ERROR=1, CAPACITY_ERROR=2, OFFSET_ERROR=3,
                     CONTENT_ERROR=4, BUSY_ERROR=5;
    localparam integer TW = IDLE_TIMEOUT_CYCLES>1 ? $clog2(IDLE_TIMEOUT_CYCLES) : 1;
    localparam [TW-1:0] TIMEOUT_LAST = IDLE_TIMEOUT_CYCLES-1;
    reg [TW-1:0] idle_count;
    reg active_bank;
    reg [SCORE_BITS:0] received_count, staged_length;
    reg [23:0] staged_end_tick;
    reg [PROGRESS_BITS-1:0] staged_melody_count;
    reg [15:0] staged_crc;
    reg validating, validate_start;
    wire validate_done, validate_valid;
    wire [SCORE_BITS-1:0] validate_index;
    reg [63:0] validate_data;
    reg [63:0] memory [0:(2 << SCORE_BITS)-1];
    wire accept = command_valid && command_ready;
    wire write_word = reset_n && accept && command==DATA && staging && idle_count!=TIMEOUT_LAST &&
        received_count<staged_length && {1'b0,request_index}==received_count;
    assign command_ready = !validating && !response_valid;

    // No RAM resets or asynchronous read mux. The inactive half is owned by
    // staging/validator; publication requires that playback has released its lock.
    always @(posedge clk) begin
        if (write_word) memory[{!active_bank,request_index}]<=request_word;
        validate_data<=memory[{!active_bank,validate_index}];
        score_data<=memory[{active_bank,score_index}];
    end
    song_score_validator #(.SCORE_BITS(SCORE_BITS),.PROGRESS_BITS(PROGRESS_BITS)) validator (
        .clk(clk),.reset_n(reset_n),.start(validate_start),
        .length(staged_length),.end_tick(staged_end_tick),
        .melody_count(staged_melody_count),.expected_crc(staged_crc),
        .read_index(validate_index),.read_data(validate_data),
        .busy(),.done(validate_done),.valid(validate_valid),.actual_crc()
    );

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            idle_count<=0; active_bank<=0; received_count<=0; staged_length<=0;
            staged_end_tick<=0; staged_melody_count<=0; staged_crc<=0;
            validating<=0; validate_start<=0; response_valid<=0; response_code<=OK; response_count<=0;
            score_valid<=0; score_length<=0; score_end_tick<=0; score_melody_count<=0; score_crc<=0;
            published<=0; staging<=0; expired<=0;
        end else begin
            published<=0; expired<=0; validate_start<=0;
            if (response_valid && response_ready) response_valid<=0;
            if (staging && !validating) begin
                if (idle_count==TIMEOUT_LAST) begin staging<=0; received_count<=0; idle_count<=0; expired<=1; end
                else idle_count<=idle_count+1'b1;
            end else idle_count<=0;
            if (accept) begin
                idle_count<=0; response_valid<=1; response_code<=OK; response_count<=received_count;
                // At the exact expiry edge the old transaction is no longer
                // eligible for DATA/COMMIT; BEGIN may start a new one next cycle.
                if (staging && idle_count==TIMEOUT_LAST && command!=ABORT) response_code<=STATE_ERROR;
                else case (command)
                    BEGIN: if (staging) response_code<=BUSY_ERROR;
                        else if (request_length==0 || request_length>(1 << SCORE_BITS) || request_length[0] ||
                                 request_end_tick==0 || request_melody_count==0 || request_melody_count>(1 << (SCORE_BITS-1))) response_code<=CAPACITY_ERROR;
                        else begin
                            staging<=1; received_count<=0; response_count<=0;
                            staged_length<=request_length; staged_end_tick<=request_end_tick;
                            staged_melody_count<=request_melody_count; staged_crc<=request_crc;
                        end
                    DATA: if (!staging) response_code<=STATE_ERROR;
                        else if (received_count>=staged_length || {1'b0,request_index}!=received_count) response_code<=OFFSET_ERROR;
                        else begin received_count<=received_count+1'b1; response_count<=received_count+1'b1; end
                    COMMIT: if (!staging) response_code<=STATE_ERROR;
                        else if (playback_busy) response_code<=BUSY_ERROR;
                        else if (received_count!=staged_length || request_length!=staged_length || request_crc!=staged_crc) response_code<=CONTENT_ERROR;
                        else begin validating<=1; validate_start<=1; response_valid<=0; end
                    ABORT: begin staging<=0; received_count<=0; response_count<=0; end
                    default: response_code<=STATE_ERROR;
                endcase
            end
            if (validating && validate_done) begin
                validating<=0; response_valid<=1; response_count<=received_count; idle_count<=0;
                if (!validate_valid) response_code<=CONTENT_ERROR;
                else if (playback_busy) response_code<=BUSY_ERROR;
                else begin
                    response_code<=OK; active_bank<=!active_bank; staging<=0; received_count<=0;
                    score_valid<=1; score_length<=staged_length; score_end_tick<=staged_end_tick;
                    score_melody_count<=staged_melody_count; score_crc<=staged_crc; published<=1;
                end
            end
        end
    end
endmodule
`default_nettype wire
