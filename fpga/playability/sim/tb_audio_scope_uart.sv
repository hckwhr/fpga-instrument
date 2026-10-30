`timescale 1ns/1ps
module tb_audio_scope_uart;
    reg sys_clk=0,audio_clk=0,reset_n=0;
    always #10 sys_clk=~sys_clk;
    always #7 audio_clk=~audio_clk;
    reg [7:0] rx_data=0;
    reg rx_valid=0,tx_ready=0;
    wire [7:0] tx_data;
    wire tx_valid;
    reg [3:0] divider=0;
    wire sample_strobe=divider==4'd15;
    reg [15:0] sample=0;
    wire signed [15:0] dry_sample=sample,wet_sample=~sample;
    audio_scope_uart dut(.sys_clk(sys_clk),.sys_reset_n(reset_n),.audio_clk(audio_clk),.audio_reset_n(reset_n),.*);
    reg [15:0] expected[0:1023];
    integer captured=0,blocks=0,frames=0,stall_checks=0;
    string received="",body,golden;
    reg [31:0] expected_id=32'h0123abcd;
    reg [15:0] random_state=16'h42ab;
    reg held=0;
    reg [7:0] held_byte;
    function automatic [15:0] crc(input string text);
        reg [15:0] c;
        begin
            c=16'hffff;
            for(integer i=0;i<text.len();i++)begin
                c=c^{text[i],8'd0};
                for(integer b=0;b<8;b++)begin
                    if(c[15])c=(c<<1)^16'h1021;else c=c<<1;
                end
            end
            crc=c;
        end
    endfunction
    always @(negedge sys_clk)begin
        random_state={random_state[14:0],random_state[15]^random_state[13]^random_state[12]^random_state[10]};
        tx_ready=random_state[0] && random_state[4];
    end
    always @(posedge audio_clk)begin
        if(!reset_n)begin divider<=0;sample<=0;end
        else begin
            divider<=divider+1'b1;
            if(sample_strobe)begin
                sample<=sample+16'h019b;
                if(dut.capturing)begin
                    expected[captured]={dry_sample[15:8],wet_sample[15:8]};captured++;
                    if(captured>1024)$fatal(1,"capture length overflow");
                end
            end
        end
    end
    always @(posedge sys_clk)begin
        if(!reset_n)begin held=0;received="";blocks=0;end
        else begin
            if(held)begin
                if(!tx_valid || tx_data!==held_byte)$fatal(1,"unstable output under stall");
                stall_checks++;
            end
            held=tx_valid && !tx_ready;held_byte=tx_data;
            if(tx_valid && tx_ready)begin
                received={received,tx_data};
                if(tx_data==10)begin
                    if(captured!=1024)$fatal(1,"published incomplete capture");
                    body=$sformatf("SCOPE1,%08X,%02X,",expected_id,blocks);
                    for(integer k=0;k<32;k++)body={body,$sformatf("%04X",expected[blocks*32+k])};
                    body=body.toupper();golden={body,$sformatf(",%04X",crc(body)),8'd10};golden=golden.toupper();
                    if(received!=golden)$fatal(1,"wire mismatch block=%d got=%s expected=%s",blocks,received,golden);
                    received="";blocks++;
                    if(blocks==32)frames++;
                end
            end
        end
    end
    task automatic send(input string text);
        for(integer k=0;k<text.len();k++)begin
            @(negedge sys_clk);rx_valid=1;rx_data=text[k];
        end
        @(negedge sys_clk);rx_valid=0;
    endtask
    task automatic request(input reg[31:0] id,input bit bad_crc);
        string text;
        begin
            text=$sformatf("SCOPE1,%08X",id);text=text.toupper();
            text={text,$sformatf(",%04X",crc(text) ^ (bad_crc ? 16'd1 : 16'd0)),8'd10};
            send(text.toupper());
        end
    endtask
    task automatic wait_frame(input integer count);
        integer cycles;
        begin
            cycles=0;
            while(frames<count)begin @(negedge sys_clk);cycles++;if(cycles>100000)$fatal(1,"snapshot timeout");end
            repeat(20)@(negedge sys_clk);
        end
    endtask
    initial begin
        repeat(8)@(negedge sys_clk);reset_n=1;
        request(expected_id,1);repeat(100)@(negedge sys_clk);
        if(dut.capturing || tx_valid || captured!=0)$fatal(1,"bad CRC accepted");
        request(expected_id,0);
        repeat(500)@(negedge sys_clk);request(32'hffffffff,0); // Busy request cannot corrupt snapshot ID.
        wait_frame(1);
        captured=0;blocks=0;expected_id=32'hf0e1d2c3;request(expected_id,0);wait_frame(2);
        captured=0;blocks=0;request(expected_id,0);
        repeat(400)@(negedge sys_clk);reset_n=0;repeat(8)@(negedge sys_clk);
        captured=0;blocks=0;reset_n=1;
        repeat(80)@(negedge sys_clk);
        if(tx_valid)$fatal(1,"reset leaked partial capture");
        expected_id=32'h76543210;request(expected_id,0);wait_frame(3);
        if(stall_checks<1000)$fatal(1,"stall coverage missing");
        $display("PASS: 3 complete SCOPE1 frames, 3072 exact signed sample pairs, independent CRC, async clocks, stalled synchronous RAM, bad CRC/busy request and reset recovery");$finish;
    end
    initial begin #15000000;$fatal(1,"test timeout");end
endmodule
