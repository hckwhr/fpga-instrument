`timescale 1ns/1ps
module baud_peer #(parameter integer BAUD=115200, CPB=434)(output reg done=0);
    reg clk=0, reset_n=0, rx=1, tx_valid=0;
    reg [7:0] tx_data=0;
    wire tx,tx_ready,rx_valid,rx_error;
    wire [7:0] rx_data;
    integer received=0,errors=0;
    reg [7:0] expected[0:511];
    always #10 clk=~clk;
    uart_8n1 #(.CLKS_PER_BIT(CPB)) dut(.*);
    always @(posedge clk) if(reset_n) begin
        if(rx_error) errors++;
        if(rx_valid) begin
            if(received>=512 || rx_data!==expected[received])
                $fatal(1,"RX mismatch baud=%0d byte=%0d",BAUD,received);
            received++;
        end
    end
    task automatic send_byte(input byte value,input realtime bit_ns);
        rx=0; #(bit_ns);
        for(integer b=0;b<8;b++)begin rx=value[b]; #(bit_ns); end
        rx=1; #(bit_ns);
    endtask
    initial begin
        for(integer n=0;n<512;n++)expected[n]=8'(n);
        repeat(8)@(negedge clk);reset_n=1;
        // Peer timing is independent of the FPGA divisor, including +/-1.5%.
        #137;
        for(integer n=0;n<256;n++)send_byte(8'(n),1.0e9/BAUD*0.985);
        #(4.0e9/BAUD);
        for(integer n=0;n<256;n++)send_byte(8'(n),1.0e9/BAUD*1.015);
        #(4.0e9/BAUD);
        if(received!=512 || errors!=0)$fatal(1,"RX count/errors baud=%0d",BAUD);
        // Missing stop bit must be reported, then the receiver must recover.
        rx=0; #(12.0e9/BAUD); rx=1; #(3.0e9/BAUD);
        if(errors!=1)$fatal(1,"framing error not detected baud=%0d",BAUD);
        for(integer n=0;n<256;n++)begin
            wait(tx_ready);@(negedge clk);tx_data=8'(n);tx_valid=1;
            fork
                begin @(negedge clk);tx_valid=0;end
                begin
                    @(negedge tx); #(1.5e9/BAUD);
                    for(integer b=0;b<8;b++)begin
                        if(tx!==((n>>b)&1))$fatal(1,"TX mismatch baud=%0d",BAUD);
                        #(1.0e9/BAUD);
                    end
                    if(tx!==1'b1)$fatal(1,"TX stop baud=%0d",BAUD);
                end
            join
        end
        done=1;
    end
endmodule
module tb_uart_high_baud;
    wire a,b;
    baud_peer #(.BAUD(115200),.CPB(434)) p115(a);
    baud_peer #(.BAUD(230400),.CPB(217)) p230(b);
    initial begin wait(a && b);$display("PASS: UART115200/230400, all bytes, independent peer +/-1.5%%, framing detection, exact TX");$finish;end
    initial begin #100000000;$fatal(1,"high baud timeout");end
endmodule
