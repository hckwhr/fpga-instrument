`timescale 1ns/1ps
module tb_spectrum_stop;
    reg clk=0,rst=0,strobe=0;
    reg signed [15:0] pcm=0;
    wire [1023:0] levels;
    wire valid;
    wire [7:0] misses;
    reg [1023:0] previous=0;
    integer n=0,frames=0,last_sample=-1;
    spectrum_analyzer #(.FRAME_GAP_SAMPLES(1024)) dut(.clk(clk),.reset_n(rst),
        .sample_strobe(strobe),.sample_in(pcm),.levels(levels),.frame_valid(valid),.deadline_misses(misses));
    always #5 clk=~clk;
    always @(posedge clk)begin
        #1;
        if(rst)begin
            if(valid)begin
                if(last_sample>=0 && n-last_sample!=2048)$fatal(1,"DFT update cadence changed");
                last_sample=n;frames=frames+1;
                if(n==1023 || n==7167)begin
                    if(levels[9*8 +: 8]==0)$fatal(1,"tone/restart missing bin 10");
                end else if(n==3071 || n==5119)begin
                    if(levels!=0)$fatal(1,"old spectrum survived a complete silent window");
                end else $fatal(1,"unexpected spectrum window endpoint %0d",n);
            end else if(levels!==previous)$fatal(1,"spectrum changed without frame_valid");
            previous=levels;
            if(misses!=0)$fatal(1,"DFT deadline missed");
        end
    end
    initial begin
        repeat(4)@(negedge clk);rst=1;
        for(n=0;n<8192;n=n+1)begin
            // Stop and restart deliberately fall inside the analyzer's quiet gap.
            pcm=(n<1500 || n>=6000)?$rtoi(12000*$sin(6.283185307179586*10*n/1024)):0;
            strobe=1;@(negedge clk);strobe=0;repeat(1023)@(negedge clk);
        end
        if(frames!=4)$fatal(1,"missing published frames");
        $display("PASS: production-gap DFT tone/stop/silence/restart, four coherent windows, no stale spectrum or deadline miss over 8192 real sample slots");
        $finish;
    end
endmodule
