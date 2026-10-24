`timescale 1ns/1ps
module stage9_piano_reference(input [31:0] phase, output signed [15:0] sample);
    `include "sim/stage9_piano_wave.vh"
    assign sample=piano_wave(phase);
endmodule

module tb_piano_lookup_exact;
    `include "piano_wave.vh"
    reg [31:0] phase=0;
    wire signed [15:0] reference_wave;
    integer index,low,checks=0;
    reg signed [16:0] expected_delta;
    stage9_piano_reference reference(.phase(phase),.sample(reference_wave));
    initial begin
        for(index=0;index<128;index=index+1)begin
            expected_delta=$signed(reference.piano_point((index+1)%128))-
                $signed(reference.piano_point(index));
            if(piano_delta(index[6:0])!==expected_delta)$fatal(1,"slope mismatch at knot %0d",index);
        end
        // Exhaust every meaningful 7-bit knot + 8-bit fraction, including the
        // negative half and 127->0 wrap. Low phase bits remain intentionally unused.
        for(index=0;index<32768;index=index+1)for(low=0;low<2;low=low+1)begin
            phase={index[14:0],{17{low[0]}}};#1;
            if(piano_wave(phase)!==reference_wave)
                $fatal(1,"wave differs from frozen stage9 at phase %h",phase);
            checks=checks+1;
        end
        $display("PASS: all 128 slopes and %0d phase/fraction cases exactly match frozen stage9 piano, including signed rounding and wrap",checks);
        $finish;
    end
endmodule
