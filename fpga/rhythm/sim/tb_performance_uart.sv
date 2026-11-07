`timescale 1ns/1ps
module tb_performance_uart #(parameter integer RHYTHM_TEST=0);
    reg sys_clk=0,audio_clk=0,reset_n=0,ce=0;
    always #10 sys_clk=~sys_clk;
    always #10.17241379 audio_clk=~audio_clk;
    always @(negedge audio_clk)ce<=!ce;
    reg sample_strobe=0,busy=0;
    reg [11:0] physical_keys=0;
    wire rhythm_guard;wire [11:0] rhythm_play,rhythm_guide;
    reg signed [15:0] sample=0;
    integer sample_phase=0,sample_number=0;
    always @(negedge audio_clk)begin
        sample_strobe<=0;
        if(reset_n)begin
            if(sample_phase==1023)begin
                sample_phase<=0;sample_strobe<=1;sample_number<=sample_number+1;
                sample<=$rtoi(11000.0*$sin(6.28318530718*440.0*sample_number/48000.0)+3000.0*$sin(6.28318530718*1320.0*sample_number/48000.0));
            end else sample_phase<=sample_phase+1;
        end
    end
    reg [7:0] rx_data=0;reg rx_valid=0;
    wire [7:0] tx_data;wire tx_valid,enabled;wire [71:0] mapping;
    integer baud_count=0;reg stall=0;
    wire tx_ready=baud_count==0&&!stall;
    always @(posedge sys_clk)if(!reset_n)baud_count<=0;else if(baud_count!=0)baud_count<=baud_count-1;else if(tx_valid&&tx_ready)baud_count<=4339;
    performance_uart #(.CE_ENABLE(1),.LEASE_CYCLES(15000000),.MAX_BLOCKS(5),.RHYTHM_ENABLE(RHYTHM_TEST)) dut(
        .sys_clk(sys_clk),.sys_reset_n(reset_n),.audio_clk(audio_clk),.audio_reset_n(reset_n),.clock_enable(ce),
        .sample_strobe(sample_strobe),.sample(sample),.keyboard_busy(busy),.custom_enabled(enabled),.custom_map(mapping),
        .physical_keys(physical_keys),.rhythm_blocked(1'b0),.rhythm_guard(rhythm_guard),.rhythm_play_keys(rhythm_play),.rhythm_guide_keys(rhythm_guide),
        .rx_data(rx_data),.rx_valid(rx_valid),.tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready));
    function automatic [15:0] crc_byte(input [15:0] crc,input [7:0] b);
        reg [15:0] c;integer k;
        begin c=crc^{b,8'd0};for(k=0;k<8;k=k+1)c=c[15]?(c<<1)^16'h1021:c<<1;crc_byte=c;end
    endfunction
    function automatic [7:0] hexchar(input [3:0] n);hexchar=n<10?48+n:55+n;endfunction
    task automatic send(input [31:0] id,input integer op,input [71:0] map,input bit corrupt=0);
        string body;reg[15:0]crc;integer k;
        begin
            body=$sformatf("PERF1,%08X,%1d,%018X",id,op,map);body=body.toupper();crc=16'hffff;
            for(k=0;k<body.len();k=k+1)crc=crc_byte(crc,body[k]);
            if(corrupt)crc=crc^1;
            body={body,",",hexchar(crc[15:12]),hexchar(crc[11:8]),hexchar(crc[7:4]),hexchar(crc[3:0]),8'd10};
            for(k=0;k<body.len();k=k+1)begin @(negedge sys_clk);rx_valid=1;rx_data=body[k];end
            @(negedge sys_clk);rx_valid=0;
        end
    endtask
    integer acks=0,ends=0,blocks=0,last_status=-1,last_end=-1;
    integer log_file,pcm_file;string line="";
    reg[15:0] crc,got_crc;integer k;
    always @(posedge sys_clk)begin
        if(reset_n && dut.pcm_valid && dut.record_active && ends==0)$fdisplay(pcm_file,"%0d",$signed(dut.pcm_data));
        if(reset_n&&tx_valid&&tx_ready)begin
            if(tx_data==10)begin
                crc=16'hffff;for(k=0;k<line.len()-5;k=k+1)crc=crc_byte(crc,line[k]);
                if($sscanf(line.substr(line.len()-4,line.len()-1),"%h",got_crc)!=1 || crc!==got_crc)$fatal(1,"CRC %s",line);
                if(line[15]=="A")begin acks=acks+1;last_status=line[19]-48;end
                if(line[15]=="D")begin blocks=blocks+1;if(line.len()!=195)$fatal(1,"DATA length");end
                if(line[15]=="E")begin ends=ends+1;last_end=line[22]-48;end
                $fdisplay(log_file,"%s",line);line="";
            end else line={line,tx_data};
        end
    end
    reg[71:0] newmap;integer before_ack;
    initial begin
        log_file=$fopen("performance-wire.txt","w");pcm_file=$fopen("performance-pcm.txt","w");
        #200;@(negedge sys_clk);reset_n=1;
        if(RHYTHM_TEST)begin
            send(1,7,0);wait(acks==1);if(last_status!=0)$fatal(1,"rhythm capability");
            send(2,6,{27'd0,1'b1,32'h12345678,12'h801});wait(acks==2);
            if(last_status!=0||!rhythm_guard||rhythm_guide!=12'h801)$fatal(1,"rhythm CDC arm");
            send(3,3,0);wait(acks==3);if(last_status!=2||dut.record_session)$fatal(1,"recording stole rhythm");
            send(4,2,0);wait(acks==4);if(last_status!=2)$fatal(1,"map changed while guarded");
            @(negedge audio_clk);physical_keys=12'h800;repeat(10)@(negedge audio_clk);physical_keys=0;
            send(5,7,0);wait(acks==5);
            if(last_status!=0||dut.result_map[23:12]!=12'h800||dut.result_map[67:36]!=32'h12345678)$fatal(1,"sticky report CDC");
            send(6,6,0,1);#100000;if(!rhythm_guard||acks!=5)$fatal(1,"bad CRC stopped session");
            send(7,6,0);wait(acks==6);if(last_status!=0||rhythm_guard||rhythm_play!=0)$fatal(1,"stop CDC");
            send(8,2,0);wait(acks==7);if(last_status!=0)$fatal(1,"map restore");
            $fclose(log_file);$fclose(pcm_file);
            $display("PASS: rhythm PERF1 CRC, audio CE request/ack, 32-bit cue, sticky hits, map/record exclusivity, stop/restore");$finish;
        end
        send(1,0,0);wait(acks==1);if(last_status!=0)$fatal(1,"default query");
        newmap=0;for(k=0;k<12;k=k+1)newmap[k*6+:6]=6'd32+(11-k);
        busy=1;send(2,1,newmap);wait(acks==2);if(last_status!=2||enabled)$fatal(1,"held key mapping accepted");
        busy=0;send(3,1,newmap);wait(acks==3);if(last_status!=1||!enabled||mapping!==newmap)$fatal(1,"map commit");
        send(4,1,{72{1'b1}});wait(acks==4);if(last_status!=3||mapping!==newmap)$fatal(1,"bad map");
        send(5,0,0,1);#100000; if(acks!=4)$fatal(1,"bad CRC accepted");
        send(6,2,0);wait(acks==5);if(last_status!=0||enabled)$fatal(1,"reset mapping");
        send(32'h12345678,3,0);wait(acks==6);wait(ends==1);
        if(blocks!=5||last_end!=3)$fatal(1,"limit did not drain exactly five blocks");
        send(32'h23456789,3,0);wait(acks==7);wait(blocks==6);
        send(32'h23456789,4,0);wait(ends==2);if(last_end!=0)$fatal(1,"normal stop");
        before_ack=acks;send(32'h34567890,3,0);wait(acks==before_ack+1);
        stall=1;wait(!dut.record_active);if(dut.record_reason!=1)$fatal(1,"backpressure must expose overflow");
        stall=0;wait(ends==3);if(last_end!=1)$fatal(1,"overflow end");
        $fclose(log_file);$fclose(pcm_file);
        $display("PASS: performance CRC, atomic CE map/busy/default, 115200 stream, 60s scaled limit, stop, overflow");$finish;
    end
    initial begin #600000000;$fatal(1,"timeout");end
endmodule
