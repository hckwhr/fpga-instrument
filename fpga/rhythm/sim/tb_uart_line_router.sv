`timescale 1ns/1ps
module tb_uart_line_router;
    reg clk=0,reset_n=0,rx_valid=0,rx_error=0,song_ready=1;
    reg [7:0] rx_data=0;
    wire [7:0] line_data;
    wire legacy_valid,song_valid,scope_valid,perf_valid,rx_dropped;
    wire legacy_ready=1'b1;
    wire [1:0] legacy_fault;
    string legacy_log="",song_log="";
    integer faults=0,last_fault=0;
    uart_line_router #(.TIMEOUT_CYCLES(40)) dut(.*);
    always #5 clk=~clk;
    always @(posedge clk)if(reset_n)begin
        if(legacy_valid && song_valid)$fatal(1,"double dispatch");
        if(legacy_valid)legacy_log={legacy_log,line_data};
        if(song_valid && song_ready)song_log={song_log,line_data};
        if(legacy_fault!=0)begin faults++;last_fault=legacy_fault;end
    end
    task put(input byte value,input bit error=0);
        @(negedge clk);rx_data=value;rx_valid=!error;rx_error=error;
        @(negedge clk);rx_valid=0;rx_error=0;
    endtask
    task send(input string value);
        for(integer k=0;k<value.len();k++)put(value[k]);
    endtask
    task check(input string legacy_expected,input string song_expected);
        repeat(300)@(negedge clk);
        if(legacy_log!=legacy_expected || song_log!=song_expected)$fatal(1,"router output legacy='%s' song='%s'",legacy_log,song_log);
        legacy_log="";song_log="";
    endtask
    string maximum;
    reg [7:0] stalled;
    initial begin
        repeat(3)@(negedge clk);reset_n=1;
        send("PING");repeat(8)@(negedge clk);
        if(legacy_log.len()!=0)$fatal(1,"partial command escaped");
        send({8'd13,8'd10});check("PING\n","");
        send({"SONG2,ABC",8'd13,8'd10});check("","SONG2,ABC\n");
        send("SONG2X\n");check("SONG2X\n","");
        send("\n");check("","");
        if(rx_dropped || faults)$fatal(1,"normal traffic dropped");
        maximum="SONG2,";repeat(249)maximum={maximum,"A"};
        send({maximum,8'd13,8'd10});check("",{maximum,"\n"});
        send({maximum,"APLAY\n"});check("","");
        if(!rx_dropped || faults)$fatal(1,"oversize SONG2 must drop without legacy error");
        send({"PL",8'd13,"AY\n"});check("","");
        if(faults!=1 || last_fault!=3)$fatal(1,"invalid CR fault");
        send("PL");repeat(60)@(negedge clk);send("AY\n");check("","");
        if(faults!=2 || last_fault!=2)$fatal(1,"timeout fault");
        send("SO");put(8'h80);send("PLAY\n");check("","");
        if(faults!=3 || last_fault!=3)$fatal(1,"ASCII fault");
        send("P");put(8'd0,1);send("LAY\n");check("","");
        if(faults!=4 || last_fault!=1)$fatal(1,"frame fault");
        song_ready=0;send("SONG2,DROP\n");check("","");
        send("STOP\n");check("STOP\n",""); // busy SONG2 cannot block old STOP
        song_ready=1;send("SONG2,WAIT\n");
        @(negedge clk);song_ready=0;stalled=line_data;
        repeat(6)begin @(negedge clk);if(!song_valid || line_data!=stalled)$fatal(1,"RX replay changed under stall");end
        send("PL"); // arrived while replay owns the buffer
        song_ready=1;repeat(30)@(negedge clk);
        send("AY\n");check("","SONG2,WAIT\n");
        send("PLAY\n");check("PLAY\n","");
        // Reset discards an unfinished line and clears the observable drop flag.
        send("SONG2,");reset_n=0;repeat(3)@(negedge clk);reset_n=1;
        if(rx_dropped)$fatal(1,"drop flag did not reset");
        send("PING\n");check("PING\n","");
        $display("PASS: complete-line demux, 255-byte/CRLF bound, exact prefix, errors/timeouts, busy backend, stalled replay and poisoned suffix recovery");$finish;
    end
    initial begin #1000000;$fatal(1,"router test timeout");end
endmodule
