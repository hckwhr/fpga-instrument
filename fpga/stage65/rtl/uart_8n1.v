`default_nettype none
// Single-clock full-duplex UART. RX is asynchronous, then double synchronized.
// 50 MHz * 58/59 / 5120 = 9600.106 baud (HC-05 transparent data mode).
module uart_8n1 #(
    parameter integer CLKS_PER_BIT = 5120
) (
    input wire clk, reset_n, rx,
    output wire tx,
    output reg [7:0] rx_data,
    output reg rx_valid, rx_error,
    input wire [7:0] tx_data,
    input wire tx_valid,
    output wire tx_ready
);
    localparam integer CW = (CLKS_PER_BIT > 1) ? $clog2(CLKS_PER_BIT) : 1;
    localparam [CW-1:0] BIT_LAST = CLKS_PER_BIT-1;
    localparam [CW-1:0] HALF_LAST = CLKS_PER_BIT/2-1;
    localparam [2:0] IDLE=0, START=1, DATA=2, STOP=3, BREAK_WAIT=4;
    reg [1:0] rx_sync;
    reg [2:0] rx_state, rx_bit;
    reg [CW-1:0] rx_count, tx_count;
    reg [7:0] rx_shift;
    reg [9:0] tx_shift;
    reg [3:0] tx_bit;
    reg tx_busy;
    assign tx = tx_shift[0];
    assign tx_ready = !tx_busy;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) rx_sync <= 2'b11;
        else rx_sync <= {rx_sync[0],rx};
    end
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rx_state<=IDLE; rx_count<=0; rx_bit<=0; rx_shift<=0;
            rx_data<=0; rx_valid<=0; rx_error<=0;
        end else begin
            rx_valid<=0; rx_error<=0;
            case (rx_state)
                IDLE: if (!rx_sync[1]) begin rx_state<=START; rx_count<=HALF_LAST; end
                START: if (rx_count!=0) rx_count<=rx_count-1'b1;
                    else if (rx_sync[1]) rx_state<=IDLE;
                    else begin rx_state<=DATA; rx_count<=BIT_LAST; rx_bit<=0; end
                DATA: if (rx_count!=0) rx_count<=rx_count-1'b1;
                    else begin
                        rx_shift[rx_bit]<=rx_sync[1]; rx_count<=BIT_LAST;
                        if (rx_bit==3'd7) rx_state<=STOP;
                        else rx_bit<=rx_bit+1'b1;
                    end
                STOP: if (rx_count!=0) rx_count<=rx_count-1'b1;
                    else if (rx_sync[1]) begin
                        rx_data<=rx_shift; rx_valid<=1; rx_state<=IDLE;
                    end else begin rx_error<=1; rx_state<=BREAK_WAIT; end
                BREAK_WAIT: if (rx_sync[1]) rx_state<=IDLE;
                default: rx_state<=IDLE;
            endcase
        end
    end
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            tx_shift<=10'h3ff; tx_count<=0; tx_bit<=0; tx_busy<=0;
        end else if (!tx_busy) begin
            if (tx_valid) begin
                tx_shift<={1'b1,tx_data,1'b0}; tx_count<=BIT_LAST; tx_bit<=0; tx_busy<=1;
            end
        end else if (tx_count!=0) tx_count<=tx_count-1'b1;
        else begin
            tx_count<=BIT_LAST;
            tx_shift<={1'b1,tx_shift[9:1]};
            if (tx_bit==4'd9) tx_busy<=0;
            else tx_bit<=tx_bit+1'b1;
        end
    end
endmodule
`default_nettype wire
