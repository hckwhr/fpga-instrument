`timescale 1ns/1ps
module tb_physical_strings;
    reg clk=0,reset_n=0,strobe=0,enable=0,fire=0,held=1,pluck=1;
    reg [5:0] note=12;
    reg [6:0] force_level=96;
    wire signed [15:0] sample;
    wire active;
    reg [2:0] triggers=0,gates=0;
    reg chord=1;
    reg [3:0] bank_note=0;
    reg [1:0] bank_octave=1;
    wire signed [15:0] bank_sample;
    wire [7:0] bank_active;
    integer i,n,fd,errors=0,peak,mag,latency;
    physical_string_voice dut(.clk(clk),.reset_n(reset_n),.sample_strobe(strobe),
        .enable(enable),.trigger(fire),.held(held),.pluck_mode(pluck),
        .note(note),.force_value(force_level),.delay_delta(17'sd0),.sample(sample),.active(active),
        .level(),.busy(),.accepting());
    physical_string_bank bank(.clk(clk),.reset_n(reset_n),.sample_strobe(strobe),
        .enable(enable),.voice_trigger(triggers),.voice_gate(gates),.play_mode(pluck),
        .keymap_select(chord),.note_select(bank_note),.octave_select(bank_octave),
        .force_value(force_level),.bend(8'sd0),.vibrato_depth(8'd0),.sample(bank_sample),.active_voices(bank_active),
        .active_voice_count(),.deadline_miss_count());
    always #5 clk=~clk;
    task tick; begin @(posedge clk); #1; end endtask
    task check;
        input cond; input [8*100-1:0] message;
        begin if(!cond) begin $display("ERROR: %0s",message); errors=errors+1; end end
    endtask
    task next_sample;
        begin
            strobe=1; tick(); strobe=0; repeat(15) tick();
            if(bank.state!=0) repeat(48) tick();
            // Only FILL needs 512 clocks. All other sample slots compress idle
            // cycles, retaining the identical sample-domain behavior.
            if(dut.state==1 || (|bank.busy)) repeat(512) tick();
            check(dut.state==0,"voice missed sample deadline");
            check((^sample)!==1'bx && (^bank_sample)!==1'bx,"unknown PCM");
            check(sample!=32767 && sample!=-32768,"single string saturated");
            check(bank.mix<65534 && bank.mix>-65536,"eight-string mix saturated");
        end
    endtask
    task strike;
        begin fire=1; triggers=1; tick(); fire=0; triggers=0; end
    endtask
    initial begin
        repeat(3)tick(); reset_n=1; enable=1; tick();
        repeat(4)next_sample(); check(sample==0 && bank_sample==0,"startup is not silent");
        strike(); latency=0;
        while(sample==0 && latency<6) begin next_sample(); latency=latency+1; end
        check(latency<6,"strike latency exceeds five sample slots");
        check(bank_active==15,"one-key chord does not activate four independent strings");
        $display("STRIKE latency=%0d sample slots plus <=512 fill clocks",latency);
        // Reset each capture so force/release comparisons share excitation.
        for(n=0;n<3;n=n+1) begin
            reset_n=0; tick(); reset_n=1; held=1; pluck=(n!=2); tick();
            force_level=(n==1)?48:96;
            case(n)
                0:fd=$fopen("sim/string_tail.csv","w");
                1:fd=$fopen("sim/string_soft.csv","w");
                2:fd=$fopen("sim/string_release.csv","w");
            endcase
            check(fd!=0,"capture cannot open"); strike();
            for(i=0;i<96000;i=i+1) begin
                if(n==2 && i==4800) held=0;
                next_sample(); $fwrite(fd,"%0d,%0d\n",sample,bank_sample);
            end
            $fclose(fd);
        end
        pluck=1; held=1; force_level=127;
        fd=$fopen("sim/string_pitch.csv","w"); check(fd!=0,"pitch capture cannot open");
        for(n=0;n<60;n=n+1) begin
            reset_n=0; tick(); reset_n=1; note=n;
            bank_note=n%12; bank_octave=(n/12)%3;
            tick(); fire=1; triggers=4; tick(); fire=0; triggers=0;
            for(i=0;i<12288;i=i+1) begin
                next_sample(); $fwrite(fd,"%0d\n",sample);
            end
        end
        $fclose(fd);
        // Mid-tail retrigger and source cancellation must remain bounded.
        note=12; strike(); repeat(256)next_sample();
        note=19; strike(); repeat(512)next_sample();
        check(active,"retrigger did not return to an active voice");
        check(dut.pending_note==19 && dut.pending==0,"retrigger lost pitch event");
        repeat(240100)next_sample();
        check(!active && sample==0,"natural tail did not terminate in exact silence");
        enable=0; tick(); check(sample==0 && bank_sample==0,"disable did not mute both engines");
        enable=1; repeat(4)next_sample(); check(sample==0,"disabled voice resumed stale RAM");
        // Three simultaneous keys in melody mapping also activate the upper fourth voice.
        chord=0; gates=7; triggers=7; tick(); triggers=0;
        repeat(5)next_sample(); check(bank_active==15,"three-key melody lost fourth voice");
        if(errors==0)$display("PASS: physical strings, four parallel loops, pitch captures, force, release, retrigger and mute");
        else $fatal(1,"physical string failures: %0d",errors);
        $finish;
    end
endmodule
