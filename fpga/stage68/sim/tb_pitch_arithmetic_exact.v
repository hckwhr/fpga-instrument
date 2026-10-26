`timescale 1ns/1ps
module tb_pitch_arithmetic_exact;
    reg clk=0,reset_n=0,strobe=0,enable=1,active=0,note_start=0,start_valid=0;
    reg [31:0] target_increment=0,start_increment=0,rng=32'h7684abc1;
    reg [1:0] glide=0;
    reg [7:0] depth=0;
    reg signed [7:0] lfo=0,bend=0;
    wire [31:0] result,reference_result;
    integer cycle,checks=0,nonzero=0;
    always #5 clk=~clk;
    pitch_expression dut(.clk(clk),.reset_n(reset_n),.sample_strobe(strobe),.enable(enable),
        .active(active),.note_start(note_start),.target_increment(target_increment),
        .start_increment(start_increment),.start_valid(start_valid),.glide_select(glide),
        .vibrato_depth(depth),.lfo(lfo),.bend(bend),.expressed_increment(result));
    stage9_pitch_expression reference(.clk(clk),.reset_n(reset_n),.sample_strobe(strobe),.enable(enable),
        .active(active),.note_start(note_start),.target_increment(target_increment),
        .start_increment(start_increment),.start_valid(start_valid),.glide_select(glide),
        .vibrato_depth(depth),.lfo(lfo),.bend(bend),.expressed_increment(reference_result));
    initial begin
        repeat(3)@(negedge clk);reset_n=1;
        for(cycle=0;cycle<220000;cycle=cycle+1)begin
            @(negedge clk);
            rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
            strobe=(cycle<60000)?1:(cycle<120000)?(cycle%2==0):
                (cycle<180000)?(cycle%12==0):(cycle%1024==0);
            reset_n=(cycle%20011!=0);enable=(cycle%1013!=0);
            if(cycle%7==0)begin
                active=rng[0];note_start=rng[1];start_valid=rng[2];glide=rng[4:3];
                depth=rng[12:5];lfo=rng[20:13];bend=rng[28:21];
                target_increment=rng;start_increment={rng[7:0],rng[31:8]};
                case(cycle%11)
                    0:target_increment=0;
                    1:start_increment=0;
                    2:target_increment=start_increment;
                    3:target_increment=32'hffffffff;
                    4:start_increment=32'hffffffff;
                    5:target_increment=32'h80000000;
                    6:target_increment=dut.base_increment;
                    default:begin end
                endcase
            end
            @(posedge clk);#1;
            if({dut.base_increment,dut.target,dut.glide_step,dut.glide_left,dut.ready}!==
               {reference.base_increment,reference.target,reference.glide_step,reference.glide_left,reference.ready})
                $fatal(1,"glide state mismatch at cycle %0d",cycle);
            if(result!==reference_result)$fatal(1,"expressed pitch mismatch cycle=%0d",cycle);
            if((^result)===1'bx)$fatal(1,"unknown expressed pitch cycle=%0d",cycle);
            if(result!=0)nonzero=nonzero+1;
            checks=checks+1;
        end
        if(nonzero<10000)$fatal(1,"insufficient nonzero coverage");
        $display("PASS: %0d cycle-exact frozen-stage9 pitch/state checks, active/idle/zero/equal/full32-bit limits, glide/bend/vibrato, cadence 1/2/12/1024 and disable/reset; nonzero=%0d",checks,nonzero);
        $finish;
    end
endmodule
