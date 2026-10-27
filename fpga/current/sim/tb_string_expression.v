`timescale 1ns/1ps
module tb_string_expression;
    reg clk=0,rst=0,enable=1,strobe=0,fire=0,held=1,pluck=1;
    reg [5:0] note=12;
    reg signed [7:0] bend=0;
    reg [7:0] depth=0;
    wire signed [16:0] delta;
    wire signed [15:0] pcm,original;
    wire active,busy;
    integer i,j,n,fd,expected,checks=0,max_step=0,actual_step,bound;
    reg [20:0] previous_delay;
    reg [31:0] ratio_at_start;
    reg compare_neutral=1;
    string_pitch_control control(.clk(clk),.reset_n(rst),.sample_strobe(strobe),
        .enable(enable),.bend(bend),.vibrato_depth(depth),.delay_delta(delta));
    physical_string_voice dut(.clk(clk),.reset_n(rst),.sample_strobe(strobe),.enable(enable),
        .trigger(fire),.held(held),.pluck_mode(pluck),.note(note),.force_value(7'd96),
        .delay_delta(delta),.sample(pcm),.active(active),.level(),.busy(busy),.accepting());
    stage20_physical_string_voice baseline(.clk(clk),.reset_n(rst),.sample_strobe(strobe),.enable(enable),
        .trigger(fire),.held(held),.pluck_mode(pluck),.note(note),.force_value(7'd96),
        .sample(original),.active(),.level(),.busy(),.accepting());
    always #5 clk=~clk;
    always @(posedge clk) if(strobe)ratio_at_start=control.ratio;
    task tick;begin @(posedge clk);#2;@(negedge clk);end endtask
    task slot;integer t;begin
        if(busy)$fatal(1,"previous feedback unfinished");
        previous_delay=dut.delay_q12;bound=dut.slew_step;
        strobe=1;tick();strobe=0;
        actual_step=dut.delay_q12>previous_delay?dut.delay_q12-previous_delay:previous_delay-dut.delay_q12;
        if(active && !dut.pending && dut.state!=1 && actual_step>bound)$fatal(1,"delay slew exceeded bound");
        if(active && !dut.pending && dut.state!=1 && actual_step>max_step)max_step=actual_step;
        // 64 clocks cover both reciprocal division and interpolated feedback.
        // Only excitation fill needs the longer 512-clock interval.
        for(t=1;t<64;t=t+1)tick();
        while(busy)tick();
        if(control.left!=0)$fatal(1,"ratio calculation unfinished");
        expected=64'd68719476736/ratio_at_start-262144;
        if(delta!==expected)$fatal(1,"reciprocal mismatch ratio=%0d actual=%0d expected=%0d",ratio_at_start,delta,expected);
        if((^pcm)===1'bx || pcm==32767 || pcm==-32768)$fatal(1,"unknown/clipped expression PCM");
        if(compare_neutral && pcm!==original)$fatal(1,"neutral differs from accepted string");
        checks=checks+1;
    end endtask
    task restart;begin
        rst=0;repeat(4)tick();rst=1;repeat(8)tick();repeat(4)slot();
    end endtask
    task strike;begin fire=1;tick();fire=0;slot();slot();end endtask
    initial begin
        restart();strike();repeat(4096)slot();
        // Every bend code: reciprocal checked against integer division in TB.
        compare_neutral=0;
        for(i=-128;i<128;i=i+1)begin bend=i;repeat(8)slot();end
        fd=$fopen("sim/string_expression_pitch.csv","w");
        if(fd==0)$fatal(1,"capture open failed");
        $fwrite(fd,"note,bend,pcm,delay_q12,ratio,baseline_pcm\n");
        for(n=0;n<6;n=n+1)for(j=0;j<3;j=j+1)begin
            case(n)0:note=0;1:note=12;2:note=24;3:note=36;4:note=47;5:note=59;endcase
            bend=j==0?-128:j==1?0:127;depth=0;restart();strike();
            for(i=0;i<12288;i=i+1)begin
                slot();$fwrite(fd,"%0d,%0d,%0d,%0d,%0d,%0d\n",note,bend,pcm,dut.delay_q12,control.ratio,original);
            end
        end
        $fclose(fd);
        fd=$fopen("sim/string_expression_sweep.csv","w");
        if(fd==0)$fatal(1,"sweep capture open failed");
        $fwrite(fd,"sample,bend,depth,pcm,delay_q12,ratio,active\n");
        note=12;bend=0;depth=0;restart();strike();
        for(i=0;i<48000;i=i+1)begin
            if(i==1000)bend=127;
            if(i==3000)bend=-128;
            if(i==5000)bend=0;
            if(i==7000)depth=128;
            if(i==31000)depth=0;
            slot();$fwrite(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",i,bend,depth,pcm,dut.delay_q12,control.ratio,active);
        end
        if(dut.delay_q12!={dut.delay_length,12'd0})$fatal(1,"neutral target not recovered");
        $fclose(fd);
        // Bypass restores tuning but cannot undo the string's physical history.
        pluck=0;held=0;repeat(20000)slot();
        if(active || pcm!=0)$fatal(1,"release not silent");
        enable=0;slot();enable=1;note=12;compare_neutral=1;restart();strike();repeat(4096)slot();
        $display("PASS: string reciprocal all bend codes, pitch captures, slewed delay, vibrato tail, release/restart and exact neutral PCM; checks=%0d max_delay_step_q12=%0d",checks,max_step);
        $finish;
    end
    initial begin #450000000;$fatal(1,"timeout");end
endmodule
