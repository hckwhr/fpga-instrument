`default_nettype none
// Goodix Rev09 reset/address timing, address 0x5D. Keep factory config.
// Polling works with either configured INT edge mode. INT is released after
// reset synchronization; never drive against the controller's IRQ output.
module gt911_touch #(
    parameter integer CYCLES_PER_MS=50000,
    parameter integer I2C_HALF_CYCLES=250,
    parameter integer I2C_TIMEOUT_CYCLES=500000
) (
    input wire clk, reset_n,
    input wire scl_in, sda_in,
    output wire scl_low, sda_low,
    output wire touch_reset_n, int_low,
    output reg online, down,
    output reg [9:0] x, y,
    output reg [2:0] touch_count,
    output reg update
);
    localparam RESET=0, SYNC=1, BOOT=2, PROBE=3, PROBE_WAIT=4,
        POLL_DELAY=5, STATUS=6, STATUS_WAIT=7, POINT=8, POINT_WAIT=9,
        CLEAR=10, CLEAR_WAIT=11;
    reg [3:0] state;
    reg [$clog2(CYCLES_PER_MS+1)-1:0] ms_count;
    reg [7:0] delay_ms, stale_polls;
    reg request, read_not_write;
    reg [15:0] register_address;
    reg [3:0] read_length;
    wire busy, done, error;
    wire [79:0] read_data;
    reg pending_down;
    reg [9:0] pending_x, pending_y;
    reg [2:0] pending_count;
    wire ms_tick = ms_count==CYCLES_PER_MS-1;
    wire bus_reset_n = reset_n && state!=RESET;
    assign touch_reset_n=reset_n && state!=RESET;
    assign int_low=!reset_n || state==RESET || state==SYNC;
    i2c_register_master #(.HALF_CYCLES(I2C_HALF_CYCLES),
        .TIMEOUT_CYCLES(I2C_TIMEOUT_CYCLES)) u_bus (
        .clk(clk),.reset_n(bus_reset_n),.request(request),
        .read_not_write(read_not_write),.register_address(register_address),
        .read_length(read_length),.write_data(8'h00),
        .scl_in(scl_in),.sda_in(sda_in),.scl_low(scl_low),.sda_low(sda_low),
        .busy(busy),.done(done),.error(error),.read_data(read_data)
    );
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state<=RESET;ms_count<=0;delay_ms<=0;stale_polls<=0;
            request<=0;read_not_write<=1;register_address<=0;read_length<=0;
            online<=0;down<=0;x<=0;y<=0;touch_count<=0;update<=0;
            pending_down<=0;pending_x<=0;pending_y<=0;pending_count<=0;
        end else begin
            request<=0;update<=0;
            if (ms_tick) ms_count<=0; else ms_count<=ms_count+1'b1;
            if (done && error) begin
                state<=RESET;delay_ms<=0;ms_count<=0;online<=0;
                down<=0;touch_count<=0;update<=1;stale_polls<=0;
            end else case (state)
                // 20 ms power/reset, 60 ms INT-low sync, 100 ms boot guard.
                RESET,SYNC,BOOT: if (ms_tick) begin
                    if ((state==RESET && delay_ms==19) ||
                        (state==SYNC && delay_ms==59) ||
                        (state==BOOT && delay_ms==99)) begin
                        delay_ms<=0;
                        case (state)
                            RESET: state<=SYNC;
                            SYNC: state<=BOOT;
                            default: state<=PROBE;
                        endcase
                    end else delay_ms<=delay_ms+1'b1;
                end
                PROBE: begin
                    register_address<=16'h8140;read_length<=10;
                    read_not_write<=1;request<=1;state<=PROBE_WAIT;
                end
                PROBE_WAIT: if (done) begin
                    // Product ID "911\0", factory panel resolution 1024x600.
                    if (read_data[31:0]==32'h00313139 &&
                        read_data[63:48]==16'd1024 && read_data[79:64]==16'd600) begin
                        online<=1;state<=POLL_DELAY;delay_ms<=0;
                    end else begin state<=RESET;delay_ms<=0;ms_count<=0; end
                end
                POLL_DELAY: if (ms_tick) begin
                    if (delay_ms==9) begin delay_ms<=0;state<=STATUS; end
                    else delay_ms<=delay_ms+1'b1;
                end
                STATUS: begin
                    register_address<=16'h814e;read_length<=1;
                    read_not_write<=1;request<=1;state<=STATUS_WAIT;
                end
                STATUS_WAIT: if (done) begin
                    if (read_data[7]) begin
                        stale_polls<=0;
                        pending_down<=0;pending_count<=0;
                        if (!read_data[6] && read_data[3:0]>=1 && read_data[3:0]<=5) begin
                            pending_count<=read_data[2:0];state<=POINT;
                        end else state<=CLEAR;
                    end else begin
                        state<=POLL_DELAY;
                        // A missing release or frozen ready flag cannot hold a key.
                        if (stale_polls==19) begin
                            down<=0;touch_count<=0;update<=1;stale_polls<=0;
                        end else stale_polls<=stale_polls+1'b1;
                    end
                end
                POINT: begin
                    register_address<=16'h814f;read_length<=8;
                    read_not_write<=1;request<=1;state<=POINT_WAIT;
                end
                POINT_WAIT: if (done) begin
                    if (read_data[23:8]<1024 && read_data[39:24]<600) begin
                        pending_x<=read_data[17:8];pending_y<=read_data[33:24];
                        pending_down<=1;
                    end else begin pending_down<=0;pending_count<=0; end
                    state<=CLEAR;
                end
                CLEAR: begin
                    register_address<=16'h814e;read_not_write<=0;
                    request<=1;state<=CLEAR_WAIT;
                end
                CLEAR_WAIT: if (done) begin
                    // Publish only after successful status clear, atomically.
                    down<=pending_down;touch_count<=pending_count;
                    if (pending_down) begin x<=pending_x;y<=pending_y; end
                    update<=1;state<=POLL_DELAY;
                end
                default: begin state<=RESET;delay_ms<=0;online<=0;down<=0;touch_count<=0; end
            endcase
        end
    end
endmodule
`default_nettype wire
