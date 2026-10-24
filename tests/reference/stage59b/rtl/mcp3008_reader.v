`default_nettype none

// MCP3008 mode-0 reader for one channel.
// The command is 1/start, 1/single-ended, 000/channel 0.  MISO is sampled
// on SCLK rising edges; the ten data bits follow one null bit.
module mcp3008_reader #(
    parameter integer CLK_DIV_CYCLES = 25,
    parameter integer SAMPLE_PERIOD_CYCLES = 250000,
    parameter integer EXTERNAL_START = 0
) (
    input  wire       clk,
    input  wire       reset_n,
    input  wire       adc_miso,
    output reg        adc_sclk,
    output reg        adc_mosi,
    output reg        adc_cs_n,
    output reg [9:0]  adc_value,
    output reg        sample_valid,
    output reg        busy,
    input  wire       start,
    input  wire [2:0] channel
);
    localparam integer DIV_WIDTH = (CLK_DIV_CYCLES <= 1) ? 1 : $clog2(CLK_DIV_CYCLES);
    localparam integer PERIOD_WIDTH = (SAMPLE_PERIOD_CYCLES <= 1) ? 1 : $clog2(SAMPLE_PERIOD_CYCLES);

    reg [DIV_WIDTH-1:0] div_count;
    reg [PERIOD_WIDTH-1:0] period_count;
    reg [4:0] bit_index;
    reg [9:0] shift_reg;
    reg [2:0] selected_channel;

    function [0:0] command_bit;
        input [4:0] index;
        begin
            case (index)
                5'd0: command_bit = 1'b1; // start
                5'd1: command_bit = 1'b1; // single-ended
                5'd2: command_bit = selected_channel[2];
                5'd3: command_bit = selected_channel[1];
                5'd4: command_bit = selected_channel[0];
                default: command_bit = 1'b0; // channel 0 and data phase
            endcase
        end
    endfunction

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            adc_sclk    <= 1'b0;
            adc_mosi    <= 1'b0;
            adc_cs_n    <= 1'b1;
            adc_value   <= 10'd0;
            sample_valid<= 1'b0;
            busy        <= 1'b0;
            div_count   <= {DIV_WIDTH{1'b0}};
            period_count<= {PERIOD_WIDTH{1'b0}};
            bit_index   <= 5'd0;
            shift_reg   <= 10'd0;
            selected_channel <= 3'd0;
        end else begin
            sample_valid <= 1'b0;

            if (!busy) begin
                adc_sclk <= 1'b0;
                adc_mosi <= 1'b0;
                adc_cs_n <= 1'b1;
                div_count <= {DIV_WIDTH{1'b0}};
                if (EXTERNAL_START ? start : (period_count == SAMPLE_PERIOD_CYCLES - 1)) begin
                    selected_channel <= EXTERNAL_START ? channel : 3'd0;
                    period_count <= {PERIOD_WIDTH{1'b0}};
                    busy         <= 1'b1;
                    adc_cs_n     <= 1'b0;
                    bit_index    <= 5'd0;
                    shift_reg    <= 10'd0;
                    adc_mosi     <= command_bit(5'd0);
                end else if (!EXTERNAL_START) begin
                    period_count <= period_count + 1'b1;
                end
            end else if (div_count == CLK_DIV_CYCLES - 1) begin
                div_count <= {DIV_WIDTH{1'b0}};
                if (!adc_sclk) begin
                    // Rising edge: MCP3008 presents data, FPGA samples it.
                    adc_sclk <= 1'b1;
                    if ((bit_index >= 5'd6) && (bit_index <= 5'd15)) begin
                        shift_reg <= {shift_reg[8:0], adc_miso};
                    end
                end else begin
                    // Falling edge: prepare the next command/data clock.
                    adc_sclk <= 1'b0;
                    if (bit_index == 5'd15) begin
                        busy         <= 1'b0;
                        adc_cs_n     <= 1'b1;
                        adc_mosi     <= 1'b0;
                        adc_value    <= shift_reg;
                        sample_valid <= 1'b1;
                    end else begin
                        bit_index <= bit_index + 1'b1;
                        adc_mosi  <= command_bit(bit_index + 1'b1);
                    end
                end
            end else begin
                div_count <= div_count + 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
