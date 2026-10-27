`timescale 1ns/1ps
module tb_string_decay;
    reg clk=0,rst=0,strobe=0,enable=1,fire=0,held=1,pluck=1;
    reg [5:0] note=0;
    reg [6:0] force_value=96;
    wire signed [15:0] pcm,old_pcm;
    wire busy,old_busy,active;
    integer n,i,t,fd,kind,checks=0;
    physical_string_voice dut(.clk(clk),.reset_n(rst),.sample_strobe(strobe),.enable(enable),
        .trigger(fire),.held(held),.pluck_mode(pluck),.note(note),.force_value(force_value),
        .delay_delta(17'sd0),.sample(pcm),.active(active),.level(),.busy(busy),.accepting());
    stage25_physical_string_voice old(.clk(clk),.reset_n(rst),.sample_strobe(strobe),.enable(enable),
        .trigger(fire),.held(held),.pluck_mode(pluck),.note(note),.force_value(force_value),
        .delay_delta(17'sd0),.sample(old_pcm),.active(),.level(),.busy(old_busy),.accepting());
    always #5 clk=~clk;
    task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
    task slot;begin
        strobe=1;tick();strobe=0;t=1;
        while(t<64 || busy || old_busy)begin tick();t=t+1;end
        if(t>513)$fatal(1,"feedback/fill missed deadline");
        if((^pcm)===1'bx || pcm==32767 || pcm==-32768)$fatal(1,"invalid or clipped string");
        if(note<36 && pcm!==old_pcm)$fatal(1,"unchanged register PCM differs");
        checks=checks+1;
    end endtask
    task strike;begin
        rst=0;repeat(4)tick();rst=1;repeat(8)tick();
        fire=1;tick();fire=0;
    end endtask
    initial begin
        fd=$fopen("sim/string_decay_pitch.csv","w");
        if(!fd)$fatal(1,"capture unavailable");
        $fwrite(fd,"note,sample,pcm,baseline\n");
        for(n=0;n<60;n=n+1)begin
            note=n;strike();
            for(i=0;i<12288;i=i+1)begin slot();$fwrite(fd,"%0d,%0d,%0d,%0d\n",n,i,pcm,old_pcm);end
        end
        $fclose(fd);
        fd=$fopen("sim/string_decay_tails.csv","w");
        if(!fd)$fatal(1,"tail capture unavailable");
        $fwrite(fd,"note,kind,sample,pcm,baseline\n");
        for(n=0;n<4;n=n+1)for(kind=0;kind<3;kind=kind+1)begin
            case(n)0:note=35;1:note=36;2:note=48;default:note=59;endcase
            force_value=kind==1?48:96;held=1;pluck=kind!=2;strike();
            for(i=0;i<48000;i=i+1)begin
                if(kind==2 && i==4800)held=0;
                slot();$fwrite(fd,"%0d,%0d,%0d,%0d,%0d\n",note,kind,i,pcm,old_pcm);
            end
            if(kind==2 && (active || pcm!=0))$fatal(1,"released string did not retire");
        end
        $fclose(fd);
        note=59;held=1;pluck=1;force_value=127;strike();repeat(240100)slot();
        if(active || pcm!=0)$fatal(1,"max lifetime did not retire high string");
        fire=1;tick();fire=0;repeat(80)slot();note=36;
        fire=1;tick();fire=0;repeat(80)slot();
        if(!active || dut.pending || dut.damping_band!=1)$fatal(1,"replacement did not latch new damping band");
        enable=0;tick();if(pcm!=0 || active)$fatal(1,"disable failed");
        enable=1;repeat(5)slot();if(pcm!=0 || active)$fatal(1,"stale RAM restarted");
        $display("PASS: 60 pitches, 12 force/release/tail captures, exact low/mid PCM, zero-gain damping-band replacement, retirement and disable; %0d sample checks",checks);
        $finish;
    end
endmodule
