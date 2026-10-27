`timescale 1ns/1ps
module tb_continuous_expression;
    reg clk=0,reset_n=0,strobe=0;
    reg signed [7:0] bend=0,lfo=0;
    reg [7:0] depth=0;
    wire [31:0] word;
    integer i,fd,errors=0;
    reg [31:0] previous;
    real cents,expected,error,max_error=0.0;
    pitch_expression dut(.clk(clk),.reset_n(reset_n),.sample_strobe(strobe),.enable(1'b1),
        .active(1'b1),.note_start(1'b0),.target_increment(32'd23409859),.start_increment(32'd23409859),
        .start_valid(1'b1),.glide_select(2'd0),.vibrato_depth(depth),.lfo(lfo),.bend(bend),.expressed_increment(word));
    always #5 clk=~clk;
    task tick;begin @(posedge clk);#1;end endtask
    task slot;begin strobe=1;tick();strobe=0;repeat(12)tick();end endtask
    task check;input cond;input [8*100-1:0] msg;begin
        if(cond!==1'b1)begin $display("ERROR: %0s",msg);errors=errors+1;end
    end endtask
    initial begin
        repeat(3)tick();reset_n=1;repeat(20)tick();
        fd=$fopen("sim/continuous_bend.csv","w");check(fd!=0,"capture unavailable");previous=0;
        for(i=-128;i<=127;i=i+1)begin
            bend=i;slot();
            cents=1200.0*$ln($itor(word)/23409859.0)/$ln(2.0);
            expected=(i==127)?200.0:i*200.0/128.0;
            error=cents-expected;if(error<0)error=-error;if(error>max_error)max_error=error;
            check(error<0.08,"equal-tempered bend error exceeds 0.08 cent");
            check(word>previous,"pitch bend not strictly monotonic");previous=word;
            if(i==0)check(word==23409859,"bend center not bit-exact");
            $fwrite(fd,"%0d,%0d,%0f\n",i,word,cents);
        end
        $fclose(fd);
        bend=0;lfo=127;previous=0;
        for(i=0;i<=128;i=i+1)begin
            depth=i;slot();check(word>previous,"vibrato positive peak depth is not continuous/monotonic");previous=word;
        end
        lfo=-128;previous=32'hffffffff;
        for(i=0;i<=128;i=i+1)begin
            depth=i;slot();check(word<previous,"vibrato negative peak depth is not continuous/monotonic");previous=word;
        end
        depth=255;slot();check(word==previous,"out-of-range vibrato depth not clamped");
        bend=-128;slot();check(word>0,"combined down bend and vibrato underflow");
        $display("BEND max_error_cent=%0f",max_error);
        if(errors)$fatal(1,"continuous expression errors=%0d",errors);
        $display("PASS: 256 bend positions, +/-2 semitones, exact center, 129 vibrato depths and clamped combination");
        $finish;
    end
endmodule
