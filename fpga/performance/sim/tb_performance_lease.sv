`timescale 1ns/1ps
// Production sample/byte cadence, with only the three-second lease scaled to
// 40 ms. Exercises a lost host and a stale host without forcing internal state.
module tb_performance_lease;
    reg clk=0, audio_clk=0, reset_n=0;
    always #10 clk=~clk;
    always #10.17241379 audio_clk=~audio_clk;
    reg [9:0] phase=0;
    reg sample_strobe=0;
    reg signed [15:0] sample=0;
    always @(negedge audio_clk) begin
        sample_strobe<=0;
        if(reset_n) begin
            phase<=phase+1'b1;
            if(phase==1023)begin sample_strobe<=1;sample<=sample+16'd127;end
        end
    end
    reg [7:0] rx_data=0;reg rx_valid=0;
    wire [7:0] tx_data;wire tx_valid,custom_enabled;wire [71:0] custom_map;
    integer baud=0;
    wire tx_ready=baud==0;
    always @(posedge clk)
        if(!reset_n)baud<=0;
        else if(baud!=0)baud<=baud-1;
        else if(tx_valid)baud<=4339;
    performance_uart #(.LEASE_CYCLES(2000000),.MAX_BLOCKS(10)) dut(
        .sys_clk(clk),.sys_reset_n(reset_n),.audio_clk(audio_clk),.audio_reset_n(reset_n),.clock_enable(1'b1),
        .sample_strobe(sample_strobe),.sample(sample),.keyboard_busy(1'b0),
        .custom_enabled(custom_enabled),.custom_map(custom_map),
        .rx_data(rx_data),.rx_valid(rx_valid),.tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready));
    function automatic [15:0] crc_byte(input [15:0] crc,input [7:0] value);
        reg [15:0] c;integer i;
        begin c=crc^{value,8'd0};for(i=0;i<8;i=i+1)c=c[15]?(c<<1)^16'h1021:c<<1;crc_byte=c;end
    endfunction
    task automatic send(input [31:0] id,input integer op);
        string body,request;reg [15:0] crc;integer i;
        begin
            body=$sformatf("PERF1,%08X,%1d,000000000000000000",id,op);body=body.toupper();crc=16'hffff;
            for(i=0;i<body.len();i=i+1)crc=crc_byte(crc,body[i]);
            request=$sformatf("%s,%04X\n",body,crc);request=request.toupper();
            for(i=0;i<request.len();i=i+1)begin @(negedge clk);rx_valid=1;rx_data=request[i];end
            @(negedge clk);rx_valid=0;
        end
    endtask
    string line="";
    integer acks=0,ends=0,blocks=0,status=-1,end_status=-1;
    reg [15:0] crc,got_crc;integer i;
    always @(posedge clk)if(reset_n&&tx_valid&&tx_ready)begin
        if(tx_data==10)begin
            crc=16'hffff;for(i=0;i<line.len()-5;i=i+1)crc=crc_byte(crc,line[i]);
            if($sscanf(line.substr(line.len()-4,line.len()-1),"%h",got_crc)!=1||crc!==got_crc)$fatal(1,"CRC");
            if(line[15]=="A")begin acks=acks+1;status=line[19]-48;end
            if(line[15]=="D")blocks=blocks+1;
            if(line[15]=="E")begin ends=ends+1;end_status=line[22]-48;end
            line="";
        end else line={line,tx_data};
    end
    initial begin
        #200;@(negedge clk);reset_n=1;
        send(32'h12345678,3);wait(acks==1);if(status!=0)$fatal(1,"start");
        #20000000;send(32'h12345678,5);wait(acks==2);if(status!=0)$fatal(1,"renew");
        #22000000;if(!dut.record_active)$fatal(1,"renewal did not extend the original lease");
        wait(ends==1);if(end_status!=2||blocks<3)$fatal(1,"lost host must terminate with lease-expired status");
        send(32'h23456789,3);wait(acks==3);if(status!=0)$fatal(1,"restart after expiration");
        send(32'h12345678,4);wait(acks==4);if(status!=3||!dut.record_active)$fatal(1,"stale owner stopped new take");
        send(32'h23456789,4);wait(ends==2);if(end_status!=0)$fatal(1,"new owner stop");
        $display("PASS: lease renewal, lost-host timeout, stale-owner rejection and restart at production cadence");$finish;
    end
    initial begin #250000000;$fatal(1,"lease test timeout");end
endmodule
