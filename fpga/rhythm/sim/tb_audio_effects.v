`timescale 1ns/1ps
module tb_audio_effects;
    reg clk=0,reset_n=0,strobe=0,mute=0;
    reg [1:0] effect=0;
    reg signed [15:0] pcm_in=0;
    wire signed [15:0] pcm_out;
    integer i,j,fd,errors=0,peak,mag,previous,tail_count;
    audio_effects dut(.clk(clk),.reset_n(reset_n),.sample_strobe(strobe),.mute(mute),
        .effect_select(effect),.effect_strength(2'd1),.sample_in(pcm_in),.sample_out(pcm_out));
    always #5 clk=~clk;
    task tick;begin @(posedge clk);#1;end endtask
    task check;input cond;input [8*100-1:0] msg;
        begin if(cond!==1'b1)begin $display("ERROR: %0s",msg);errors=errors+1;end end endtask
    task slot;begin
        strobe=1;tick();strobe=0;repeat(12)tick();
        check((^pcm_out)!==1'bx,"unknown output / stale RAM exposed");
    end endtask
    task clear;begin mute=1;pcm_in=0;repeat(300)slot();mute=0;repeat(300)slot();end endtask
    initial begin
        repeat(3)tick();reset_n=1;repeat(300)slot();
        pcm_in=12345;slot();check(pcm_out==12345,"dry bypass not exact");
        for(j=1;j<=3;j=j+1)begin
            effect=j;clear();peak=0;tail_count=0;
            fd=$fopen(j==1?"sim/impulse_delay.csv":j==2?"sim/impulse_chorus.csv":"sim/impulse_reverb.csv","w");
            check(fd!=0,"capture file unavailable");
            for(i=0;i<144000;i=i+1)begin
                pcm_in=i==0?16'sd30000:16'sd0;slot();
                $fwrite(fd,"%0d\n",pcm_out);
                mag=pcm_out<0?-pcm_out:pcm_out;if(mag>peak)peak=mag;
                if(i>1000 && mag>4)tail_count=tail_count+1;
            end
            $fclose(fd);
            check(peak<=30000,"impulse exceeded input bound");
            if(j==1 || j==3)check(tail_count>0,"effect has no tail");
            if(j==3)check(tail_count>300,"reverb reflections not dense enough");
            check(pcm_out==0,"zero-input tail failed to retire exactly");
            $display("EFFECT %0d impulse_peak=%0d tail_nonzero_samples=%0d",j,peak,tail_count);
            pcm_in=30000;
            repeat(48000)begin slot();check(pcm_out<=30000 && pcm_out>=0,"positive DC feedback unstable/clipped");end
            pcm_in=-30000;
            repeat(48000)begin slot();check(pcm_out>= -30000 && pcm_out<=30000,"negative feedback unstable/clipped");end
            // Settled mute fades with bounded per-sample change, then no old tail.
            previous=pcm_out;mute=1;
            repeat(160)begin slot();mag=pcm_out-previous;if(mag<0)mag=-mag;
                check(mag<=300,"mute made a discontinuous step");previous=pcm_out;end
            check(pcm_out==0,"mute did not reach silence");
            pcm_in=0;mute=0;repeat(10000)begin slot();check(pcm_out==0,"old effect RAM leaked after mute");end
        end
        effect=0;repeat(300)slot();pcm_in=-2345;slot();check(pcm_out==-2345,"dry mode did not recover exact bypass");
        if(errors)$fatal(1,"audio effects errors=%0d",errors);
        $display("PASS: dry bypass, delay/chorus/reverb impulses, DC bounds, smooth mute, tail retirement and stale RAM protection");
        $finish;
    end
endmodule
