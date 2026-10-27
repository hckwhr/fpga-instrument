`timescale 1ns/1ps
module tb_spectrum_gap;
    reg clk=0,reset_n=0,strobe=0;
    reg signed [15:0] sample=0;
    wire [1023:0] levels;
    wire valid;
    wire [7:0] misses;
    integer n,cycles;
    spectrum_analyzer #(.FRAME_GAP_SAMPLES(1024)) dut(
        .clk(clk),.reset_n(reset_n),.sample_strobe(strobe),.sample_in(sample),
        .levels(levels),.frame_valid(valid),.deadline_misses(misses));
    always #5 clk=~clk;
    task sample_tick;
        begin @(negedge clk);sample=16'sd4000;strobe=1;@(posedge clk);#2;strobe=0;end
    endtask
    task feed_frame;
        begin
            for(n=0;n<1024;n=n+1)begin sample_tick();cycles=0;
                while(dut.step!=0 && cycles<1024)begin @(posedge clk);#2;cycles=cycles+1;end
                repeat(1023-cycles)@(posedge clk);
            end
            @(posedge clk);#2;
        end
    endtask
    initial begin
        repeat(3)@(posedge clk);reset_n=1;
        feed_frame();
        if(!dut.frame_skip || misses!=0)$fatal(1,"first frame/gap failed step=%0d sample=%0d bin=%0d skip=%0d misses=%0d",dut.step,dut.sample_index,dut.bin_index,dut.frame_skip,misses);
        repeat(1024)sample_tick();
        if(dut.frame_skip || misses!=0)$fatal(1,"gap did not elapse cleanly skip=%0d sample=%0d step=%0d",dut.frame_skip,dut.sample_index,dut.step);
        feed_frame();
        if(!dut.frame_skip || misses!=0)$fatal(1,"second frame failed");
        $display("PASS: one-frame DFT quiet gap, no deadline misses, audio sample timing remains free-running");
        $finish;
    end
endmodule
