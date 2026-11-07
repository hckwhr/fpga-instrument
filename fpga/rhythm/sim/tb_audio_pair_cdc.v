`timescale 1ns/1ps
module tb_audio_pair_cdc;
    reg src=0,dst=0,rst=0,strobe=0;
    reg [31:0] pair=0;
    wire [31:0] received;
    wire valid;
    integer sent=0,seen=0,n;
    reg [31:0] expected[0:127];
    reg [15:0] dry,wet;
    audio_sample_cdc #(.WIDTH(32)) dut(.src_clk(src),.src_reset_n(rst),.src_sample(pair),
        .src_sample_strobe(strobe),.dst_clk(dst),.dst_reset_n(rst),.dst_sample(received),.dst_sample_valid(valid));
    always #7 src=~src;
    always #11 dst=~dst;
    always @(posedge dst)begin
        #1;
        if(rst && valid)begin
            if(seen>=sent || received!==expected[seen])$fatal(1,"torn/reordered dry-wet pair");
            seen=seen+1;
        end
    end
    initial begin
        repeat(4)@(negedge src);rst=1;
        for(n=0;n<128;n=n+1)begin
            @(negedge src);
            dry=16'hffff^(n*16'h1357);wet=16'h7fff^(n*16'h246b);pair={dry,wet};
            expected[sent]=pair;sent=sent+1;strobe=1;
            @(negedge src);strobe=0;pair=~pair;
            repeat(20)@(negedge src);
        end
        repeat(30)@(negedge dst);
        if(seen!=128)$fatal(1,"pair missing");
        $display("PASS: 128 coherent dry/wet pairs through asynchronous 32-bit handshake, source changes while held");
        $finish;
    end
endmodule
