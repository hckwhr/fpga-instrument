`timescale 1ns/1ps
module tb_scope_production_uart #(parameter integer CPB=8);
    reg sys_clk=0,audio_clk=0,reset_n=0,rx=1;
    always #10 sys_clk=~sys_clk;
    always #7 audio_clk=~audio_clk;
    wire tx,sample_strobe;
    reg signed [15:0] wet=16'h7f45;
    wire signed [15:0] dry=~wet;
    wire bck,ws,din,stream_ready;
    pt8211_tx dac(.audio_clk(audio_clk),.reset_n(reset_n),.sample_in(wet),.sample_strobe(sample_strobe),.audio_bck(bck),.audio_ws(ws),.audio_din(din),.stream_ready(stream_ready));
    always @(posedge audio_clk)if(!reset_n)wet<=16'h7f45;else if(sample_strobe)wet<=wet+16'h0397;
    instrument_production_link #(.SCOPE_ENABLE(1),.CLKS_PER_BIT(CPB),.LINE_TIMEOUT_CYCLES(100000)) dut(
        .clock_enable(1'b1),.sys_clk(sys_clk),.audio_clk(audio_clk),.reset_n(reset_n),.rx(rx),.tx(tx),
        .setting_mode(1'b0),.stop_key(1'b0),.song_active(1'b0),.song_done(1'b0),.song_index(8'd0),.song_length(8'd85),
        .sample_strobe(sample_strobe),.scope_sample_strobe(sample_strobe),.scope_dry_sample(dry),.scope_wet_sample(wet),
        .event_ready(1'b1),.local_stop(1'b0),.play_blocked(1'b0),.upload_selected(1'b0));
    reg [15:0] expected[0:1023];
    integer captured=0,received=0,lines=0;
    string text="",body,golden;
    reg [7:0] decoded;
    function automatic [15:0] crc(input string value);
        reg [15:0] c;
        begin
            c=16'hffff;
            for(integer i=0;i<value.len();i++)begin
                c=c^{value[i],8'd0};
                for(integer b=0;b<8;b++)if(c[15])c=(c<<1)^16'h1021;else c=c<<1;
            end
            crc=c;
        end
    endfunction
    // frame_shift is the exact word already latched by the real PT8211 TX,
    // not a reconstruction of the note/score or of the incoming scope bus.
    always @(posedge audio_clk)if(reset_n && sample_strobe && dut.scope_enabled.scope.capturing)begin
        if(dac.frame_shift[31:16]!==wet)$fatal(1,"scope sample differs from actual PT8211 word");
        expected[captured]={dry[15:8],dac.frame_shift[31:24]};captured++;
    end
    initial forever begin
        @(negedge tx);#(CPB*30);
        for(integer b=0;b<8;b++)begin decoded[b]=tx;#(CPB*20);end
        if(tx!==1)$fatal(1,"bad UART stop bit");
        text={text,decoded};received++;
        if(decoded==10)begin
            if(lines<32)begin
                if(captured!=1024)$fatal(1,"UART sent incomplete frame");
                body=$sformatf("SCOPE1,89ABCDEF,%02X,",lines);
                for(integer k=0;k<32;k++)body={body,$sformatf("%04X",expected[lines*32+k])};
                body=body.toupper();golden={body,$sformatf(",%04X",crc(body)),8'd10};golden=golden.toupper();
                if(text!=golden)$fatal(1,"physical UART payload/CRC mismatch line %d",lines);
            end else if(text!="PONG\n")$fatal(1,"legacy control lost after snapshot: %s",text);
            lines++;text="";
        end
    end
    task automatic send(input string value);
        value=value.toupper();
        for(integer k=0;k<value.len();k++)begin
            @(negedge sys_clk);rx=0;repeat(CPB)@(negedge sys_clk);
            for(integer b=0;b<8;b++)begin rx=value[k][b];repeat(CPB)@(negedge sys_clk);end
            rx=1;repeat(CPB)@(negedge sys_clk);
        end
    endtask
    initial begin
        repeat(8)@(negedge sys_clk);reset_n=1;repeat(8)@(negedge sys_clk);
        body="SCOPE1,89ABCDEF";send({body,$sformatf(",%04X",crc(body)),8'd10});
        wait(lines==32);repeat(200)@(negedge sys_clk);send("PING\n");wait(lines==33);
        if(received!=4901)$fatal(1,"unexpected byte count");
        $display("PASS: physical UART request/router/mux/CDC to 32 CRC-checked SCOPE1 replies; all 1024 wet bytes match actual PT8211 frame words; subsequent PING intact");$finish;
    end
    initial begin #(40000000.0 * CPB / 8);$fatal(1,"production scope timeout");end
endmodule
