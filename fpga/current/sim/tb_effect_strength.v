`timescale 1ns/1ps
module tb_effect_strength;
    reg clk=0,reset_n=0,strobe=0,mute=0;
    reg [1:0] effect=0;
    reg [1:0] strength[0:2];
    reg signed [15:0] pcm=0;
    wire signed [15:0] sample[0:2];
    wire signed [15:0] baseline;
    integer i,j,k,fd,errors=0,previous,delta;
    real energy[0:2];
    genvar g;
    generate for(g=0;g<3;g=g+1)begin: fx
        audio_effects dut(.clk(clk),.reset_n(reset_n),.sample_strobe(strobe),.mute(mute),
            .effect_select(effect),.effect_strength(strength[g]),.sample_in(pcm),.sample_out(sample[g]));
    end endgenerate
    baseline_audio_effects old(.clk(clk),.reset_n(reset_n),.sample_strobe(strobe),.mute(mute),
        .effect_select(effect),.sample_in(pcm),.sample_out(baseline));
    always #5 clk=~clk;
    task tick;begin @(posedge clk);#1;end endtask
    task check;input cond;input [8*100-1:0] msg;begin
        if(cond!==1'b1)begin $display("ERROR: %0s",msg);errors=errors+1;
            if(errors>5)$fatal(1,"strength failure");end
    end endtask
    task slot;begin strobe=1;tick();strobe=0;repeat(12)tick();
        check(sample[1]===baseline,"medium strength differs from approved previous RTL");
        for(k=0;k<3;k=k+1)check((^sample[k])!==1'bx && sample[k]<=30000 && sample[k]>=-30000,
            "strength mix unknown or exceeded bounded input");
    end endtask
    initial begin
        strength[0]=0;strength[1]=1;strength[2]=2;repeat(3)tick();reset_n=1;
        for(j=1;j<=3;j=j+1)begin
            mute=1;effect=j;pcm=0;repeat(300)slot();mute=0;repeat(300)slot();
            for(k=0;k<3;k=k+1)energy[k]=0.0;
            case(j)
                1:fd=$fopen("sim/strength_delay.csv","w");
                2:fd=$fopen("sim/strength_chorus.csv","w");
                3:fd=$fopen("sim/strength_reverb.csv","w");
            endcase
            check(fd!=0,"strength capture unavailable");
            for(i=0;i<48000;i=i+1)begin
                pcm=(i==0)?30000:0;slot();
                if(i==0)check(sample[0]==22500 && sample[1]==15000 && sample[2]==7500,"wrong dry coefficients");
                else for(k=0;k<3;k=k+1)energy[k]=energy[k]+$itor(sample[k])*$itor(sample[k]);
                $fwrite(fd,"%0d,%0d,%0d\n",sample[0],sample[1],sample[2]);
            end
            $fclose(fd);
            check(energy[0]>0 && energy[0]<energy[1] && energy[1]<energy[2],"wet energy not light < medium < strong");
            $display("STRENGTH effect=%0d tail_energy=%0f/%0f/%0f",j,energy[0],energy[1],energy[2]);
            for(i=0;i<12000;i=i+1)begin pcm=(i%11<5)?30000:-30000;slot();end
        end
        // Switch strength during a steady nonzero signal; no abrupt gain step.
        mute=1;effect=1;pcm=30000;repeat(300)slot();mute=0;repeat(1000)slot();
        previous=sample[2];strength[2]=0;
        repeat(512)begin slot();delta=sample[2]-previous;if(delta<0)delta=-delta;
            // First rendered sample arrives at ramp level 2; subsequent steps are one level.
            check(delta<=((30000*2+127)/128),"live strength change exceeded two ramp steps");previous=sample[2];end
        check(sample[2]==22500,"light strength did not commit / stale tail exposed");
        if(errors)$fatal(1,"strength errors=%0d",errors);
        $display("PASS: all three effects and strengths, exact medium baseline PCM, wet-energy order, bounded mixing and faded live change");
        $finish;
    end
endmodule
