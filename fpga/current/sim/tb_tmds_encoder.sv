`timescale 1ns/1ps
module tb_tmds_encoder;
    reg clk=0, reset_n=0, de=0;
    reg [7:0] data=0;
    reg [1:0] control=0;
    wire [9:0] symbol;
    always #5 clk=~clk;
    tmds_encoder dut(.pixel_clk(clk),.reset_n(reset_n),.de(de),.data(data),.control(control),.symbol(symbol));
    integer rd=0, checks=0;
    reg [9:0] pending=10'b1101010100;
    function automatic [9:0] ctl(input [1:0] c);
        case(c)
            0:ctl=10'b1101010100; 1:ctl=10'b0010101011;
            2:ctl=10'b0101010100; 3:ctl=10'b1010101011;
        endcase
    endfunction
    task automatic send(input bit active,input [7:0] d,input [1:0] c);
        reg [8:0] q;
        reg [9:0] expected;
        reg [7:0] restored,transition;
        integer ones, balance, k;
        begin
            @(negedge clk);de=active;data=d;control=c;
            @(posedge clk);#1;
            if(symbol!==pending) $fatal(1,"TMDS expected=%b got=%b check=%0d",pending,symbol,checks);
            checks++;
            if(!active) begin expected=ctl(c);rd=0;end
            else begin
                ones=$countones(d);
                q[8]=(ones<4 || (ones==4 && d[0]));
                q[0]=d[0];
                for(k=1;k<8;k++) q[k]=q[8] ? (q[k-1]^d[k]) : ~(q[k-1]^d[k]);
                balance=2*$countones(q[7:0])-8;
                // DVI 1.0 figure 3-5 selection; disparity is independently
                // accumulated from the emitted ten physical bits.
                if(rd==0 || balance==0)
                    expected={~q[8],q[8],q[8]?q[7:0]:~q[7:0]};
                else if((rd>0 && balance>0)||(rd<0 && balance<0))
                    expected={1'b1,q[8],~q[7:0]};
                else expected={1'b0,q[8],q[7:0]};
                rd=rd+2*$countones(expected)-10;
                if(rd>8 || rd< -8) $fatal(1,"disparity unbounded: %0d",rd);
                transition=expected[9] ? ~expected[7:0] : expected[7:0];
                restored[0]=transition[0];
                for(k=1;k<8;k++) restored[k]=transition[k]^transition[k-1]^!expected[8];
                if(restored!==d) $fatal(1,"TMDS inverse mismatch");
            end
            pending=expected;
        end
    endtask
    integer a,b;
    initial begin
        #2;reset_n=0;#20;reset_n=1;
        // Every pair of 8-bit pixels, continuous disparity across all pairs.
        for(a=0;a<256;a++) for(b=0;b<256;b++) begin
            send(1,a[7:0],0);send(1,b[7:0],0);
        end
        for(a=0;a<256;a++) begin
            send(0,0,a[1:0]);send(1,a[7:0],0);
        end
        send(0,0,0);send(0,0,0);
        @(negedge clk);reset_n=0;#1;
        if(symbol!==ctl(0)) $fatal(1,"reset failed");
        pending=ctl(0);rd=0;
        @(negedge clk);reset_n=1;
        send(1,8'hff,0);send(0,0,3);send(0,0,0);
        $display("PASS: TMDS exhaustive pixel pairs, controls, disparity, reset (%0d symbols)",checks);
        $finish;
    end
    initial begin #3000000;$fatal(1,"timeout");end
endmodule
