`timescale 1ns/1ps
module tb_spectrum;
    reg clk=0,reset_n=0,strobe=0;
    reg signed [15:0] pcm=0;
    wire [1023:0] levels;
    wire valid;
    wire [7:0] misses;
    integer scenario,n,b,fd,src,cycles,frames=0,max_work=0;
    real value;
    spectrum_analyzer dut(.clk(clk),.reset_n(reset_n),.sample_strobe(strobe),
        .sample_in(pcm),.levels(levels),.frame_valid(valid),.deadline_misses(misses));
    always #5 clk=~clk;
    always @(posedge clk)begin
        #1;
        if(valid)frames=frames+1;
        if(reset_n && dut.step==8 && dut.sample_index==1023)
            $fwrite(fd,"%0d,%0d,%0d\n",scenario,dut.bin_index+1,dut.magnitude);
    end
    task tick;begin @(posedge clk);#2;end endtask
    initial begin
        fd=$fopen("sim/spectrum_magnitudes.csv","w");
        src=$fopen("sim/spectrum_input.csv","w");
        if(!fd || !src)$fatal(1,"capture open failed");
        repeat(3)tick();reset_n=1;
        for(scenario=0;scenario<7;scenario=scenario+1)begin
            for(n=0;n<1024;n=n+1)begin
                case(scenario)
                    0:value=0;
                    1:value=8000*$sin(6.283185307179586*10*n/1024);
                    2:value=8000*$sin(6.283185307179586*10*n/1024)+4000*$sin(6.283185307179586*30*n/1024);
                    3:value=12000*$sin(6.283185307179586*9.3*n/1024);
                    4:value=1000;
                    5:value=(n%2)?32767:-32768;
                    default:value=20000*$sin(6.283185307179586*127*n/1024);
                endcase
                @(negedge clk);pcm=$rtoi(value);strobe=1;
                $fwrite(src,"%0d,%0d,%0d\n",scenario,n,pcm);
                tick();strobe=0;cycles=0;
                while(dut.step!=0 && cycles<1024)begin tick();cycles=cycles+1;end
                if(cycles>=1024)$fatal(1,"DFT missed audio deadline");
                if(cycles>max_work)max_work=cycles;
                repeat(1023-cycles)tick();
            end
            if(frames!=scenario+1 || misses!=0)$fatal(1,"frame/drop mismatch");
            for(b=0;b<128;b=b+1)begin
                if((^levels[b*8 +: 8])===1'bx || levels[b*8 +: 8]>80)$fatal(1,"bar out of range");
                if(scenario==0 && levels[b*8 +: 8]!=0)$fatal(1,"silence spectrum nonzero");
            end
        end
        $fclose(fd);$fclose(src);
        // Overrun is reported; never silently claim full-rate capture.
        @(negedge clk);strobe=1;tick();strobe=0;repeat(3)tick();
        strobe=1;tick();strobe=0;
        if(misses!=1)$fatal(1,"missing overload diagnostic");
        reset_n=0;tick();reset_n=1;
        if(misses!=0 || levels!=0)$fatal(1,"reset did not clear metadata");
        $display("PASS: 7 full-rate Hann DFT frames, 128 bins, silence, headroom, reset, overload diagnostic; work=%0d clocks/1024",max_work);
        $finish;
    end
endmodule
