`timescale 1ns/1ps
module tb_ws2812_guide;
    reg clk=0,rst=0,mode=0;reg [11:0] notes=12'h001;
    wire data,enabled;integer f,b,k;reg [287:0] received;reg [23:0] expected;
    time rise;
    always #15 clk=~clk;
    ws2812_tx #(.GUIDE_ENABLE(1),.PIXELS_PER_KEY(1),.KEY_ORDER_REVERSED(1),.STARTUP_CYCLES(4)) dut(
        .clk(clk),.reset_n(rst),.held_notes(notes),.guide_mode(mode),.data_out(data),.buffer_enable(enabled));
    initial begin
        repeat(4)@(negedge clk);rst=1;
        for(f=0;f<4;f++)begin
            for(b=0;b<288;b++)begin @(posedge data);rise=$time;@(negedge data);received={received[286:0],($time-rise>550)};end
            for(k=0;k<12;k++)begin
                expected=0;
                if(f==1 && k==11)expected=24'h100800;
                if(f==2 && (k==11 || k==0))expected=24'h100010;
                if(received[(11-k)*24+:24]!==expected)$fatal(1,"frame=%d slot=%d color=%h expected=%h",f,k,received[(11-k)*24+:24],expected);
            end
            if(f==1)begin mode=1;notes=12'h801;end
            if(f==2)notes=0;
        end
        $display("PASS: decoded 12-pixel reversed GRB frames: startup black, manual yellow, score cyan chord, rest black");$finish;
    end
    initial begin #5000000;$fatal(1,"RGB timeout");end
endmodule
