`default_nettype none
// GT911 16-bit register transactions. Burst reads of 1..10 bytes; single
// byte writes. LSB byte of read_data is the first register. No fabric clock.
module i2c_register_master #(
    parameter integer HALF_CYCLES=250, TIMEOUT_CYCLES=500000
) (
    input wire clk, reset_n, request, read_not_write,
    input wire [15:0] register_address,
    input wire [3:0] read_length,
    input wire [7:0] write_data,
    input wire scl_in, sda_in,
    output wire scl_low, sda_low,
    output reg busy, done, error,
    output reg [79:0] read_data
);
    reg byte_request, waiting, reading, failed;
    reg [3:0] step, length, index;
    reg [15:0] address;
    reg [7:0] write_hold;
    reg [2:0] command;
    reg [7:0] tx_data;
    wire byte_busy, byte_done, byte_error;
    wire [7:0] rx_data;
    i2c_byte_master #(.HALF_CYCLES(HALF_CYCLES),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) u_byte (
        .clk(clk),.reset_n(reset_n),.request(byte_request),.command(command),
        .tx_data(tx_data),.scl_in(scl_in),.sda_in(sda_in),
        .scl_low(scl_low),.sda_low(sda_low),.busy(byte_busy),
        .done(byte_done),.error(byte_error),.rx_data(rx_data)
    );
    always @* begin
        command=2; tx_data=0;
        case (step)
            0,4: command=0;
            1: tx_data=8'hba;
            2: tx_data=address[15:8];
            3: tx_data=address[7:0];
            5: tx_data=8'hbb;
            6: command=(index==length-1'b1)?4:3;
            7: tx_data=write_hold;
            8: command=1;
            default: command=1;
        endcase
    end
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            busy<=0;done<=0;error<=0;read_data<=0; byte_request<=0;
            waiting<=0;reading<=0;failed<=0;step<=0;length<=0;index<=0;
            address<=0;write_hold<=0;
        end else begin
            done<=0;error<=0;byte_request<=0;
            if (!busy) begin
                if (request) begin
                    if (read_not_write && (read_length==0 || read_length>10)) begin
                        done<=1;error<=1;
                    end else begin
                        busy<=1;reading<=read_not_write;length<=read_length;
                        address<=register_address;write_hold<=write_data;
                        read_data<=0;failed<=0;step<=0;index<=0;waiting<=0;
                    end
                end
            end else if (!waiting) begin byte_request<=1;waiting<=1; end
            else if (byte_done) begin
                waiting<=0;
                if (step==8) begin busy<=0;done<=1;error<=failed || byte_error; end
                else if (byte_error) begin failed<=1;step<=8; end
                else case (step)
                    3: step<=reading?4:7;
                    6: begin
                        read_data[index*8 +: 8]<=rx_data;
                        if (index==length-1'b1) step<=8;
                        else index<=index+1'b1;
                    end
                    7: step<=8;
                    default: step<=step+1'b1;
                endcase
            end
        end
    end
endmodule
`default_nettype wire
